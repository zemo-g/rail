#!/usr/bin/env python3
"""safe_server.py — HTTP server for sandboxed Rail-to-WASM compilation.
Serves compile.ledatic.org on port 8090.

POST /compile — Rail source in body → .wasm binary response
GET / — playground editor page
"""

import http.server
import subprocess
import tempfile
import hashlib
import threading
import time
import os
from collections import defaultdict

PORT = 8090
RAIL_SAFE = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'rail_safe')
MAX_SOURCE = 65536
COMPILE_TIMEOUT = 5
RATE_LIMIT = 10  # per minute per IP
RATE_WINDOW = 60
ALLOWED_ORIGINS = {'https://compile.ledatic.org', 'https://ledatic.org'}

# Compile lock — rail_safe writes to fixed /tmp/rail_safe.wasm
_compile_lock = threading.Lock()

# Rate limiting with cleanup
_rates = defaultdict(list)
_rate_cleanup = 0

def rate_ok(ip):
    global _rate_cleanup
    now = time.time()
    # Periodic cleanup of stale IPs
    if now - _rate_cleanup > 300:
        stale = [k for k, v in _rates.items() if not v or now - v[-1] > RATE_WINDOW]
        for k in stale:
            del _rates[k]
        _rate_cleanup = now
    _rates[ip] = [t for t in _rates[ip] if now - t < RATE_WINDOW]
    if len(_rates[ip]) >= RATE_LIMIT:
        return False
    _rates[ip].append(now)
    return True

def validate_wasm_imports(wasm_bytes):
    """Verify WASM binary only imports fd_write and proc_exit."""
    try:
        if len(wasm_bytes) < 8 or wasm_bytes[:4] != b'\x00asm':
            return False
        # Walk sections to find import section (id=2)
        pos = 8
        while pos < len(wasm_bytes):
            section_id = wasm_bytes[pos]
            pos += 1
            size, pos = _read_leb128(wasm_bytes, pos)
            if section_id == 2:  # Import section
                return _check_imports(wasm_bytes, pos, pos + size)
            pos += size
        return True  # No import section = safe
    except Exception:
        return False

def _read_leb128(data, pos):
    result = 0
    shift = 0
    while pos < len(data):
        b = data[pos]
        pos += 1
        result |= (b & 0x7f) << shift
        if (b & 0x80) == 0:
            break
        shift += 7
    return result, pos

def _read_name(data, pos):
    length, pos = _read_leb128(data, pos)
    name = data[pos:pos+length].decode('utf-8', errors='replace')
    return name, pos + length

def _skip_limits(data, pos):
    """Skip WASM limits encoding (used by table and memory imports)."""
    flags = data[pos]
    pos += 1
    _, pos = _read_leb128(data, pos)  # min
    if flags & 1:
        _, pos = _read_leb128(data, pos)  # max (if has_max flag)
    return pos

def _check_imports(data, pos, end):
    count, pos = _read_leb128(data, pos)
    allowed = {
        ('wasi_snapshot_preview1', 'fd_write'),
        ('wasi_snapshot_preview1', 'proc_exit'),
    }
    found = set()
    for _ in range(count):
        if pos >= end:
            return False  # Truncated import section
        mod, pos = _read_name(data, pos)
        name, pos = _read_name(data, pos)
        kind = data[pos]
        pos += 1
        if kind == 0:  # func import
            _, pos = _read_leb128(data, pos)  # type index
        elif kind == 1:  # table import
            _ = data[pos]  # reftype
            pos += 1
            pos = _skip_limits(data, pos)
        elif kind == 2:  # memory import
            pos = _skip_limits(data, pos)
        elif kind == 3:  # global import
            pos += 1  # valtype
            pos += 1  # mutability
        else:
            return False  # Unknown import kind
        found.add((mod, name))
    return found.issubset(allowed)

