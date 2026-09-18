#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description="Request a safe RNA-seq pipeline stop")
    parser.add_argument("output_dir")
    args = parser.parse_args()
    stop = Path(args.output_dir).expanduser().resolve() / ".rnaseq_suite" / "STOP_REQUESTED"
    stop.parent.mkdir(parents=True, exist_ok=True)
    stop.write_text("Stop requested by user.\n", encoding="utf-8")
    print(f"Stop request written: {stop}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
