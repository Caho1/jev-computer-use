#!/usr/bin/env python3
"""One host call owns the bounded observe/decide/act loop."""
import argparse
import getpass
import json
import os
import platform
import selectors
import subprocess
import sys
import time
from pathlib import Path
from jev import JevClient, Halt, make_request, choose, completed, validate_task, clean_metrics

HERE = Path(__file__).resolve().parent


def record(trace, row):
    safe_row = clean_metrics(row)
    print(json.dumps(safe_row), flush=True)
    if trace:
        trace.write(json.dumps(safe_row) + "\n")
        trace.flush()


def binary():
    if platform.system() != "Darwin":
        raise Halt("Native AX execution requires macOS; this environment is " + platform.system())
    path = Path.home() / "Library/Caches/jev-mac-use/axbridge"
    if not path.is_file():
        raise Halt("Run scripts/build.sh on this Mac first")
    return path


class Bridge:
    def __init__(self, bundle_id):
        env = os.environ.copy()
        env.pop("TYPESAFE_API_KEY", None)
        self.proc = subprocess.Popen([str(binary()), bundle_id], stdin=subprocess.PIPE,
                                      stdout=subprocess.PIPE, stderr=None, text=True, bufsize=1, env=env)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.proc.stdout, selectors.EVENT_READ)

    def request(self, command):
        try:
            self.proc.stdin.write(json.dumps(command, ensure_ascii=False) + "\n")
            self.proc.stdin.flush()
            if not self.selector.select(15):
                self.proc.kill()
                raise Halt("AX helper timed out; stopped")
            line = self.proc.stdout.readline()
            data = json.loads(line)
        except (OSError, ValueError):
            raise Halt("AX helper exited or returned invalid data") from None
        if not data.get("ok"):
            raise Halt("AX: " + str(data.get("error", "unknown error")))
        return data

    def close(self):
        self.selector.close()
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()


