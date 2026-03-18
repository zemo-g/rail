"""Fleet Agent — Python implementation for non-ARM64 nodes (Windows/x86_64).
Drop-in replacement for fleet_agent.rail. Serves identical JSON API on :9101.

Usage: python fleet_agent.py [--port 9101]
"""
import http.server
import json
import os
import platform
import subprocess
import time
import sys

PORT = 9101
START_TIME = time.time()
TOKEN = None
ALLOWED_COMMANDS = []
HOME = os.path.expanduser("~")
FLEET_DIR = os.path.join(HOME, ".fleet")


def load_config():
    global TOKEN, ALLOWED_COMMANDS
    token_path = os.path.join(FLEET_DIR, "token")
    if os.path.exists(token_path):
        TOKEN = open(token_path).read().strip().replace("\r", "")
    cmds_path = os.path.join(FLEET_DIR, "allowed_commands")
    if os.path.exists(cmds_path):
        ALLOWED_COMMANDS = [l.strip() for l in open(cmds_path).readlines() if l.strip()]


def escape_json(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "")


def run_cmd(cmd):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10)
        return r.stdout + r.stderr, r.returncode
    except subprocess.TimeoutExpired:
        return "timeout", 1
    except Exception as e:
        return str(e), 1


def get_gpu_info():
    out, _ = run_cmd("nvidia-smi --query-gpu=name,memory.total,memory.free,utilization.gpu --format=csv,noheader,nounits")
    if out and "timeout" not in out and "not" not in out.lower():
        parts = [p.strip() for p in out.strip().split(",")]
        if len(parts) >= 4:
            return {
                "gpu": parts[0],
                "gpu_mem_total": f"{parts[1]} MB",
                "gpu_mem_free": f"{parts[2]} MB",
                "gpu_util": f"{parts[3]}%",
            }
    return {}


def get_status():
    hostname = platform.node() or os.environ.get("COMPUTERNAME", "")
    if not hostname:
        hostname, _ = run_cmd("hostname")
        hostname = hostname.strip()

    cpu = platform.processor() or platform.machine()
    arch = platform.machine()

    # Memory + Disk — try psutil first (reliable cross-platform), fall back to shell
    mem = "unknown"
    disk = "unknown"
    try:
        import psutil
        m = psutil.virtual_memory()
        mem = f"{m.available // (1024*1024)} MB avail"
        import shutil
        d = shutil.disk_usage("C:/" if os.name == "nt" or "MINGW" in platform.platform() else "/")
        disk = f"{d.free // (1024**3)}G free of {d.total // (1024**3)}G"
    except ImportError:
        out, _ = run_cmd("free -m 2>/dev/null || vm_stat 2>/dev/null")
        mem = out.strip()[:60] if out.strip() else "unknown"
        out, _ = run_cmd("df -h / | tail -1")
        disk = out.strip()[:80] if out.strip() else "unknown"

    # Uptime
    uptime_str = "unknown"
    try:
        import psutil as _ps
        boot = _ps.boot_time()
        delta = int(time.time() - boot)
        days, rem = divmod(delta, 86400)
        hours, rem = divmod(rem, 3600)
        mins, _ = divmod(rem, 60)
        uptime_str = f"{days}d {hours}h {mins}m" if days else f"{hours}h {mins}m"
    except ImportError:
        out, _ = run_cmd("uptime")
        uptime_str = out.strip().split(",")[0] if out.strip() else "unknown"

    # Training progress (check local path)
    train = {"train_level": "", "train_round": "", "train_harvested": "", "train_rate": ""}
    progress_path = os.path.join(HOME, "projects", "rail", "training", "self_train", "progress.txt")
    if os.path.exists(progress_path):
        for line in open(progress_path).readlines():
            if "=" in line:
                k, v = line.strip().split("=", 1)
                if k == "level":
                    train["train_level"] = v
                elif k == "round":
                    train["train_round"] = v
                elif k == "harvested":
                    train["train_harvested"] = v
                elif k == "rate":
                    train["train_rate"] = v

    # Services (platform-specific)
    services = []
    if platform.system() == "Windows" or "MINGW" in platform.platform():
        # List notable running processes
        out, _ = run_cmd('tasklist /FO CSV /NH 2>nul | findstr /i "python mlx nvidia fleet"')
        for line in out.strip().split("\n"):
            if line.strip():
                name = line.split(",")[0].strip('" ')
                if name and name not in services:
                    services.append(name)
    else:
        out, _ = run_cmd("launchctl list 2>/dev/null | grep ledatic")
        for line in out.strip().split("\n"):
            parts = line.strip().split()
            if len(parts) >= 3 and "ledatic" in parts[-1]:
                services.append(parts[-1])

    result = {
        "hostname": hostname,
        "cpu": cpu,
        "mem": mem,
        "disk": disk,
        "arch": arch,
        "uptime": uptime_str,
        **train,
        "services": services[:20],
    }

    # Add GPU info if available
    gpu = get_gpu_info()
    if gpu:
        result.update(gpu)

    return result


def is_allowed(cmd):
    for entry in ALLOWED_COMMANDS:
        if cmd == entry or cmd.startswith(entry + " "):
            return True
    return not ALLOWED_COMMANDS  # open access if no whitelist


class FleetHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # quiet

    def _send(self, code, body):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())

    def _check_auth(self):
        if TOKEN is None:
            return True
        req_token = self.headers.get("X-Fleet-Token", "").strip().replace("\r", "")
        if req_token != TOKEN:
            self._send(403, {"error": "unauthorized"})
            return False
        return True

    def do_GET(self):
        if not self._check_auth():
            return
        if self.path == "/health":
            self._send(200, {"alive": True, "uptime": int(time.time() - START_TIME)})
        elif self.path == "/status":
            self._send(200, get_status())
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if not self._check_auth():
            return
        if self.path == "/exec":
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length).decode() if length else ""
            try:
                data = json.loads(body)
            except json.JSONDecodeError:
                self._send(400, {"error": "invalid json"})
                return
            cmd = data.get("cmd", "")
            if not cmd:
                self._send(400, {"error": "missing cmd"})
                return
            if not is_allowed(cmd):
                self._send(403, {"error": "command not whitelisted"})
                return
            output, exit_code = run_cmd(cmd)
            self._send(200, {"output": output, "exit_code": exit_code})
        else:
            self._send(404, {"error": "not found"})


if __name__ == "__main__":
    port = PORT
    if "--port" in sys.argv:
        idx = sys.argv.index("--port")
        port = int(sys.argv[idx + 1])

    load_config()
    os.makedirs(FLEET_DIR, exist_ok=True)

    # Write default token if none exists
    token_path = os.path.join(FLEET_DIR, "token")
    if not os.path.exists(token_path):
        print(f"[fleet] No token found, creating {token_path}")
        open(token_path, "w").write("fleet-test-token-2026\n")
        TOKEN = "fleet-test-token-2026"

    # Write default allowed_commands if none exists
    cmds_path = os.path.join(FLEET_DIR, "allowed_commands")
    if not os.path.exists(cmds_path):
        print(f"[fleet] No allowed_commands found, creating {cmds_path}")
        open(cmds_path, "w").write("nvidia-smi\ntasklist\ndir\nwhoami\n")
        ALLOWED_COMMANDS = ["nvidia-smi", "tasklist", "dir", "whoami"]

    server = http.server.HTTPServer(("0.0.0.0", port), FleetHandler)
    print(f"[fleet] agent listening on :{port} (token={'set' if TOKEN else 'open'})")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[fleet] shutdown")
