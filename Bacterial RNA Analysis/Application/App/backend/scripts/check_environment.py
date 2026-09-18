#!/usr/bin/env python3
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

BACKEND_ROOT = Path(__file__).resolve().parents[1]
if str(BACKEND_ROOT) not in sys.path:
    sys.path.insert(0, str(BACKEND_ROOT))

from rnaseq_suite.config import ConfigError, load_config, validate_config  # noqa: E402
from rnaseq_suite.paths import runtime_path  # noqa: E402


CORE_TOOLS = ["python", "samtools", "featureCounts", "bamCoverage", "multiqc"]
CORE_PYTHON_PACKAGES = ["openpyxl"]
METHOD_TOOLS = {
    "fastqc_fastp_multiqc": ["fastqc", "fastp"],
    "fastqc_cutadapt_multiqc": ["fastqc", "cutadapt"],
    "qc_only": ["fastqc"],
    "bowtie2_accuracy": ["bowtie2", "bowtie2-build"],
    "dual_bowtie2_bwa": ["bowtie2", "bowtie2-build", "bwa-mem2"],
    "dual_bowtie2_hisat2": ["bowtie2", "bowtie2-build", "hisat2", "hisat2-build"],
    "bwa_mem2": ["bwa-mem2"],
    "hisat2_no_splice": ["hisat2", "hisat2-build"],
    "dorado_sup": ["dorado"],
    "dorado_hac": ["dorado"],
    "nanoplot_longqc": ["NanoPlot", "longQC.py"],
    "nanoplot": ["NanoPlot"],
    "long_qc_only": ["NanoPlot"],
    "minimap2": ["minimap2"],
    "dual_minimap2_winnowmap": ["minimap2", "winnowmap", "meryl"],
    "winnowmap2": ["winnowmap", "meryl"],
    "featurecounts_fadu_audit": ["featureCounts"],
    "featurecounts": ["featureCounts"],
    "fadu": ["julia", "fadu.jl"],
    "htseq": ["htseq-count"],
    "raw_and_cpm_stranded": ["bamCoverage"],
    "raw_unstranded": ["bamCoverage"],
}


def tool_version(path: str) -> str:
    for flag in ("--version", "-V", "-v", "version"):
        try:
            result = subprocess.run(
                [path, flag],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=8,
                check=False,
            )
            value = " ".join(result.stdout.splitlines()[:2]).strip()
            if result.returncode == 0 and value:
                return value
        except (OSError, subprocess.TimeoutExpired):
            continue
    return ""


def resolve_special(tool: str, app_root: Path, config: dict[str, Any] | None) -> str | None:
    if tool == "fadu.jl":
        candidates = [
            Path(os.environ["FADU_HOME"]) / "fadu.jl" if os.environ.get("FADU_HOME") else None,
            app_root / "tools" / "FADU" / "fadu.jl",
        ]
        return next((str(path) for path in candidates if path and path.is_file()), None)
    if tool == "longQC.py":
        candidates = [
            Path(os.environ["LONGQC_HOME"]) / "longQC.py" if os.environ.get("LONGQC_HOME") else None,
            app_root / "tools" / "LongQC" / "longQC.py",
        ]
        return next((str(path) for path in candidates if path and path.is_file()), None)
    if tool == "dorado" and config:
        configured = str(config.get("options", {}).get("dorado_path", "")).strip()
        if configured and configured != "dorado":
            candidate = runtime_path(configured)
            if candidate.is_file():
                return str(candidate)
    return shutil.which(tool)


