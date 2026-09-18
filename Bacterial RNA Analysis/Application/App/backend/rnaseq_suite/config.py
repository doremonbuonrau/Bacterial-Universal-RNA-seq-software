from __future__ import annotations

import hashlib
import json
import re
import shlex
from collections import defaultdict
from pathlib import Path
from typing import Any

from .paths import is_probably_bam, is_probably_fastq, runtime_path, safe_name


class ConfigError(ValueError):
    pass


ANALYSIS_TYPES = {"short", "long", "both"}
STRANDS = {"auto", "unstranded", "forward", "reverse"}
LONG_PLATFORMS = {
    "ont_cdna",
    "ont_direct_rna",
    "pacbio_hifi",
    "pacbio_clr",
}
LONG_PLATFORM_ALIASES = {
    "ont_cdna": "ont_cdna",
    "oxford_nanopore_cdna": "ont_cdna",
    "ont_direct_rna": "ont_direct_rna",
    "oxford_nanopore_direct_rna": "ont_direct_rna",
    "pacbio_hifi": "pacbio_hifi",
    "pacbio_clr": "pacbio_clr",
}

BOWTIE2_PRESETS = {"default", "very-fast", "fast", "sensitive", "very-sensitive"}
BOWTIE2_MODES = {"end-to-end", "local"}
TOOL_ARGUMENT_KEYS = {
    "fastqc", "fastp", "cutadapt", "multiqc",
    "bowtie2_build", "bowtie2", "bwa_mem2_index", "bwa_mem2",
    "hisat2_build", "hisat2", "samtools_faidx", "samtools_sort",
    "samtools_merge", "samtools_index", "samtools_fastq", "samtools_quickcheck",
    "samtools_flagstat", "samtools_stats", "samtools_idxstats",
    "dorado", "chopper", "pigz", "nanoplot", "longqc", "minimap2",
    "winnowmap", "meryl_count", "meryl_print", "featurecounts",
    "htseq_count", "fadu", "bamcoverage",
}


def normalize_long_platform(value: Any) -> str:
    normalized = re.sub(r"[^a-z0-9]+", "_", str(value or "").strip().lower()).strip("_")
    return LONG_PLATFORM_ALIASES.get(normalized, normalized)

METHOD_IDS = {
    "short_qc": {
        "fastqc_fastp_multiqc",
        "fastqc_cutadapt_multiqc",
        "qc_only",
    },
    "short_alignment": {
        "bowtie2_accuracy",
        "dual_bowtie2_bwa",
        "dual_bowtie2_hisat2",
        "bwa_mem2",
        "hisat2_no_splice",
    },
    "long_basecalling": {"already_basecalled", "dorado_sup", "dorado_hac"},
    "long_qc": {"nanoplot_longqc", "nanoplot", "long_qc_only"},
    "long_alignment": {"minimap2", "dual_minimap2_winnowmap", "winnowmap2"},
    "quantification": {
        "featurecounts_fadu_audit",
        "featurecounts",
        "fadu",
        "htseq",
        "skip_counts",
    },
    "coverage": {"cpm_bigwig_stranded", "raw_and_cpm_stranded", "raw_unstranded"},
}


def load_config(path: str | Path) -> dict[str, Any]:
    config_path = runtime_path(path)
    try:
        with config_path.open("r", encoding="utf-8-sig") as handle:
            data = json.load(handle)
    except FileNotFoundError as exc:
        raise ConfigError(f"Configuration file not found: {config_path}") from exc
    except json.JSONDecodeError as exc:
        raise ConfigError(f"Configuration JSON is invalid: {exc}") from exc
    if not isinstance(data, dict):
        raise ConfigError("Configuration root must be a JSON object.")
    return data


