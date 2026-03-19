"""Fleet Agent v2 — Job-capable agent for distributed Rail training.

Backward-compatible with v1 (/health, /status, /exec).
New: /job/* endpoints for long-running training processes.

API:
  GET  /health              → {"alive": true, "uptime": N}
  GET  /status              → system info + GPU + active job
  GET  /job/status           → current job state, last log lines
  GET  /job/log?lines=N      → tail N lines of job output (default 50)
  POST /exec                → run short command (10s timeout)
  POST /job/start            → {"cmd": "...", "name": "..."} start long job
  POST /job/stop             → kill running job
  POST /upload               → {"path": "...", "content": "..."} write file

Usage: python fleet_agent.py [--port 9101]
"""

import http.server
import json
import os
import platform
import subprocess
import threading
import time
import sys
import urllib.parse

PORT = 9101
START_TIME = time.time()
TOKEN = None
ALLOWED_COMMANDS = []
HOME = os.path.expanduser("~")
FLEET_DIR = os.path.join(HOME, ".fleet")
LOG_DIR = os.path.join(HOME, "rail_training")

# ── Job Manager ───────────────────────────────────────────────────────────────

class JobManager:
    """Manages a single long-running background job."""

    def __init__(self):
        self.process = None
        self.name = None
        self.cmd = None
        self.start_time = None
        self.end_time = None
        self.exit_code = None
        self.log_path = None
        self._lock = threading.Lock()
        self._thread = None

    @property
    def running(self):
        return self.process is not None and self.process.poll() is None

    @property
    def state(self):
        return self._get_state_nolock()

    def start(self, cmd, name="job"):
        with self._lock:
            if self.process is not None and self.process.poll() is None:
                return False, "job already running"

            self.name = name
            self.cmd = cmd
            self.start_time = time.time()
            self.end_time = None
            self.exit_code = None
            self.log_path = os.path.join(LOG_DIR, f"{name}.log")

            os.makedirs(LOG_DIR, exist_ok=True)

            try:
                log_fd = open(self.log_path, "w")
                # Write header
                log_fd.write(f"=== {name} ===\n")
                log_fd.write(f"Started: {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
                log_fd.write(f"Command: {cmd}\n")
                log_fd.write(f"{'='*60}\n")
                log_fd.flush()

                self.process = subprocess.Popen(
                    cmd, shell=True,
                    stdout=log_fd, stderr=subprocess.STDOUT,
                    cwd=LOG_DIR,
                    # CREATE_NEW_PROCESS_GROUP on Windows to survive parent death
                    creationflags=subprocess.CREATE_NEW_PROCESS_GROUP if os.name == "nt" else 0,
                )
                self._log_fd = log_fd

                # Monitor thread — updates state when process exits
                self._thread = threading.Thread(target=self._monitor, daemon=True)
                self._thread.start()

                return True, f"started pid={self.process.pid}"

            except Exception as e:
                self.name = None
                return False, str(e)

    def _monitor(self):
        """Wait for process to exit, record results."""
        if self.process:
            self.process.wait()
            with self._lock:
                self.exit_code = self.process.returncode
                self.end_time = time.time()
                elapsed = self.end_time - self.start_time
                try:
                    self._log_fd.write(f"\n{'='*60}\n")
                    self._log_fd.write(f"Finished: {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
                    self._log_fd.write(f"Exit code: {self.exit_code}\n")
                    self._log_fd.write(f"Elapsed: {elapsed:.0f}s ({elapsed/60:.1f}m)\n")
                    self._log_fd.close()
                except Exception:
                    pass

    def stop(self):
        with self._lock:
            if self.process is None or self.process.poll() is not None:
                return False, "no running job"
            try:
                self.process.terminate()
                # Give it 5s to clean up
                try:
                    self.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                self.exit_code = -9
                self.end_time = time.time()
                return True, "stopped"
            except Exception as e:
                return False, str(e)

    def get_status(self):
        try:
            result = {
                "state": self._get_state_nolock(),
                "name": self.name,
                "cmd": self.cmd,
            }
            if self.start_time:
                result["start_time"] = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(self.start_time))
                if self.state == "running":
                    result["elapsed_s"] = int(time.time() - self.start_time)
                    result["elapsed"] = _fmt_duration(time.time() - self.start_time)
                    result["pid"] = self.process.pid if self.process else None
            if self.end_time:
                result["end_time"] = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(self.end_time))
                result["elapsed_s"] = int(self.end_time - self.start_time)
                result["elapsed"] = _fmt_duration(self.end_time - self.start_time)
            if self.exit_code is not None:
                result["exit_code"] = self.exit_code
            if self.log_path:
                result["log_path"] = self.log_path
            return result
        except Exception as e:
            return {"state": "error", "error": str(e)}

    def _get_state_nolock(self):
        if self.process is None and self.name is None:
            return "idle"
        if self.process is not None and self.process.poll() is None:
            return "running"
        if self.exit_code == 0:
            return "completed"
        if self.exit_code is not None:
            return "failed"
        return "unknown"

    def get_log(self, lines=50):
        if not self.log_path or not os.path.exists(self.log_path):
            return ""
        try:
            with open(self.log_path, "r") as f:
                all_lines = f.readlines()
                return "".join(all_lines[-lines:])
        except Exception:
            return ""