EDITOR_HTML = b"""<!DOCTYPE html><html><head><meta charset='utf-8'>
<meta name='viewport' content='width=device-width,initial-scale=1'>
<title>Rail Playground</title>
<link href='https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;600&display=swap' rel='stylesheet'>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{background:#0a0a0a;color:#e4e4e7;font-family:'JetBrains Mono',monospace;padding:24px}
h1{color:#00ff41;font-size:24px;margin-bottom:4px}
.sub{color:#52525b;font-size:13px;margin-bottom:24px}
.wrap{max-width:800px;margin:0 auto}
textarea{width:100%;height:300px;background:#111;color:#e4e4e7;border:1px solid #222;
border-radius:8px;padding:16px;font-family:'JetBrains Mono',monospace;font-size:14px;
resize:vertical;outline:none;tab-size:2}
textarea:focus{border-color:#00ff4140}
.btns{display:flex;gap:8px;margin-top:12px;flex-wrap:wrap}
button{background:#111;color:#00ff41;border:1px solid #00ff41;border-radius:6px;
padding:10px 24px;font-family:'JetBrains Mono',monospace;font-size:14px;cursor:pointer}
button:hover{background:#00ff4110}
button:disabled{opacity:0.5;cursor:wait}
.btn-example{color:#52525b;border-color:#333;font-size:12px;padding:6px 12px}
.btn-example:hover{color:#e4e4e7;border-color:#555}
#output{background:#111;border:1px solid #222;border-radius:8px;padding:16px;
margin-top:16px;min-height:60px;white-space:pre-wrap;font-size:13px;color:#a1a1aa}
#output.ok{border-color:#00ff4140;color:#e4e4e7}
#output.err{border-color:#f9731640;color:#f97316}
#stats{color:#333;font-size:11px;margin-top:8px}
.info{color:#52525b;font-size:11px;margin-top:16px}
.info a{color:#00ff41;text-decoration:none}
</style></head><body><div class='wrap'>
<h1>Rail Playground</h1>
<div class='sub'>Write Rail. Compile to WebAssembly. Run in your browser. Nothing touches the server.</div>
<textarea id='src' spellcheck='false'>fib n = if n < 2 then n else fib (n - 1) + fib (n - 2)

main =
  let _ = print (show (fib 10))
  let _ = print (show (fib 20))
  let _ = print (show (fib 30))
  0</textarea>
<div class='btns'>
<button id='btn' onclick='compile()'>Compile &amp; Run</button>
<button class='btn-example' onclick='loadEx(0)'>fibonacci</button>
<button class='btn-example' onclick='loadEx(1)'>ADTs</button>
<button class='btn-example' onclick='loadEx(2)'>closures</button>
<button class='btn-example' onclick='loadEx(3)'>fizzbuzz</button>
<button class='btn-example' onclick='loadEx(4)'>lists</button>
</div>
<div id='output'>Press Compile &amp; Run.</div>
<div id='stats'></div>
<div class='info'>
Sandboxed compilation via <a href='https://ledatic.org'>Rail</a>.
WASM runs in your browser &mdash; no server execution.
<code>shell</code>, <code>read_file</code>, <code>write_file</code> are rejected at the AST level.
<a href='https://github.com/zemo-g/rail'>Source</a>
</div>
<script>
var EXAMPLES=[
`fib n = if n < 2 then n else fib (n - 1) + fib (n - 2)

main =
  let _ = print (show (fib 10))
  let _ = print (show (fib 20))
  let _ = print (show (fib 30))
  0`,
`type Shape = | Circle r | Rect w h

area s = match s
  | Circle r -> r * r * 3
  | Rect w h -> w * h

main =
  let _ = print (show (area (Circle 5)))
  let _ = print (show (area (Rect 4 7)))
  let _ = print (show (area (Circle 10)))
  0`,
`apply f x = f x

main =
  let scale = 10
  let mul = \\x -> x * scale
  let _ = print (show (apply mul 7))
  let offset = 100
  let add = \\x -> x + offset
  let _ = print (show (apply add 42))
  0`,
`fizzbuzz n = if n > 20 then 0
  else
    let _ = if (n % 15) == 0 then print "FizzBuzz"
      else if (n % 3) == 0 then print "Fizz"
      else if (n % 5) == 0 then print "Buzz"
      else print (show n)
    fizzbuzz (n + 1)

main =
  let _ = fizzbuzz 1
  0`,
`main =
  let xs = [10, 20, 30, 40, 50]
  let _ = print (show (head xs))
  let _ = print (show (length xs))
  let _ = print (show (head (tail (tail xs))))
  0`
];
function loadEx(i){document.getElementById('src').value=EXAMPLES[i]}
async function compile(){
var btn=document.getElementById('btn'),out=document.getElementById('output'),stats=document.getElementById('stats');
var src=document.getElementById('src').value;
btn.disabled=true;out.className='';out.textContent='Compiling...';stats.textContent='';
var t0=performance.now();
try{
var r=await fetch('/compile',{method:'POST',body:src,headers:{'Content-Type':'text/plain'}});
var ct=performance.now()-t0;
if(!r.ok){var e=await r.text();out.className='err';out.textContent=e;stats.textContent='compile: '+Math.round(ct)+'ms';btn.disabled=false;return}
var wasm=await r.arrayBuffer();
stats.textContent='compile: '+Math.round(ct)+'ms, wasm: '+wasm.byteLength+' bytes';
var output='';var M={m:null};
var imports={wasi_snapshot_preview1:{
fd_write:function(fd,iovs,cnt,pw){var v=new DataView(M.m.buffer);var p=v.getUint32(iovs,true);var l=v.getUint32(iovs+4,true);output+=new TextDecoder().decode(new Uint8Array(M.m.buffer,p,l));v.setUint32(pw,l,true);return 0},
proc_exit:function(c){}}};
var{instance}=await WebAssembly.instantiate(wasm,imports);
M.m=instance.exports.memory;
output='';instance.exports._start();
out.className='ok';out.textContent=output||'(no output)';
}catch(e){out.className='err';out.textContent='Error: '+e.message}
btn.disabled=false}
</script></div></body></html>"""


