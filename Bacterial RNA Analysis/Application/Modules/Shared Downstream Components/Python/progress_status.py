#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import time
from pathlib import Path
from typing import Any


def _progress_path(explicit: str | os.PathLike[str] | None = None) -> Path | None:
    raw = os.fspath(explicit).strip() if explicit else os.environ.get("BRA_PROGRESS_FILE", "").strip()
    return Path(raw) if raw else None


def read_progress(path: str | os.PathLike[str] | None = None) -> dict[str, Any]:
    target = _progress_path(path)
    if target is None or not target.is_file():
        return {}
    try:
        value = json.loads(target.read_text(encoding="utf-8-sig"))
        return value if isinstance(value, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def update_progress(
    *,
    path: str | os.PathLike[str] | None = None,
    mode: str | None = None,
    status: str | None = None,
    overall_percent: float | int | None = None,
    phase: str | None = None,
    phase_percent: float | int | None = None,
    current: int | None = None,
    total: int | None = None,
    unit: str | None = None,
    detail: str | None = None,
) -> None:
    target = _progress_path(path)
    if target is None:
        return
    state = read_progress(target)
    if mode is not None:
        state["mode"] = str(mode)
    if status is not None:
        state["status"] = str(status)
    if overall_percent is not None:
        state["overall_percent"] = max(0.0, min(100.0, float(overall_percent)))
    if phase is not None:
        state["phase"] = str(phase)
    if phase_percent is not None:
        state["phase_percent"] = max(0.0, min(100.0, float(phase_percent)))
    if current is not None:
        state["current"] = max(0, int(current))
    if total is not None:
        state["total"] = max(0, int(total))
    if unit is not None:
        state["unit"] = str(unit)
    if detail is not None:
        state["detail"] = str(detail)
    state["updated_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_suffix(target.suffix + ".tmp")
    tmp.write_text(json.dumps(state, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    os.replace(tmp, target)


def main() -> int:
    parser = argparse.ArgumentParser(description="Write one atomic downstream GUI progress state")
    parser.add_argument("path")
    parser.add_argument("--mode")
    parser.add_argument("--status")
    parser.add_argument("--overall", type=float)
    parser.add_argument("--phase")
    parser.add_argument("--phase-percent", type=float)
    parser.add_argument("--current", type=int)
    parser.add_argument("--total", type=int)
    parser.add_argument("--unit")
    parser.add_argument("--detail")
    args = parser.parse_args()
    update_progress(
        path=args.path,
        mode=args.mode,
        status=args.status,
        overall_percent=args.overall,
        phase=args.phase,
        phase_percent=args.phase_percent,
        current=args.current,
        total=args.total,
        unit=args.unit,
        detail=args.detail,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