def main() -> int:
    parser = argparse.ArgumentParser(description="Check the RNA-seq execution environment")
    parser.add_argument("--config", help="Optional project JSON to check only selected methods")
    parser.add_argument("--analysis-type", choices=("short", "long", "both"), help="Check the tool family required by a read type without requiring project inputs")
    parser.add_argument("--json", action="store_true", help="Print JSON")
    parser.add_argument("--report-file", help=argparse.SUPPRESS)
    args = parser.parse_args()

    config = load_config(args.config) if args.config else None
    config_valid = True
    config_warnings: list[str] = []
    config_error = ""
    if config:
        try:
            config_warnings = validate_config(config)
        except ConfigError as exc:
            config_valid = False
            config_error = str(exc)
    app_root = Path(__file__).resolve().parents[2]
    requested = set(CORE_TOOLS)
    if config:
        methods = config.get("methods", {})
        analysis_type = str(config.get("project", {}).get("analysis_type", ""))
        relevant = ["quantification", "coverage"]
        if analysis_type in {"short", "both"}:
            relevant.extend(["short_qc", "short_alignment"])
        if analysis_type in {"long", "both"}:
            relevant.extend(["long_qc", "long_alignment"])
            has_pod5 = any(
                str(sample.get("pod5_dir", "")).strip()
                for sample in config.get("samples", [])
                if isinstance(sample, dict) and sample.get("include", True) is not False
            )
            if has_pod5:
                relevant.append("long_basecalling")
        for method_group in relevant:
            selection = str(methods.get(method_group, ""))
            if analysis_type == "long" and selection == "featurecounts_fadu_audit":
                requested.add("featureCounts")
            else:
                requested.update(METHOD_TOOLS.get(selection, []))
    elif args.analysis_type:
        if args.analysis_type in {"short", "both"}:
            requested.update([
                "fastqc", "fastp", "cutadapt",
                "bowtie2", "bowtie2-build", "bwa-mem2",
                "hisat2", "hisat2-build",
            ])
        if args.analysis_type in {"long", "both"}:
            requested.update(["NanoPlot", "minimap2", "winnowmap", "meryl"])
    else:
        requested.update(["fastqc", "fastp", "cutadapt", "bowtie2", "bwa-mem2", "hisat2", "NanoPlot", "minimap2"])

    tools = []
    missing = []
    for tool in sorted(requested):
        path = resolve_special(tool, app_root, config)
        status = "ready" if path else "missing"
        if not path:
            missing.append(tool)
        version = ""
        if path and tool not in {"fadu.jl", "longQC.py"}:
            version = tool_version(path)
        tools.append({"tool": tool, "status": status, "path": path or "", "version": version})

    for package in CORE_PYTHON_PACKAGES:
        available = importlib.util.find_spec(package) is not None
        label = f"python:{package}"
        if not available:
            missing.append(label)
        tools.append(
            {
                "tool": label,
                "status": "ready" if available else "missing",
                "path": "Python environment" if available else "",
                "version": "",
            }
        )

    is_linux = platform.system() == "Linux"
    is_wsl = is_linux and ("microsoft" in platform.release().lower() or os.environ.get("WSL_DISTRO_NAME"))
    disk = shutil.disk_usage(Path.cwd())
    payload = {
        "ready": is_linux and not missing and config_valid,
        "os": platform.platform(),
        "linux": is_linux,
        "wsl": bool(is_wsl),
        "architecture": platform.machine(),
        "cpu_threads": os.cpu_count(),
        "free_disk_gib": round(disk.free / (1024**3), 1),
        "conda_environment": os.environ.get("CONDA_DEFAULT_ENV", ""),
        "missing": missing,
        "configuration_valid": config_valid,
        "configuration_warnings": config_warnings,
        "configuration_error": config_error,
        "tools": tools,
        "guidance": (
            (
                f"Ready for {args.analysis_type}-read mode."
                if args.analysis_type
                else "Ready for the selected project."
            )
            if is_linux and not missing and config_valid
            else (
                "Correct the project configuration shown above, then check again."
                if not config_valid
                else (
                    "The existing RNA-seq tools are ready. This software update needs "
                    "OpenPyXL for Excel result workbooks. On Windows, accept the offered "
                    "quick repair or use Install or repair core once. WSL does not need "
                    "to be reinstalled."
                    if is_linux and missing == ["python:openpyxl"]
                    else "Run App/environment/setup_linux.sh inside Linux or use Install or Repair on Windows."
                )
            )
        ),
    }

    if args.json:
        report = json.dumps(payload, indent=2, ensure_ascii=False)
    else:
        report_lines = [
            "Bacterial RNA Analysis environment check",
            f"Linux: {'yes' if is_linux else 'no'}   WSL: {'yes' if is_wsl else 'no'}",
        ]
        for item in tools:
            report_lines.append(f"[{item['status'].upper():7}] {item['tool']:<18} {item['path']}")
        if config_warnings:
            report_lines.extend(["", "Configuration warnings:"])
            for warning in config_warnings:
                report_lines.append(f"  WARNING: {warning}")
        if config_error:
            report_lines.extend(["", "Configuration error:", config_error])
        report_lines.append(payload["guidance"])
        report = "\n".join(report_lines)

    if args.report_file:
        try:
            Path(args.report_file).write_text(report + "\n", encoding="utf-8")
        except OSError as exc:
            print(f"WARNING: could not write the environment report file: {exc}", file=sys.stderr)
    print(report)
    return 0 if payload["ready"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