class Handler(http.server.BaseHTTPRequestHandler):
    def _cors_origin(self):
        origin = self.headers.get('Origin', '')
        if origin in ALLOWED_ORIGINS:
            return origin
        return 'https://compile.ledatic.org'

    def do_GET(self):
        if self.path == '/' or self.path == '':
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(EDITOR_HTML)))
            self.end_headers()
            self.wfile.write(EDITOR_HTML)
        else:
            self.send_error(404)

    def do_POST(self):
        if self.path != '/compile':
            self.send_error(404)
            return

        ip = self.client_address[0]
        if not rate_ok(ip):
            self._error(429, 'Rate limit exceeded (max 10/min)')
            return

        length = int(self.headers.get('Content-Length', 0))
        if length > MAX_SOURCE:
            self._error(413, 'Source too large (max 64KB)')
            return
        if length == 0:
            self._error(400, 'Empty source')
            return

        source = self.rfile.read(length)

        # Unique temp paths per request to avoid race conditions
        with tempfile.NamedTemporaryFile(suffix='.rail', delete=False, mode='wb') as f:
            f.write(source)
            src_path = f.name

        try:
            # Serialize compilation — rail_safe writes to fixed /tmp/rail_safe.wasm
            with _compile_lock:
                result = subprocess.run(
                    [RAIL_SAFE, 'safe', src_path],
                    capture_output=True, text=True,
                    timeout=COMPILE_TIMEOUT
                )

                # Sanitize output — strip temp file paths
                stdout = result.stdout.replace(src_path, '<source>')

                if 'REJECTED' in stdout:
                    for line in stdout.split('\n'):
                        if 'REJECTED' in line:
                            self._error(400, line.strip())
                            return
                    self._error(400, 'Rejected: banned construct')
                    return

                if 'wat2wasm: OK' not in stdout:
                    self._error(400, 'Compilation failed')
                    return

                # Read compiled WASM before releasing lock
                wasm_path = '/tmp/rail_safe.wasm'
                if not os.path.exists(wasm_path):
                    self._error(500, 'Compilation produced no output')
                    return

                with open(wasm_path, 'rb') as f:
                    wasm = f.read()

            # Validate WASM imports outside lock (defense-in-depth, Gap C)
            if not validate_wasm_imports(wasm):
                print(f'  BLOCKED: {ip} — WASM import validation failed')
                self._error(500, 'Output validation failed')
                return

            # Log
            src_hash = hashlib.sha256(source).hexdigest()[:12]
            wasm_hash = hashlib.sha256(wasm).hexdigest()[:12]
            print(f'  compile: {ip} src={src_hash} wasm={wasm_hash} size={len(wasm)}')

            self.send_response(200)
            self.send_header('Content-Type', 'application/wasm')
            self.send_header('Content-Length', str(len(wasm)))
            self.send_header('Access-Control-Allow-Origin', self._cors_origin())
            self.end_headers()
            self.wfile.write(wasm)

        except subprocess.TimeoutExpired as te:
            # Ensure child is dead — prevent zombies
            try:
                os.kill(te.pid, 9) if hasattr(te, 'pid') and te.pid else None
                os.waitpid(-1, os.WNOHANG)
            except (OSError, ChildProcessError):
                pass
            self._error(408, 'Compilation timeout (5s)')
        except Exception:
            self._error(500, 'Internal error')
        finally:
            try:
                os.unlink(src_path)
            except OSError:
                pass

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header('Access-Control-Allow-Origin', self._cors_origin())
        self.send_header('Access-Control-Allow-Methods', 'POST, GET, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()

    def _error(self, code, msg):
        body = msg.encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'text/plain')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Access-Control-Allow-Origin', self._cors_origin())
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        print(f'  {self.client_address[0]} {args[0]}')


class ThreadingServer(http.server.ThreadingHTTPServer):
    daemon_threads = True


if __name__ == '__main__':
    print(f'rail-safe server on :{PORT}')
    print(f'  compiler: {RAIL_SAFE}')
    print(f'  rate limit: {RATE_LIMIT}/min per IP')
    print(f'  compile timeout: {COMPILE_TIMEOUT}s')
    print(f'  CORS: {ALLOWED_ORIGINS}')
    ThreadingServer(('0.0.0.0', PORT), Handler).serve_forever()
