from __future__ import annotations

import json
import os
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


class EventWriter:
    def __init__(self, state_dir: Path) -> None:
        self.state_dir = state_dir
        self.state_dir.mkdir(parents=True, exist_ok=True)
        self.events_path = self.state_dir / "events.jsonl"
        self.state_path = self.state_dir / "state.json"
        self._lock = threading.Lock()
        self._state: dict[str, Any] = {
            "status": "initializing",
            "stage": "",
            "message": "",
            "percent": 0,
            "step_current": 0,
            "step_total": 0,
            "steps_remaining": 0,
            "updated_at": utc_now(),
        }

    def emit(
        self,
        event: str,
        message: str,
        *,
        stage: str = "",
        status: str | None = None,
        percent: int | None = None,
        step_current: int | None = None,
        step_total: int | None = None,
        details: dict[str, Any] | None = None,
    ) -> None:
        payload: dict[str, Any] = {
            "time": utc_now(),
            "event": event,
            "stage": stage,
            "message": message,
        }
        if status is not None:
            payload["status"] = status
        if percent is not None:
            payload["percent"] = max(0, min(100, int(percent)))
        if step_current is not None:
            payload["step_current"] = max(0, int(step_current))
        if step_total is not None:
            payload["step_total"] = max(0, int(step_total))
        if step_current is not None or step_total is not None:
            current = payload.get("step_current", self._state.get("step_current", 0))
            total = payload.get("step_total", self._state.get("step_total", 0))
            payload["steps_remaining"] = max(0, int(total) - int(current))
        if details:
            payload["details"] = details

        with self._lock:
            with self.events_path.open("a", encoding="utf-8") as handle:
                handle.write(json.dumps(payload, ensure_ascii=False) + "\n")

            self._state.update(
                {
                    "stage": stage or self._state.get("stage", ""),
                    "message": message,
                    "updated_at": payload["time"],
                }
            )
            if status is not None:
                self._state["status"] = status
            if percent is not None:
                self._state["percent"] = payload["percent"]
            if step_current is not None:
                self._state["step_current"] = payload["step_current"]
            if step_total is not None:
                self._state["step_total"] = payload["step_total"]
            if step_current is not None or step_total is not None:
                self._state["steps_remaining"] = payload["steps_remaining"]
            self._write_state()

    def _write_state(self) -> None:
        temp_path = self.state_path.with_suffix(".json.tmp")
        with temp_path.open("w", encoding="utf-8") as handle:
            json.dump(self._state, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
        os.replace(temp_path, self.state_path)
