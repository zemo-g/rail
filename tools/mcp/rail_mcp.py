#!/usr/bin/env python3
"""rail_mcp.py — MCP server exposing Rail compiler, bench, and flywheel as tools.

Lets Claude Code directly compile Rail code, run benchmarks, check training
progress, and manage the fleet — no manual SSH or shell commands needed.

Usage:
  Add to Claude Code settings.json:
  {
    "mcpServers": {
      "rail": {
        "command": "/opt/homebrew/bin/python3.11",
        "args": ["/Users/ledaticempire/projects/rail/tools/mcp/rail_mcp.py"]
      }
    }
  }

  Then in Claude Code: "compile this Rail code" → tool call → result
"""

import json
import subprocess
import sys
import os
import tempfile
import time

RAIL_DIR = os.path.expanduser("~/projects/rail")
RAIL_BIN = os.path.join(RAIL_DIR, "rail_native")
RAZER_HOST = "Detro@100.109.63.37"


def run(cmd, timeout=30, cwd=None):
    """Run a shell command, return (stdout, stderr, returncode)."""
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True,
                           timeout=timeout, cwd=cwd or RAIL_DIR)
        return r.stdout, r.stderr, r.returncode
    except subprocess.TimeoutExpired:
        return "", "timeout", 1


# ── Tool implementations ──────────────────────────────────────────────

def tool_compile(code: str) -> dict:
    """Compile Rail code and optionally run the binary."""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.rail', delete=False, dir='/tmp') as f:
        f.write(code)
        path = f.name

    stdout, stderr, rc = run(f"{RAIL_BIN} {path}", timeout=30)
    result = {"compiled": rc == 0, "compiler_output": (stdout + stderr).strip()}

    if rc == 0:
        # Try to run the binary
        run_out, run_err, run_rc = run("timeout 5 /tmp/rail_out", timeout=10)
        result["ran"] = run_rc == 0
        result["output"] = run_out.strip()
        if run_rc != 0:
            result["runtime_error"] = run_err.strip()

        # Quality metrics
        size_out, _, _ = run("stat -f%z /tmp/rail_out")
        result["binary_size"] = int(size_out.strip()) if size_out.strip().isdigit() else 0

    os.unlink(path)
    return result


def tool_test() -> dict:
    """Run the 67-test suite."""
    stdout, stderr, rc = run(f"{RAIL_BIN} test", timeout=120)
    output = stdout + stderr
    # Extract pass count from last line
    lines = output.strip().split('\n')
    last = lines[-1] if lines else ""
    return {"passed": rc == 0, "summary": last, "full_output": output[-2000:]}


def tool_bench() -> dict:
    """Run the 30-task benchmark."""
    stdout, stderr, rc = run(f"{RAIL_BIN} run flywheel/bench.rail", timeout=300)
    output = stdout + stderr
    # Read bench log for latest result
    log, _, _ = run("tail -3 flywheel/bench_log.txt")
    return {"output": output[-2000:], "log": log.strip()}


def tool_self_train_status() -> dict:
    """Check self-training progress."""
    progress, _, _ = run("cat training/self_train/progress.txt")
    log, _, _ = run("tail -10 training/self_train/log.txt")
    harvest_count, _, _ = run("wc -l < training/self_train/harvest.jsonl")
    return {
        "progress": progress.strip(),
        "recent_rounds": log.strip(),
        "harvest_count": harvest_count.strip()
    }


def tool_fleet_status() -> dict:
    """Check all fleet nodes."""
    result = {"mini": {}, "razer": {}}

    # Mini (local)
    mlx_out, _, _ = run("curl -s -m 3 http://localhost:8080/v1/models 2>/dev/null | head -1")
    st_pid, _, _ = run("pgrep -f rail_st_bin || echo none")
    result["mini"] = {
        "mlx_server": "up" if mlx_out.strip() else "down",
        "self_train": "running" if st_pid.strip() != "none" else "stopped"
    }

    # Razer
    gpu_out, _, rc = run(f"ssh -o ConnectTimeout=5 {RAZER_HOST} 'nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total --format=csv,noheader 2>/dev/null'", timeout=10)
    if rc == 0 and gpu_out.strip():
        result["razer"] = {"status": "up", "gpu": gpu_out.strip()}
    else:
        result["razer"] = {"status": "unreachable"}

    # Check Razer training
    train_log, _, rc = run(f"ssh -o ConnectTimeout=5 {RAZER_HOST} 'tail -3 ~/rail_training/v6_train.log 2>/dev/null'", timeout=10)
    if rc == 0:
        result["razer"]["training_log"] = train_log.strip()

    return result


