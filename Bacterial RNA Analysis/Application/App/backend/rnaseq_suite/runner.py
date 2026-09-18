from __future__ import annotations

import json
import os
import shlex
import shutil
import signal
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Mapping, Sequence

from .events import EventWriter, utc_now


class PipelineStopped(RuntimeError):
    pass


class CommandFailed(RuntimeError):
    pass


@dataclass
class CommandRecord:
    name: str
    command: list[str]
    cwd: str
    started_at: str
    finished_at: str | None = None
    return_code: int | None = None
    stdout_path: str | None = None


class CommandRunner:
    def __init__(
        self,
        run_root: Path,
        events: EventWriter,
        *,
        dry_run: bool = False,
    ) -> None:
        self.run_root = run_root
        self.events = events
        self.dry_run = dry_run
        self.logs_dir = run_root / "00_project" / "logs"
        self.logs_dir.mkdir(parents=True, exist_ok=True)
        self.pipeline_log = self.logs_dir / "pipeline.log"
        self.command_log = self.logs_dir / "commands.sh"
        self.plan_path = self.logs_dir / "command_plan.json"
        self.stop_file = run_root / ".rnaseq_suite" / "STOP_REQUESTED"
        self.records: list[CommandRecord] = []

    def check_stop(self) -> None:
        if self.stop_file.exists():
            raise PipelineStopped(
                "A stop request was detected. Completed outputs and checkpoints were preserved."
            )

    def require_tools(self, tools: Iterable[str]) -> None:
        missing = sorted({tool for tool in tools if tool and shutil.which(tool) is None})
        if missing and not self.dry_run:
            raise CommandFailed(
                "Required command(s) are missing from the analysis environment: "
                + ", ".join(missing)
            )

    def _record_command(self, name: str, command: Sequence[str], cwd: Path | None) -> CommandRecord:
        record = CommandRecord(
            name=name,
            command=[str(item) for item in command],
            cwd=str(cwd or Path.cwd()),
            started_at=utc_now(),
        )
        self.records.append(record)
        with self.command_log.open("a", encoding="utf-8", newline="\n") as handle:
            handle.write(f"# {name}\n")
            if cwd:
                handle.write(f"cd {shlex.quote(str(cwd))}\n")
            handle.write(shlex.join(record.command) + "\n\n")
        self._write_plan()
        return record

    def _write_plan(self) -> None:
        payload = [record.__dict__ for record in self.records]
        temp_path = self.plan_path.with_suffix(".json.tmp")
        with temp_path.open("w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
        os.replace(temp_path, self.plan_path)

    def _append_log(self, line: str) -> None:
        with self.pipeline_log.open("a", encoding="utf-8", newline="\n") as handle:
            handle.write(line.rstrip("\r\n") + "\n")
        print(line.rstrip("\r\n"), flush=True)

    def _terminate_active_process(self, process: subprocess.Popen[object], name: str) -> None:
        """Terminate one active command and its children after a user stop request."""
        if process.poll() is not None:
            return
        self._append_log(f"STOP REQUESTED: terminating active command {name}.")
        try:
            if os.name == "posix":
                os.killpg(process.pid, signal.SIGTERM)
            else:
                process.terminate()
        except (ProcessLookupError, PermissionError):
            pass
        except OSError:
            try:
                process.terminate()
            except OSError:
                pass

        deadline = time.monotonic() + 8.0
        while process.poll() is None and time.monotonic() < deadline:
            time.sleep(0.10)
        if process.poll() is None:
            self._append_log(f"STOP REQUESTED: {name} did not exit after SIGTERM; forcing termination.")
            try:
                if os.name == "posix":
                    os.killpg(process.pid, signal.SIGKILL)
                else:
                    process.kill()
            except (ProcessLookupError, PermissionError, OSError):
                try:
                    process.kill()
                except OSError:
                    pass

    def run(
        self,
        name: str,
        command: Sequence[str | os.PathLike[str]],
        *,
        cwd: Path | None = None,
        stdout_path: Path | None = None,
        env: Mapping[str, str] | None = None,
        check: bool = True,
    ) -> int:
        self.check_stop()
        normalized = [os.fspath(item) for item in command]
        record = self._record_command(name, normalized, cwd)
        if stdout_path is not None:
            stdout_path.parent.mkdir(parents=True, exist_ok=True)
            record.stdout_path = str(stdout_path)

        self.events.emit(
            "command_started",
            name,
            stage=name,
            status="running",
            details={"command": shlex.join(normalized)},
        )
        self._append_log(f"[{record.started_at}] START {name}")
        self._append_log(f"$ {shlex.join(normalized)}")

        if self.dry_run:
            record.return_code = 0
            record.finished_at = utc_now()
            self._append_log(f"[{record.finished_at}] DRY-RUN {name}")
            self._write_plan()
            return 0

        process_env = os.environ.copy()
        if env:
            process_env.update(env)

        output_handle = None
        process: subprocess.Popen[object] | None = None
        reader_thread: threading.Thread | None = None
        stop_requested = False
        try:
            if stdout_path is not None:
                output_handle = stdout_path.open("wb")
                process = subprocess.Popen(
                    normalized,
                    cwd=str(cwd) if cwd else None,
                    env=process_env,
                    stdout=output_handle,
                    stderr=subprocess.PIPE,
                    text=True,
                    bufsize=1,
                    start_new_session=(os.name == "posix"),
                )
                stream = process.stderr
            else:
                process = subprocess.Popen(
                    normalized,
                    cwd=str(cwd) if cwd else None,
                    env=process_env,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    bufsize=1,
                    start_new_session=(os.name == "posix"),
                )
                stream = process.stdout

            assert stream is not None

            def pump_output() -> None:
                try:
                    for output_line in stream:
                        self._append_log(output_line)
                except (OSError, ValueError):
                    pass

            reader_thread = threading.Thread(target=pump_output, name=f"log-{name}", daemon=True)
            reader_thread.start()

            while process.poll() is None:
                if self.stop_file.exists():
                    stop_requested = True
                    self._terminate_active_process(process, name)
                    break
                time.sleep(0.25)
            return_code = process.wait()
            if reader_thread is not None:
                reader_thread.join(timeout=3.0)
        except FileNotFoundError as exc:
            raise CommandFailed(f"Command not found while running {name}: {normalized[0]}") from exc
        finally:
            if output_handle is not None:
                output_handle.close()

        record.return_code = return_code
        record.finished_at = utc_now()
        self._write_plan()
        if stop_requested:
            self._append_log(f"[{record.finished_at}] STOPPED {name} (exit {return_code})")
            self.events.emit(
                "command_stopped",
                f"{name} stopped after user request",
                stage=name,
                status="stopped",
                details={"return_code": return_code},
            )
            raise PipelineStopped(
                "A stop request was detected. The active command was terminated and completed outputs/checkpoints were preserved."
            )

        self._append_log(f"[{record.finished_at}] END {name} (exit {return_code})")

        if check and return_code != 0:
            self.events.emit(
                "command_failed",
                f"{name} failed with exit code {return_code}",
                stage=name,
                status="error",
            )
            raise CommandFailed(f"{name} failed with exit code {return_code}. See {self.pipeline_log}")

        self.events.emit(
            "command_finished",
            name,
            stage=name,
            status="running",
            details={"return_code": return_code},
        )
        return return_code

    def run_shell(
        self,
        name: str,
        script: str,
        *,
        cwd: Path | None = None,
        check: bool = True,
    ) -> int:
        return self.run(name, ["bash", "-o", "pipefail", "-c", script], cwd=cwd, check=check)

    def capture(
        self,
        name: str,
        command: Sequence[str | os.PathLike[str]],
        *,
        cwd: Path | None = None,
        check: bool = True,
    ) -> str:
        self.check_stop()
        normalized = [os.fspath(item) for item in command]
        record = self._record_command(name, normalized, cwd)
        if self.dry_run:
            record.return_code = 0
            record.finished_at = utc_now()
            self._write_plan()
            return ""

        process: subprocess.Popen[str] | None = None
        stop_requested = False
        output = ""
        try:
            process = subprocess.Popen(
                normalized,
                cwd=str(cwd) if cwd else None,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                start_new_session=(os.name == "posix"),
            )
            while True:
                try:
                    output, _ = process.communicate(timeout=0.25)
                    break
                except subprocess.TimeoutExpired:
                    if self.stop_file.exists():
                        stop_requested = True
                        self._terminate_active_process(process, name)
                        output, _ = process.communicate()
                        break
        except FileNotFoundError as exc:
            raise CommandFailed(f"Command not found while running {name}: {normalized[0]}") from exc

        record.return_code = process.returncode if process is not None else -1
        record.finished_at = utc_now()
        self._write_plan()
        for line in output.splitlines():
            self._append_log(line)
        if stop_requested:
            self._append_log(f"[{record.finished_at}] STOPPED {name} (exit {record.return_code})")
            raise PipelineStopped(
                "A stop request was detected. The active command was terminated and completed outputs/checkpoints were preserved."
            )
        if check and record.return_code != 0:
            raise CommandFailed(f"{name} failed with exit code {record.return_code}.")
        return output


def quote(value: str | os.PathLike[str]) -> str:
    return shlex.quote(os.fspath(value))