def run(task, client, bridge, mode, max_steps, max_seconds, execute, trace=None):
    validate_task(task)
    started, history = time.monotonic(), []
    attempts, stagnant, waits = {}, 0, 0
    last_digest = None
    for step in range(max_steps):
        loop_start = time.perf_counter()
        if time.monotonic() - started >= max_seconds:
            return {"status": "time_budget"}
        snap = bridge.request({"cmd": "snapshot", "include_menu": task.get("include_menu", False)})
        if snap["bundle_id"] != task["bundle_id"]:
            raise Halt("App identity changed")
        if completed(snap, task):
            return {"status": "verified", "steps": step}
        if snap.get("digest") == last_digest:
            stagnant += 1
        else:
            stagnant = 0
        if stagnant >= 3:
            return {"status": "no_progress", "steps": step}
        last_digest = snap.get("digest")
        state, questions, candidates = make_request(snap, task, history, mode)
        data, timing = client.evaluate(state, questions)
        status, action, probability = choose(data, questions, candidates, mode)
        row = {"step": step, "status": status, "observe_ms": snap.get("observe_ms"),
               "candidate_count": len(candidates), **timing, **probability}
        if time.monotonic() - started >= max_seconds:
            return {"status": "time_budget", "steps": step}
        if status in {"DONE", "BLOCKED"}:
            # Never call an unverified model assertion a successful task.
            result = {"status": "needs_host_verification" if status == "DONE" else "blocked", "steps": step}
        elif status == "WAIT":
            waits += 1
            if waits > 3:
                return {"status": "wait_budget", "steps": step}
            bridge.request({"cmd": "settle", "timeout_ms": 500})
            result = None
        else:
            row["op"], row["target"] = action.op, action.target
            if not execute:
                print(json.dumps({"proposed_action": action.key, "op": action.op,
                                  "target": action.target}, ensure_ascii=False))
                result = {"status": "preview", "steps": step}
            else:
                key = (snap.get("digest"), action.op, action.target, action.text)
                if attempts.get(key, 0) >= 1:
                    return {"status": "repeated_action", "steps": step}
                attempts[key] = attempts.get(key, 0) + 1
                action_started = time.perf_counter()
                try:
                    response = bridge.request({"cmd": "act", "snapshot": snap["snapshot"],
                                               "target": action.target, "op": action.op, "text": action.text})
                except Halt as e:
                    row.update(status="action_failed", error=str(e),
                               execute_ms=round((time.perf_counter()-action_started)*1000, 3),
                               loop_ms=round((time.perf_counter()-loop_start)*1000, 3))
                    record(trace, row)
                    raise
                row["execute_ms"] = response.get("execute_ms")
                settled = bridge.request({"cmd": "settle", "timeout_ms": 600})
                row["settle_ms"] = settled.get("settle_ms")
                history.append({"op": action.op, "target": action.target, "result": "AX accepted"})
                result = None
        row["loop_ms"] = round((time.perf_counter() - loop_start) * 1000, 3)
        record(trace, row)
        if result:
            return result
    # Verify the last allowed action too.
    snap = bridge.request({"cmd": "snapshot", "include_menu": task.get("include_menu", False)})
    if snap["bundle_id"] != task["bundle_id"]:
        raise Halt("App identity changed")
    return {"status": "verified" if completed(snap, task) else "step_budget", "steps": max_steps}


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("doctor")
    observe = sub.add_parser("observe")
    observe.add_argument("--app", required=True)
    observe.add_argument("--include-menu", action="store_true")
    execute = sub.add_parser("run")
    execute.add_argument("--task", required=True)
    execute.add_argument("--execute", action="store_true")
    execute.add_argument("--ask-key", action="store_true")
    execute.add_argument("--mode", choices=["flat", "fanout"], default="flat")
    execute.add_argument("--max-steps", type=int, default=12)
    execute.add_argument("--max-seconds", type=float, default=60)
    execute.add_argument("--trace")
    args = parser.parse_args()
    bridge = client = trace = None
    try:
        if args.command == "doctor":
            print(json.dumps({"platform": platform.system(), "native_supported": platform.system() == "Darwin",
                              "key_present": bool(os.environ.get("TYPESAFE_API_KEY"))}))
            if platform.system() == "Darwin":
                subprocess.run([str(binary()), "--doctor"], check=True)
            return
        if args.command == "observe":
            bridge = Bridge(args.app)
            print(json.dumps(bridge.request({"cmd": "snapshot", "include_menu": args.include_menu}), ensure_ascii=False, indent=2))
            return
        task = json.loads(Path(args.task).read_text())
        validate_task(task)
        if not 1 <= args.max_steps <= 100 or not 1 <= args.max_seconds <= 600:
            raise Halt("Use 1..100 steps and 1..600 seconds")
        bridge = Bridge(task["bundle_id"])
        key = getpass.getpass("TypeSafe API key (hidden): ") if args.ask_key else None
        client = JevClient(key=key)
        if args.trace:
            fd = os.open(args.trace, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            trace = os.fdopen(fd, "w")
        # Warm the connection before capturing expiring AX handles.
        _, warmup = client.evaluate("Connection warmup.", {"ready": {
            "type": "noul", "instructions": "Does the state contain the word warmup?"}})
        record(trace, {"event": "warmup", "api_ms": warmup["api_ms"], "usage": warmup["usage"], "model": warmup["model"]})
        result = run(task, client, bridge, args.mode, args.max_steps, args.max_seconds, args.execute, trace)
        record(trace, {"event": "result", **result})
        if result["status"] not in {"verified", "preview"}:
            sys.exit(2)
    except (Halt, ValueError, OSError) as e:
        if trace:
            record(trace, {"event": "error", "status": "stopped", "error": str(e)})
        print(json.dumps({"status": "stopped", "error": str(e)}), file=sys.stderr)
        sys.exit(2)
    finally:
        if bridge: bridge.close()
        if client: client.close()
        if trace: trace.close()


if __name__ == "__main__":
    main()
