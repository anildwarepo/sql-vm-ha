#!/usr/bin/env python3
"""Start the SQL control plane: FastAPI backend + React UI.

    python run_all.py              # dev: API on :8000 (Swagger /docs), Vite UI with hot reload on :5173
    python run_all.py --prod       # build the UI and serve it from the API on a single port (:8000)
    python run_all.py --api-only   # just the API

Missing dependencies are installed on first run (uv sync for the backend, npm install for the UI).
Press Ctrl+C to stop everything.
"""

from __future__ import annotations

import argparse
import io
import os
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.request
import webbrowser
from pathlib import Path

ROOT = Path(__file__).resolve().parent
BACKEND = ROOT / "backend"
FRONTEND = ROOT / "frontend"
IS_WINDOWS = os.name == "nt"
VENV_PY = BACKEND / ".venv" / ("Scripts/python.exe" if IS_WINDOWS else "bin/python")
COLORS = {"api": "\033[36m", "ui": "\033[35m", "run": "\033[33m"}
RESET = "\033[0m"


def log(tag: str, msg: str) -> None:
    color = COLORS.get(tag, "") if sys.stdout.isatty() else ""
    try:
        print(f"{color}[{tag}]{RESET if color else ''} {msg}", flush=True)
    except (UnicodeError, OSError):
        pass


def which(cmd: str) -> str:
    path = shutil.which(cmd)
    if not path:
        sys.exit(f"'{cmd}' was not found on PATH. Install it and retry.")
    return path


def run_step(tag: str, args: list[str], cwd: Path) -> None:
    log(tag, "$ " + " ".join(Path(args[0]).name if i == 0 else a for i, a in enumerate(args)))
    if subprocess.run(args, cwd=cwd).returncode != 0:
        sys.exit(f"[{tag}] command failed: {' '.join(args)}")


def ensure_deps(skip: bool) -> None:
    if skip:
        return
    if not VENV_PY.exists():
        # Honours UV_DEFAULT_INDEX / UV_INDEX_URL from the environment for private package feeds.
        run_step("api", [which("uv"), "sync"], BACKEND)
    if not (FRONTEND / "node_modules").is_dir():
        run_step("ui", [which("npm"), "install"], FRONTEND)


def port_free(port: int) -> bool:
    with socket.socket() as s:
        return s.connect_ex(("127.0.0.1", port)) != 0


def spawn(tag: str, args: list[str], cwd: Path, env: dict[str, str]) -> subprocess.Popen:
    kwargs: dict = {}
    if IS_WINDOWS:
        # Own process group, so Ctrl+C doesn't trigger npm's "Terminate batch job?" prompt; we stop the tree ourselves.
        kwargs["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP
    else:
        kwargs["start_new_session"] = True
    proc = subprocess.Popen(args, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            stdin=subprocess.DEVNULL, text=True, encoding="utf-8", errors="replace", bufsize=1, **kwargs)

    def pump() -> None:
        assert proc.stdout
        for line in proc.stdout:
            log(tag, line.rstrip())

    threading.Thread(target=pump, daemon=True).start()
    return proc


def stop(proc: subprocess.Popen) -> None:
    if proc.poll() is not None:
        return
    if IS_WINDOWS:
        subprocess.run(["taskkill", "/T", "/F", "/PID", str(proc.pid)], capture_output=True)
    else:
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()


def wait_http(url: str, procs: list[subprocess.Popen], timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if any(p.poll() is not None for p in procs):
            return False
        try:
            with urllib.request.urlopen(url, timeout=2) as r:
                if r.status < 500:
                    return True
        except Exception:
            pass
        time.sleep(0.5)
    return False


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--prod", action="store_true", help="build the UI and serve it from the API on one port")
    ap.add_argument("--api-only", action="store_true", help="start only the backend API")
    ap.add_argument("--api-port", type=int, default=int(os.environ.get("SQLHA_API_PORT", 8000)))
    ap.add_argument("--ui-port", type=int, default=int(os.environ.get("SQLHA_UI_PORT", 5173)))
    ap.add_argument("--no-browser", action="store_true", help="don't open the browser")
    ap.add_argument("--skip-install", action="store_true", help="don't install missing dependencies")
    args = ap.parse_args()

    # Child output (Vite, uvicorn) contains non-ASCII; never let a legacy console code page crash the relay.
    if isinstance(sys.stdout, io.TextIOWrapper):
        if sys.stdout.isatty():
            sys.stdout.reconfigure(errors="replace")
        else:
            sys.stdout.reconfigure(encoding="utf-8", errors="replace")

    os.chdir(ROOT)
    ensure_deps(args.skip_install)
    with_ui = not args.api_only and not args.prod

    for port, what in [(args.api_port, "API")] + ([(args.ui_port, "UI")] if with_ui else []):
        if not port_free(port):
            sys.exit(f"Port {port} ({what}) is already in use. Stop the other process or pass --{what.lower()}-port.")

    if args.prod:
        run_step("ui", [which("npm"), "run", "build"], FRONTEND)

    api_url = f"http://127.0.0.1:{args.api_port}"
    ui_url = f"http://127.0.0.1:{args.ui_port}" if with_ui else api_url

    env = {**os.environ, "PYTHONUNBUFFERED": "1", "PYTHONIOENCODING": "utf-8",
           "SQLHA_API_PORT": str(args.api_port), "SQLHA_API_URL": api_url, "SQLHA_CONTROLPLANE_API": api_url}
    if with_ui:
        env.setdefault("SQLHA_CORS_ORIGINS", f"http://127.0.0.1:{args.ui_port},http://localhost:{args.ui_port}")

    procs: list[subprocess.Popen] = []
    try:
        procs.append(spawn("api", [str(VENV_PY), "-m", "app"], BACKEND, env))
        if with_ui:
            procs.append(spawn("ui", [which("npm"), "run", "dev", "--", "--port", str(args.ui_port)], FRONTEND, env))

        log("run", "waiting for the API...")
        if not wait_http(f"{api_url}/api/health", procs, 60):
            log("run", "API did not become healthy; see the [api] output above.")
            return 1
        if with_ui and not wait_http(ui_url, procs, 60):
            log("run", "UI dev server did not start; see the [ui] output above.")
            return 1

        log("run", f"UI       {ui_url}")
        log("run", f"API      {api_url}/api")
        log("run", f"Swagger  {api_url}/docs")
        log("run", "Ctrl+C to stop.")
        if not args.no_browser and not args.api_only:
            webbrowser.open(ui_url)

        while all(p.poll() is None for p in procs):
            time.sleep(0.5)
        log("run", "a process exited; shutting down.")
        return 1
    except KeyboardInterrupt:
        log("run", "stopping...")
        return 0
    finally:
        for p in reversed(procs):
            stop(p)


if __name__ == "__main__":
    sys.exit(main())
