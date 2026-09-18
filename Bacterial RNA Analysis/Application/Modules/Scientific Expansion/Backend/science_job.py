#!/usr/bin/env python3
"""Supervise one scientific job; cancellation never affects other WSL work."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def run(backend: str, cancel_path: str, arguments: list[str]) -> int:
    cancel = Path(cancel_path)
    process = subprocess.Popen([sys.executable, '-u', backend, *arguments], start_new_session=True)
    stopped = False
    try:
        while process.poll() is None:
            if cancel.exists():
                stopped = True
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                print('Job cancelled by user.', flush=True)
                break
            time.sleep(0.1)
        return 130 if stopped else process.returncode
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)


if __name__ == '__main__':
    sys.exit(run(sys.argv[1], sys.argv[2], sys.argv[3:]))