def _fmt_duration(seconds):
    h, rem = divmod(int(seconds), 3600)
    m, s = divmod(rem, 60)
    if h > 0:
        return f"{h}h {m}m {s}s"
    return f"{m}m {s}s"


JOB = JobManager()

# ── Config ────────────────────────────────────────────────────────────────────

def load_config():
    global TOKEN, ALLOWED_COMMANDS
    token_path = os.path.join(FLEET_DIR, "token")
    if os.path.exists(token_path):
        TOKEN = open(token_path).read().strip().replace("\r", "")
    cmds_path = os.path.join(FLEET_DIR, "allowed_commands")
    if os.path.exists(cmds_path):
        ALLOWED_COMMANDS = [l.strip() for l in open(cmds_path).readlines() if l.strip()]


def is_allowed(cmd):
    for entry in ALLOWED_COMMANDS:
        if cmd == entry or cmd.startswith(entry + " "):
            return True
    return not ALLOWED_COMMANDS


# ── System Info ───────────────────────────────────────────────────────────────

def run_cmd(cmd, timeout=10):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return r.stdout + r.stderr, r.returncode
    except subprocess.TimeoutExpired:
        return "timeout", 1
    except Exception as e:
        return str(e), 1


_gpu_cache = {"data": {}, "ts": 0, "lock": threading.Lock()}
_GPU_SCRIPT = os.path.join(HOME, ".fleet", "gpu_poll.py")

def _write_gpu_script():
    """Write a standalone GPU polling script that runs as a separate process."""
    os.makedirs(os.path.dirname(_GPU_SCRIPT), exist_ok=True)
    with open(_GPU_SCRIPT, "w") as f:
        f.write("""import subprocess, json, sys
try:
    r = subprocess.run(
        "nvidia-smi --query-gpu=name,memory.total,memory.used,memory.free,utilization.gpu,temperature.gpu --format=csv,noheader,nounits",
        shell=True, capture_output=True, text=True, timeout=8)
    parts = [p.strip() for p in r.stdout.strip().split(",")]
    if len(parts) >= 6:
        print(json.dumps({"gpu":parts[0],"gpu_mem_total_mb":int(parts[1]),"gpu_mem_used_mb":int(parts[2]),"gpu_mem_free_mb":int(parts[3]),"gpu_util_pct":int(parts[4]),"gpu_temp_c":int(parts[5])}))
    else:
        print("{}")
except:
    print("{}")
""")