def canonical_config_hash(data: dict[str, Any]) -> str:
    canonical = json.dumps(data, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def validate_config(data: dict[str, Any], *, check_paths: bool = True) -> list[str]:
    errors: list[str] = []
    warnings: list[str] = []

    project = data.get("project")
    reference = data.get("reference")
    methods = data.get("methods")
    samples = data.get("samples")
    library = data.get("library", {})
    options = data.get("options", {})

    if not isinstance(project, dict):
        errors.append("Missing project settings.")
        project = {}
    if not isinstance(reference, dict):
        errors.append("Missing reference settings.")
        reference = {}
    if not isinstance(methods, dict):
        errors.append("Missing method selections.")
        methods = {}
    if not isinstance(samples, list) or not samples:
        errors.append("At least one included sample row is required.")
        samples = []
    if not isinstance(options, dict):
        errors.append("Options must be a JSON object.")
        options = {}

    bowtie2_preset = str(options.get("bowtie2_preset", "sensitive")).strip().lower()
    bowtie2_mode = str(options.get("bowtie2_mode", "end-to-end")).strip().lower()
    if bowtie2_preset not in BOWTIE2_PRESETS:
        errors.append("Bowtie2 preset must be default, very-fast, fast, sensitive, or very-sensitive.")
    if bowtie2_mode not in BOWTIE2_MODES:
        errors.append("Bowtie2 mode must be end-to-end or local.")

    tool_arguments = options.get("tool_arguments", {})
    if not isinstance(tool_arguments, dict):
        errors.append("Advanced tool arguments must be a JSON object keyed by tool name.")
    else:
        unknown_keys = sorted(set(tool_arguments) - TOOL_ARGUMENT_KEYS)
        if unknown_keys:
            errors.append("Unknown advanced tool argument key(s): " + ", ".join(unknown_keys))
        custom_count = 0
        for key, raw_value in tool_arguments.items():
            if not isinstance(raw_value, str):
                errors.append(f"Advanced arguments for {key} must be one command-line string.")
                continue
            if "\x00" in raw_value:
                errors.append(f"Advanced arguments for {key} contain a NUL character.")
                continue
            try:
                parsed = shlex.split(raw_value, posix=True)
            except ValueError as exc:
                errors.append(f"Advanced arguments for {key} are not correctly quoted: {exc}")
                continue
            if parsed:
                custom_count += 1
        if custom_count:
            warnings.append(
                f"Expert command-line overrides are enabled for {custom_count} tool(s). "
                "Review the exact commands and outputs because incompatible options can intentionally change or stop the workflow."
            )

    project_name = str(project.get("name", "")).strip()
    if not project_name:
        errors.append("Project name is required.")
    analysis_type = str(project.get("analysis_type", "")).strip().lower()
    if analysis_type not in ANALYSIS_TYPES:
        errors.append("Analysis type must be short, long, or both.")

    output_dir_raw = str(project.get("output_dir", "")).strip()
    if not output_dir_raw:
        errors.append("Output folder is required.")
    elif check_paths:
        output_dir = runtime_path(output_dir_raw)
        existing_parent = output_dir
        while not existing_parent.exists() and existing_parent != existing_parent.parent:
            existing_parent = existing_parent.parent
        if not existing_parent.exists():
            errors.append(f"No existing parent folder could be resolved for output: {output_dir}")
        elif not existing_parent.is_dir():
            errors.append(f"Output parent is not a folder: {existing_parent}")

    try:
        threads = int(project.get("threads", 1))
        if threads < 1:
            raise ValueError
    except (TypeError, ValueError):
        errors.append("Threads must be an integer of at least 1.")

    try:
        min_mapq = int(project.get("min_mapq", 10))
        if not 0 <= min_mapq <= 255:
            raise ValueError
    except (TypeError, ValueError):
        errors.append("Minimum mapping quality must be between 0 and 255.")

    for key, label in (("fasta", "Reference FASTA"), ("annotation", "Annotation")):
        raw = str(reference.get(key, "")).strip()
        if not raw:
            errors.append(f"{label} is required.")
        elif check_paths:
            path = runtime_path(raw)
            if not path.is_file():
                errors.append(f"{label} file not found: {path}")

    short_strand = str(library.get("short_strand", library.get("strand", "auto"))).strip().lower()
    long_strand = str(library.get("long_strand", library.get("strand", "auto"))).strip().lower()
    if analysis_type in {"short", "both"} and short_strand not in STRANDS:
        errors.append("Short-read library strand must be auto, unstranded, forward, or reverse.")
    if analysis_type in {"long", "both"} and long_strand not in STRANDS:
        errors.append("Long-read library strand must be auto, unstranded, forward, or reverse.")

    for method_group, allowed in METHOD_IDS.items():
        selected = str(methods.get(method_group, "")).strip()
        relevant = True
        if method_group.startswith("short_") and analysis_type == "long":
            relevant = False
        if method_group.startswith("long_") and analysis_type == "short":
            relevant = False
        if relevant and selected not in allowed:
            errors.append(f"Invalid or missing {method_group} method: {selected or '(blank)'}")

    adapter_r1 = str(methods.get("adapter_r1", "")).strip().upper()
    adapter_r2 = str(methods.get("adapter_r2", "")).strip().upper()
    if methods.get("short_qc") == "fastqc_cutadapt_multiqc":
        if not adapter_r1:
            errors.append("Cutadapt requires the R1 adapter sequence.")
        for name, sequence in (("R1", adapter_r1), ("R2", adapter_r2)):
            if sequence and not re.fullmatch(r"[ACGTRYSWKMBDHVN]+", sequence):
                errors.append(f"Cutadapt {name} adapter contains invalid nucleotide codes.")

    include_short = False
    include_long = False
    include_pod5 = False
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    conditions: dict[str, set[str]] = defaultdict(set)
    condition_replicates: dict[str, dict[str, set[str]]] = defaultdict(lambda: defaultdict(set))

    for row_index, raw_sample in enumerate(samples, start=1):
        if not isinstance(raw_sample, dict):
            errors.append(f"Sample row {row_index} is not an object.")
            continue
        if raw_sample.get("include", True) is False:
            continue

        sample_id = str(raw_sample.get("sample_id", "")).strip()
        if not sample_id:
            errors.append(f"Sample row {row_index} has no sample ID.")
            continue
        if safe_name(sample_id) != sample_id:
            errors.append(
                f"Sample ID '{sample_id}' must contain only letters, numbers, dot, underscore, or hyphen."
            )
        grouped[sample_id].append(raw_sample)

        raw_condition = str(raw_sample.get("condition", "")).strip()
        condition = raw_condition or "unspecified"
        conditions[sample_id].add(condition)
        replicate = str(raw_sample.get("replicate", "")).strip()
        if not raw_condition:
            warnings.append(f"Sample {sample_id} has no condition; processing can continue, but downstream differential expression requires complete condition metadata.")
        if not replicate:
            warnings.append(f"Sample {sample_id} has no replicate identifier; add one before differential-expression handoff.")
        else:
            condition_replicates[condition][replicate].add(sample_id)

        short_r1_raw = str(raw_sample.get("short_r1", "")).strip()
        short_r2_raw = str(raw_sample.get("short_r2", "")).strip()
        long_raw = str(raw_sample.get("long_reads", "")).strip()
        pod5_raw = str(raw_sample.get("pod5_dir", "")).strip()

        if short_r1_raw:
            include_short = True
            r1 = runtime_path(short_r1_raw)
            if check_paths and not r1.is_file():
                errors.append(f"Sample {sample_id} R1 file not found: {r1}")
            if not is_probably_fastq(r1):
                warnings.append(f"Sample {sample_id} R1 does not use a common FASTQ extension: {r1.name}")
        if short_r2_raw:
            r2 = runtime_path(short_r2_raw)
            if not short_r1_raw:
                errors.append(f"Sample {sample_id} has R2 but no R1.")
            if check_paths and not r2.is_file():
                errors.append(f"Sample {sample_id} R2 file not found: {r2}")
            if not is_probably_fastq(r2):
                warnings.append(f"Sample {sample_id} R2 does not use a common FASTQ extension: {r2.name}")
            if short_r1_raw and runtime_path(short_r1_raw) == r2:
                errors.append(f"Sample {sample_id} uses the same file for R1 and R2.")

        if long_raw and pod5_raw:
            errors.append(f"Sample {sample_id} must use either basecalled long reads or POD5, not both in one row.")
        if long_raw:
            include_long = True
            long_path = runtime_path(long_raw)
            if check_paths and not long_path.is_file():
                errors.append(f"Sample {sample_id} long-read file not found: {long_path}")
            if not (is_probably_fastq(long_path) or is_probably_bam(long_path)):
                warnings.append(
                    f"Sample {sample_id} long-read input is expected to be FASTQ or unaligned BAM: {long_path.name}"
                )
        if pod5_raw:
            include_long = True
            include_pod5 = True
            pod5_path = runtime_path(pod5_raw)
            if check_paths and not pod5_path.is_dir():
                errors.append(f"Sample {sample_id} POD5 folder not found: {pod5_path}")
            elif check_paths and not any(pod5_path.rglob("*.pod5")):
                errors.append(f"Sample {sample_id} POD5 folder contains no .pod5 files: {pod5_path}")
            if methods.get("long_basecalling") == "already_basecalled":
                errors.append(f"Sample {sample_id} supplies POD5 but Dorado basecalling is not selected.")

        if long_raw or pod5_raw:
            platform = normalize_long_platform(raw_sample.get("long_platform", ""))
            if platform not in LONG_PLATFORMS:
                errors.append(
                    f"Sample {sample_id} requires a long-read platform: Oxford Nanopore cDNA, Oxford Nanopore direct RNA, PacBio HiFi, or PacBio CLR."
                )
            if pod5_raw and not platform.startswith("ont_"):
                errors.append(f"Sample {sample_id} POD5 input requires an Oxford Nanopore long platform.")

        if not short_r1_raw and not long_raw and not pod5_raw:
            errors.append(f"Sample row {row_index} ({sample_id}) has no sequencing input.")

    if analysis_type == "short" and not include_short:
        errors.append("Short-read analysis requires at least one R1 FASTQ.")
    if analysis_type == "long" and not include_long:
        errors.append("Long-read analysis requires basecalled reads or a POD5 folder.")
    if analysis_type == "both":
        if not include_short:
            errors.append("Combined analysis requires at least one short-read input.")
        if not include_long:
            errors.append("Combined analysis requires at least one long-read input.")

    if include_long and not include_pod5 and methods.get("long_basecalling") in {"dorado_sup", "dorado_hac"}:
        warnings.append(
            "Dorado was selected but no POD5 input is present. Supplied FASTQ/BAM reads will pass through without basecalling."
        )
    if analysis_type == "long" and methods.get("quantification") == "fadu":
        errors.append(
            "FADU-only counting is not suitable for the long-read-only workflow; choose featureCounts or skip counts."
        )
    if analysis_type == "long" and methods.get("quantification") == "featurecounts_fadu_audit":
        warnings.append(
            "FADU is fragment-oriented and will be skipped for long reads; featureCounts remains the exported long-read matrix."
        )
    if methods.get("long_qc") == "long_qc_only" and bool(data.get("options", {}).get("filter_long_reads", False)):
        warnings.append(
            "Long-read filtering is enabled even though the QC method is labeled without filtering. The explicit filter checkbox takes precedence."
        )

    for sample_id, rows in grouped.items():
        if len(conditions[sample_id]) > 1:
            errors.append(
                f"Technical runs sharing sample ID {sample_id} must have the same condition."
            )
        short_layouts = {
            bool(str(row.get("short_r2", "")).strip())
            for row in rows
            if str(row.get("short_r1", "")).strip()
        }
        if len(short_layouts) > 1:
            errors.append(
                f"Technical runs sharing sample ID {sample_id} cannot mix single-end and paired-end short reads."
            )

    biological_samples = len(grouped)
    if biological_samples == 1:
        warnings.append(
            "Only one biological sample is present. BAM and QC export are valid, but later differential expression will not be possible."
        )

    condition_counts: dict[str, int] = defaultdict(int)
    for sample_id, values in conditions.items():
        if values:
            condition_counts[next(iter(values))] += 1
    for condition, replicate_map in sorted(condition_replicates.items()):
        if condition == "unspecified":
            continue
        for replicate, sample_ids in sorted(replicate_map.items()):
            if len(sample_ids) > 1:
                warnings.append(
                    f"Condition '{condition}' uses replicate label '{replicate}' for multiple biological sample IDs: {', '.join(sorted(sample_ids))}. Consider unique replicate labels within each condition."
                )

    for condition, count in sorted(condition_counts.items()):
        if condition != "unspecified" and count < 2:
            warnings.append(
                f"Condition '{condition}' has {count} biological replicate; later differential expression should preferably use at least three."
            )

    if errors:
        raise ConfigError("\n".join(f"• {message}" for message in errors))
    return warnings


def included_samples(data: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        sample
        for sample in data.get("samples", [])
        if isinstance(sample, dict) and sample.get("include", True) is not False
    ]


def grouped_samples(data: dict[str, Any]) -> dict[str, list[dict[str, Any]]]:
    result: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for sample in included_samples(data):
        result[str(sample["sample_id"]).strip()].append(sample)
    return dict(result)