def tool_data_stats() -> dict:
    """Show training data statistics."""
    sources = [
        "training/train.jsonl",
        "training/real_programs.jsonl",
        "training/git_harvest.jsonl",
        "training/handcrafted_l2_l5.jsonl",
        "training/self_train/harvest.jsonl",
        "training/self_train/harvest_clean.jsonl",
        "training/self_train/repairs.jsonl",
        "training/self_train/synthetic_repairs.jsonl",
        "training/self_train/cloud_harvest.jsonl",
        "training/self_train/evolved.jsonl",
    ]
    stats = {}
    for src in sources:
        count, _, rc = run(f"wc -l < {src} 2>/dev/null")
        if rc == 0 and count.strip():
            stats[os.path.basename(src)] = int(count.strip())
    # Merged data
    for split in ["train", "valid", "test"]:
        count, _, rc = run(f"wc -l < /tmp/rail_flywheel_data/{split}.jsonl 2>/dev/null")
        if rc == 0 and count.strip():
            stats[f"merged_{split}"] = int(count.strip())
    return stats


def tool_run_file(path: str) -> dict:
    """Compile and run a .rail file."""
    stdout, stderr, rc = run(f"{RAIL_BIN} run {path}", timeout=60)
    return {"success": rc == 0, "output": (stdout + stderr).strip()[-2000:]}


# ── MCP protocol ──────────────────────────────────────────────────────

TOOLS = {
    "rail_compile": {
        "description": "Compile Rail code and run the binary. Returns compile status, output, and binary size.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "code": {"type": "string", "description": "Rail source code to compile"}
            },
            "required": ["code"]
        },
        "fn": lambda args: tool_compile(args["code"])
    },
    "rail_test": {
        "description": "Run Rail's 67-test suite. Returns pass/fail summary.",
        "inputSchema": {
            "type": "object",
            "properties": {}
        },
        "fn": lambda args: tool_test()
    },
    "rail_bench": {
        "description": "Run the 30-task benchmark across 6 difficulty bands.",
        "inputSchema": {
            "type": "object",
            "properties": {}
        },
        "fn": lambda args: tool_bench()
    },
    "rail_self_train_status": {
        "description": "Check self-training progress: round, level, pass rates, harvest count.",
        "inputSchema": {
            "type": "object",
            "properties": {}
        },
        "fn": lambda args: tool_self_train_status()
    },
    "rail_fleet_status": {
        "description": "Check fleet status: Mini (MLX server, self-train), Razer (GPU, training).",
        "inputSchema": {
            "type": "object",
            "properties": {}
        },
        "fn": lambda args: tool_fleet_status()
    },
    "rail_data_stats": {
        "description": "Show training data statistics across all JSONL sources.",
        "inputSchema": {
            "type": "object",
            "properties": {}
        },
        "fn": lambda args: tool_data_stats()
    },
    "rail_run_file": {
        "description": "Compile and run a .rail file from the repo.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Path to .rail file (relative to repo root)"}
            },
            "required": ["path"]
        },
        "fn": lambda args: tool_run_file(args["path"])
    },
}


def handle_request(req):
    """Handle a single JSON-RPC request."""
    method = req.get("method", "")
    params = req.get("params", {})
    req_id = req.get("id")

    if method == "initialize":
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "rail-mcp", "version": "1.0.0"}
            }
        }

    elif method == "notifications/initialized":
        return None  # No response needed

    elif method == "tools/list":
        tool_list = []
        for name, spec in TOOLS.items():
            tool_list.append({
                "name": name,
                "description": spec["description"],
                "inputSchema": spec["inputSchema"]
            })
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {"tools": tool_list}
        }

    elif method == "tools/call":
        tool_name = params.get("name", "")
        arguments = params.get("arguments", {})

        if tool_name not in TOOLS:
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "error": {"code": -32601, "message": f"Unknown tool: {tool_name}"}
            }

        try:
            result = TOOLS[tool_name]["fn"](arguments)
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "content": [{"type": "text", "text": json.dumps(result, indent=2)}]
                }
            }
        except Exception as e:
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "content": [{"type": "text", "text": f"Error: {str(e)}"}],
                    "isError": True
                }
            }

    elif method == "ping":
        return {"jsonrpc": "2.0", "id": req_id, "result": {}}

    else:
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "error": {"code": -32601, "message": f"Method not found: {method}"}
        }


def main():
    """Run MCP server on stdin/stdout (JSON-RPC over stdio)."""
    sys.stderr.write("rail-mcp: starting\n")

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue

        response = handle_request(req)
        if response is not None:
            sys.stdout.write(json.dumps(response) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