def _gpu_poll_loop():
    """Background thread: runs a SEPARATE python process to query nvidia-smi.
    This avoids GIL contention — the subprocess runs independently."""
    while True:
        try:
            r = subprocess.run(
                [sys.executable, _GPU_SCRIPT],
                capture_output=True, text=True, timeout=15)
            if r.stdout.strip():
                data = json.loads(r.stdout.strip())
                if data:
                    with _gpu_cache["lock"]:
                        _gpu_cache["data"] = data
                        _gpu_cache["ts"] = time.time()
        except Exception:
            pass
        time.sleep(30)

def get_gpu_info():
    """Return cached GPU info (never blocks)."""
    with _gpu_cache["lock"]:
        return dict(_gpu_cache["data"]) if _gpu_cache["data"] else {}


_sys_cache = {"data": {}, "ts": 0, "lock": threading.Lock()}

def _sys_poll_loop():
    """Background thread: polls system info every 60s via separate process."""
    while True:
        try:
            r = subprocess.run(
                [sys.executable, "-c",
                 "import json,shutil,os;root='C:/' if os.name=='nt' else '/';d=shutil.disk_usage(root);print(json.dumps({'disk_free_gb':d.free//(1024**3),'disk_total_gb':d.total//(1024**3)}))"],
                capture_output=True, text=True, timeout=10)
            if r.stdout.strip():
                data = json.loads(r.stdout.strip())
                with _sys_cache["lock"]:
                    _sys_cache["data"] = data
                    _sys_cache["ts"] = time.time()
        except Exception:
            pass
        time.sleep(60)

_HOSTNAME = os.environ.get("COMPUTERNAME", os.environ.get("HOSTNAME", "unknown"))
_ARCH = platform.machine()
_PLATFORM = platform.system()

def get_status():
    """Fully non-blocking: reads only from pre-populated caches."""
    result = {
        "hostname": _HOSTNAME,
        "arch": _ARCH,
        "platform": _PLATFORM,
        "agent_uptime_s": int(time.time() - START_TIME),
        "agent_uptime": _fmt_duration(time.time() - START_TIME),
        "agent_version": "2.0",
    }

    # Merge cached sys info (non-blocking read)
    with _sys_cache["lock"]:
        if _sys_cache["data"]:
            result.update(_sys_cache["data"])

    # Merge cached GPU info (non-blocking read)
    with _gpu_cache["lock"]:
        if _gpu_cache["data"]:
            result.update(_gpu_cache["data"])

    # Job info (in-memory, always instant)
    result["job"] = JOB.get_status()
    return result


# ── HTTP Handler ──────────────────────────────────────────────────────────────

class FleetHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def _send(self, code, body):
        payload = json.dumps(body, indent=2).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)

    def _read_body(self):
        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            return {}
        raw = self.rfile.read(length).decode()
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            return None

    def _check_auth(self):
        if TOKEN is None:
            return True
        req = self.headers.get("X-Fleet-Token", "").strip().replace("\r", "")
        if req != TOKEN:
            self._send(403, {"error": "unauthorized"})
            return False
        return True

    def _parse_qs(self):
        parsed = urllib.parse.urlparse(self.path)
        return dict(urllib.parse.parse_qsl(parsed.query))

    # ── GET ────────────────────────────────────────────────────────────────

    def do_GET(self):
        if not self._check_auth():
            return
        path = urllib.parse.urlparse(self.path).path

        if path == "/health":
            self._send(200, {
                "alive": True,
                "uptime": int(time.time() - START_TIME),
                "version": "2.0",
                "job_running": JOB.running,
            })

        elif path == "/ping":
            self._send(200, {"pong": True})

        elif path == "/status":
            s = {
                "alive": True,
                "hostname": _HOSTNAME,
                "arch": _ARCH,
                "platform": _PLATFORM,
                "agent_uptime_s": int(time.time() - START_TIME),
                "version": "2.0",
            }
            # Job status (all in-memory, no subprocess)
            j = JOB.get_status()
            s["job"] = j
            self._send(200, s)

        elif path == "/job/status":
            status = JOB.get_status()
            # Include last 5 log lines for quick glance
            last_lines = JOB.get_log(5).strip()
            if last_lines:
                status["last_output"] = last_lines
            self._send(200, status)

        elif path == "/job/log":
            qs = self._parse_qs()
            lines = int(qs.get("lines", "50"))
            log_text = JOB.get_log(lines)
            self._send(200, {
                "name": JOB.name,
                "state": JOB.state,
                "lines": lines,
                "log": log_text,
            })

        else:
            self._send(404, {"error": "not found"})

    # ── POST ───────────────────────────────────────────────────────────────

    def do_POST(self):
        if not self._check_auth():
            return
        path = urllib.parse.urlparse(self.path).path

        if path == "/exec":
            data = self._read_body()
            if data is None:
                self._send(400, {"error": "invalid json"})
                return
            cmd = data.get("cmd", "")
            if not cmd:
                self._send(400, {"error": "missing cmd"})
                return
            if not is_allowed(cmd):
                self._send(403, {"error": "command not whitelisted"})
                return
            timeout = min(data.get("timeout", 10), 60)
            output, exit_code = run_cmd(cmd, timeout=timeout)
            self._send(200, {"output": output, "exit_code": exit_code})

        elif path == "/job/start":
            data = self._read_body()
            if data is None:
                self._send(400, {"error": "invalid json"})
                return
            cmd = data.get("cmd", "")
            name = data.get("name", "job")
            if not cmd:
                self._send(400, {"error": "missing cmd"})
                return
            ok, msg = JOB.start(cmd, name)
            code = 200 if ok else 409
            self._send(code, {"ok": ok, "message": msg, "name": name})

        elif path == "/job/stop":
            ok, msg = JOB.stop()
            self._send(200, {"ok": ok, "message": msg})

        elif path == "/upload":
            data = self._read_body()
            if data is None:
                self._send(400, {"error": "invalid json"})
                return
            filepath = data.get("path", "")
            content = data.get("content", "")
            if not filepath:
                self._send(400, {"error": "missing path"})
                return
            # Security: only allow writes under rail_training/
            abs_path = os.path.abspath(os.path.join(LOG_DIR, filepath))
            if not abs_path.startswith(os.path.abspath(LOG_DIR)):
                self._send(403, {"error": "path must be under rail_training/"})
                return
            try:
                os.makedirs(os.path.dirname(abs_path), exist_ok=True)
                with open(abs_path, "w") as f:
                    f.write(content)
                self._send(200, {"ok": True, "path": abs_path, "bytes": len(content)})
            except Exception as e:
                self._send(500, {"error": str(e)})

        else:
            self._send(404, {"error": "not found"})


# ── Main ──────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    port = PORT
    if "--port" in sys.argv:
        idx = sys.argv.index("--port")
        port = int(sys.argv[idx + 1])

    load_config()
    os.makedirs(FLEET_DIR, exist_ok=True)
    os.makedirs(LOG_DIR, exist_ok=True)

    token_path = os.path.join(FLEET_DIR, "token")
    if not os.path.exists(token_path):
        print(f"[fleet] No token found, creating {token_path}")
        open(token_path, "w").write("fleet-test-token-2026\n")
        TOKEN = "fleet-test-token-2026"

    cmds_path = os.path.join(FLEET_DIR, "allowed_commands")
    if not os.path.exists(cmds_path):
        defaults = "nvidia-smi\ntasklist\ndir\nwhoami\npython\n"
        open(cmds_path, "w").write(defaults)
        ALLOWED_COMMANDS = [l for l in defaults.strip().split("\n")]

    # Write GPU polling helper script
    _write_gpu_script()

    # No background threads, no startup subprocess calls
    # All system info is static or on-demand

    server = http.server.ThreadingHTTPServer(("0.0.0.0", port), FleetHandler)
    print(f"[fleet] agent v2 on :{port} (token={'set' if TOKEN else 'open'})")
    print(f"[fleet] log dir: {LOG_DIR}")
    print(f"[fleet] endpoints: /health /status /exec /job/start /job/status /job/log /job/stop /upload")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[fleet] shutdown")
        if JOB.running:
            print("[fleet] stopping active job...")
            JOB.stop()
