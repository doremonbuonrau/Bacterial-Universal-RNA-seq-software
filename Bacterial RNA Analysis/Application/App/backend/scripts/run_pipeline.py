#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
import traceback
from pathlib import Path

BACKEND_ROOT = Path(__file__).resolve().parents[1]
if str(BACKEND_ROOT) not in sys.path:
    sys.path.insert(0, str(BACKEND_ROOT))

from rnaseq_suite.config import ConfigError, load_config, validate_config  # noqa: E402
from rnaseq_suite.paths import runtime_path  # noqa: E402
from rnaseq_suite.runner import CommandFailed, PipelineStopped  # noqa: E402


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Run the Bacterial RNA Analysis preprocessing pipeline."
    )
    parser.add_argument("--config", required=True, help="Project JSON configuration file")
    parser.add_argument(
        "--validate-only",
        action="store_true",
        help="Validate configuration and inputs without creating an analysis",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Create a complete command plan without executing external bioinformatics tools",
    )
    return parser


def main() -> int:
    args = build_parser().parse_args()
    config = None

    def record_startup_error(message: str) -> None:
        if not isinstance(config, dict):
            return
        raw_output = str(config.get("project", {}).get("output_dir", "")).strip()
        if not raw_output:
            return
        try:
            log = runtime_path(raw_output) / "00_project" / "logs" / "pipeline.log"
            log.parent.mkdir(parents=True, exist_ok=True)
            with log.open("a", encoding="utf-8") as handle:
                handle.write(f"ERROR: {message}\n")
        except OSError:
            pass

    try:
        config = load_config(args.config)
        warnings = validate_config(config, check_paths=not args.dry_run)
        if args.validate_only:
            print(json.dumps({"valid": True, "warnings": warnings}, indent=2, ensure_ascii=False))
            return 0
        from rnaseq_suite.pipeline import Pipeline

        pipeline = Pipeline(config, dry_run=args.dry_run)
        output = pipeline.run()
        cleanup_warnings = pipeline.finalize_runtime_state(runtime_path(args.config))
        for cleanup_warning in cleanup_warnings:
            print(f"CLEANUP WARNING\n{cleanup_warning}", file=sys.stderr)
        result_root = pipeline.run_root if not args.dry_run and not cleanup_warnings else output
        print(json.dumps({"status": "complete", "result_root": str(result_root), "analysis_ready": str(result_root)}, ensure_ascii=False))
        return 0
    except ConfigError as exc:
        record_startup_error(str(exc))
        print(f"CONFIGURATION ERROR\n{exc}", file=sys.stderr)
        return 2
    except PipelineStopped as exc:
        print(f"STOPPED\n{exc}", file=sys.stderr)
        return 130
    except (CommandFailed, OSError) as exc:
        record_startup_error(str(exc))
        print(f"PIPELINE ERROR\n{exc}", file=sys.stderr)
        return 1
    except Exception as exc:  # preserve unexpected initialization details in the run log
        details = "".join(traceback.format_exception(type(exc), exc, exc.__traceback__))
        record_startup_error(details)
        print(f"UNEXPECTED PIPELINE ERROR\n{details}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("STOPPED\nInterrupted by user.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
