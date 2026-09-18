from __future__ import annotations

import csv
import gzip
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

from .annotation import normalize_annotation
from .compact_export import (
    compact_successful_export,
    create_processing_workbook,
    remap_path,
)
from .config import (
    ConfigError,
    canonical_config_hash,
    grouped_samples,
    included_samples,
    validate_config,
)
from .events import EventWriter
from .parsers import (
    parse_fadu_counts,
    parse_featurecounts_assigned,
    parse_featurecounts_counts,
    parse_htseq_counts,
    sha256_file,
    write_count_matrix,
)
from .paths import is_probably_bam, runtime_path, safe_name
from .report import (
    generate_html_report,
    generate_qc_report,
    refresh_checksum_entries,
    write_checksums,
    write_run_manifest,
)
from .runner import CommandFailed, CommandRunner, PipelineStopped, quote


def _execution_hash(config: dict[str, Any]) -> str:
    """Bind checkpoints to configuration plus input file identity metadata."""

    records: list[dict[str, object]] = []
    raw_paths: list[tuple[str, str]] = [
        ("reference_fasta", str(config.get("reference", {}).get("fasta", ""))),
        ("reference_annotation", str(config.get("reference", {}).get("annotation", ""))),
    ]
    for index, sample in enumerate(included_samples(config), start=1):
        for key in ("short_r1", "short_r2", "long_reads", "pod5_dir"):
            raw = str(sample.get(key, "")).strip()
            if raw:
                raw_paths.append((f"sample_{index}_{key}", raw))

    for role, raw in raw_paths:
        if not raw:
            continue
        path = runtime_path(raw)
        if path.is_file():
            stat = path.stat()
            records.append(
                {
                    "role": role,
                    "path": os.fspath(path.resolve()),
                    "size": stat.st_size,
                    "mtime_ns": stat.st_mtime_ns,
                }
            )
        elif path.is_dir():
            for child in sorted(item for item in path.rglob("*") if item.is_file()):
                stat = child.stat()
                records.append(
                    {
                        "role": role,
                        "path": os.fspath(child.resolve()),
                        "size": stat.st_size,
                        "mtime_ns": stat.st_mtime_ns,
                    }
                )
        else:
            records.append({"role": role, "path": os.fspath(path), "missing": True})

    payload = {
        "configuration_hash": canonical_config_hash(config),
        "input_identity": records,
    }
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def _provenance_text(value: object) -> str:
    """Keep package provenance one-line, tab-safe, and suitable for Excel."""

    if value is None:
        return ""
    if isinstance(value, (list, tuple, set)):
        value = "; ".join(str(item) for item in value)
    elif isinstance(value, dict):
        value = json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    return " ".join(str(value).replace("\t", " ").splitlines()).strip()


def _conda_package_record(metadata_path: Path) -> dict[str, str]:
    """Extract auditable package identity without copying huge file manifests.

    Conda's per-package JSON can contain tens of thousands of ``files`` and
    ``paths_data.paths`` entries. Those are installation inventories, not
    executable source code or generated analysis code. The metadata file hash
    fingerprints the complete record, while the returned fields preserve the
    package identity, build, origin, license, and dependency information needed
    to reproduce and audit the environment.
    """

    digest = sha256_file(metadata_path)
    try:
        payload = json.loads(metadata_path.read_text(encoding="utf-8", errors="replace"))
    except (OSError, json.JSONDecodeError) as exc:
        return {
            "package": metadata_path.stem,
            "version": "",
            "build": "",
            "build_number": "",
            "subdir": "",
            "channel": "",
            "license": "",
            "license_family": "",
            "package_url": "",
            "package_sha256": "",
            "package_md5": "",
            "requested_spec": "",
            "dependencies": "",
            "upstream_urls": "",
            "metadata_file": metadata_path.name,
            "metadata_sha256": digest,
            "metadata_status": f"unreadable: {exc}",
        }

    repodata = payload.get("repodata_record")
    if not isinstance(repodata, dict):
        repodata = {}
    channel = payload.get("channel", repodata.get("channel", ""))
    if isinstance(channel, dict):
        channel = channel.get("canonical_name") or channel.get("name") or channel.get("url") or channel
    upstream_candidates = [
        payload.get("source_url"),
        payload.get("dev_url"),
        payload.get("doc_url"),
        payload.get("home"),
        payload.get("homepage"),
    ]
    upstream_urls = "; ".join(
        dict.fromkeys(_provenance_text(item) for item in upstream_candidates if item)
    )
    return {
        "package": _provenance_text(payload.get("name") or repodata.get("name") or metadata_path.stem),
        "version": _provenance_text(payload.get("version") or repodata.get("version")),
        "build": _provenance_text(payload.get("build") or repodata.get("build")),
        "build_number": _provenance_text(payload.get("build_number", repodata.get("build_number", ""))),
        "subdir": _provenance_text(payload.get("subdir") or repodata.get("subdir")),
        "channel": _provenance_text(channel),
        "license": _provenance_text(payload.get("license") or repodata.get("license")),
        "license_family": _provenance_text(
            payload.get("license_family") or repodata.get("license_family")
        ),
        "package_url": _provenance_text(payload.get("url") or repodata.get("url")),
        "package_sha256": _provenance_text(payload.get("sha256") or repodata.get("sha256")),
        "package_md5": _provenance_text(payload.get("md5") or repodata.get("md5")),
        "requested_spec": _provenance_text(payload.get("requested_spec")),
        "dependencies": _provenance_text(payload.get("depends") or repodata.get("depends") or []),
        "upstream_urls": upstream_urls,
        "metadata_file": metadata_path.name,
        "metadata_sha256": digest,
        "metadata_status": "ok",
    }


class Pipeline:
    """Accuracy-first prokaryotic RNA-seq preprocessing and export workflow."""

    def __init__(self, config: dict[str, Any], *, dry_run: bool = False) -> None:
        self.config = config
        self.dry_run = dry_run
        self.warnings = validate_config(config, check_paths=not dry_run)
        self.configuration_hash = canonical_config_hash(config)
        self.config_hash = _execution_hash(config)

        project = config["project"]
        self.run_root = runtime_path(project["output_dir"]).resolve()
        self.project_dir = self.run_root / "00_project"
        self.work_dir = self.run_root / "work"
        self.ready_dir = self.run_root / "analysis_ready"
        self.state_dir = self.run_root / ".rnaseq_suite"
        self.checkpoint_dir = self.state_dir / "checkpoints"

        compact_manifest = self.ready_dir / "Intermediate files" / "Run manifest.json"
        if compact_manifest.is_file():
            try:
                compact_status = str(
                    json.loads(compact_manifest.read_text(encoding="utf-8", errors="replace")).get("status", "")
                ).lower()
            except (OSError, json.JSONDecodeError):
                compact_status = ""
            if compact_status in {"complete", "dry_run"}:
                raise ConfigError(
                    "The selected output folder already contains a completed compact run. "
                    "Choose a new output folder so final results are never mixed with a rerun."
                )

        for path in (
            self.project_dir,
            self.work_dir,
            self.ready_dir,
            self.state_dir,
            self.checkpoint_dir,
        ):
            path.mkdir(parents=True, exist_ok=True)

        previous_hash_path = self.project_dir / "config.sha256"
        compact_hash_path = self.ready_dir / "Intermediate files" / "Provenance" / "config.sha256"
        if not previous_hash_path.is_file() and compact_hash_path.is_file():
            previous_hash_path = compact_hash_path
        if previous_hash_path.is_file():
            previous_hash = previous_hash_path.read_text(encoding="utf-8", errors="replace").split()[0]
            manifest_path = self.ready_dir / "Run manifest.json"
            if not manifest_path.is_file():
                manifest_path = self.ready_dir / "Intermediate files" / "Run manifest.json"
            if not manifest_path.is_file():
                manifest_path = self.ready_dir / "run_manifest.json"
            completed_previous_run = False
            if manifest_path.is_file():
                try:
                    previous_manifest = json.loads(manifest_path.read_text(encoding="utf-8", errors="replace"))
                    completed_previous_run = str(previous_manifest.get("status", "")).lower() in {"complete", "dry_run"}
                except (OSError, json.JSONDecodeError):
                    completed_previous_run = False
            if previous_hash and completed_previous_run:
                raise ConfigError(
                    "The selected output folder already contains a completed compact run. "
                    "Choose a new output folder so final results are never mixed with a rerun."
                )
            if previous_hash and previous_hash != self.config_hash and not completed_previous_run:
                # A failed or interrupted run may have written only initialization metadata.
                # Do not permanently lock that folder; clear only resumability state and
                # replace the initialization records with the current configuration.
                shutil.rmtree(self.checkpoint_dir, ignore_errors=True)
                self.checkpoint_dir.mkdir(parents=True, exist_ok=True)
                self.warnings.append(
                    "An incomplete earlier run used a different configuration. Its initialization metadata was refreshed; completed biological outputs were not present."
                )

        stop_file = self.state_dir / "STOP_REQUESTED"
        if stop_file.exists():
            stop_file.unlink()

        self.events = EventWriter(self.state_dir)
        self.runner = CommandRunner(self.run_root, self.events, dry_run=dry_run)
        self.threads = max(1, int(project.get("threads", 4)))
        self.min_mapq = max(0, int(project.get("min_mapq", 10)))
        self.resume = bool(project.get("resume", True))
        self.analysis_type = str(project["analysis_type"]).lower()
        self.stage_plan = ["initialize", "reference"]
        if self.analysis_type in {"short", "both"}:
            self.stage_plan.extend(["short_qc", "short_alignment"])
        if self.analysis_type in {"long", "both"}:
            self.stage_plan.extend(["long_qc", "long_alignment"])
        self.stage_plan.extend(["bam_qc", "counts", "coverage", "multiqc", "export"])
        self.stage_numbers = {stage: index + 1 for index, stage in enumerate(self.stage_plan)}
        self.total_steps = len(self.stage_plan)
        self.methods = config["methods"]
        self.options = config.get("options", {})
        self.library = config.get("library", {})
        self.reference_config = config["reference"]

        self.reference_fasta = self.ready_dir / "reference" / "reference.fasta"
        self.normalized_gff = self.ready_dir / "reference" / "annotation.normalized.gff3"
        self.saf = self.ready_dir / "reference" / "features.saf"
        self.annotation_summary: dict[str, object] | None = None
        self.alignment_summary: list[dict[str, object]] = []
        self.strand_summary: list[dict[str, object]] = []
        self.outputs: list[Path] = []
        self.primary_bams: dict[str, dict[str, Path]] = defaultdict(dict)
        self.alternative_bams: dict[str, dict[str, Path]] = defaultdict(dict)
        self.sample_layout: dict[str, str] = {}
        self.effective_strand: dict[tuple[str, str], str] = {}
        self.fadu_audit_status: list[dict[str, str]] = []

    def _tool_args(self, key: str) -> list[str]:
        """Parse one expert option string into inert subprocess arguments."""
        options = getattr(self, "options", {})
        configured = options.get("tool_arguments", {}) if isinstance(options, dict) else {}
        if not isinstance(configured, dict):
            return []
        raw = configured.get(key, "")
        if raw is None:
            return []
        if not isinstance(raw, str):
            raise ConfigError(f"Advanced arguments for {key} must be a string.")
        try:
            return shlex.split(raw, posix=True)
        except ValueError as exc:
            raise ConfigError(f"Advanced arguments for {key} are not correctly quoted: {exc}") from exc

    def _quoted_tool_args(self, key: str) -> str:
        return " ".join(quote(item) for item in self._tool_args(key))

    def _restore_internal_export_names(self) -> None:
        """Restore machine-facing names when resuming a completed export."""
        mapping_path = self.ready_dir / "Intermediate files" / "Export filename mapping.json"
        if not mapping_path.is_file():
            mapping_path = self.ready_dir / "Export filename mapping.json"
        if not mapping_path.is_file():
            return
        try:
            payload = json.loads(mapping_path.read_text(encoding="utf-8-sig"))
            mappings = payload.get("files", []) if isinstance(payload, dict) else []
            for item in mappings:
                if not isinstance(item, dict):
                    continue
                internal = self.ready_dir / str(item.get("internal", ""))
                display = self.ready_dir / str(item.get("display", ""))
                if display.is_file() and not internal.exists():
                    internal.parent.mkdir(parents=True, exist_ok=True)
                    display.rename(internal)
            mapping_path.unlink(missing_ok=True)
        except (OSError, json.JSONDecodeError, ValueError):
            # A damaged optional mapping must not hide the original diagnostic.
            return

    def _apply_export_filename_policy(self) -> None:
        """Replace underscores in every user-facing exported filename with spaces."""
        renamed: dict[Path, Path] = {}
        records: list[dict[str, str]] = []
        for source in sorted(
            (path for path in self.ready_dir.rglob("*") if path.is_file()),
            key=lambda path: path.as_posix().casefold(),
        ):
            display_name = re.sub(r"\s+", " ", source.name.replace("_", " ")).strip()
            if display_name == source.name:
                continue
            destination = source.with_name(display_name)
            if destination.exists() and destination != source:
                raise ConfigError(
                    f"Export filename collision after replacing underscores with spaces: {source} and {destination}"
                )
            source.rename(destination)
            renamed[source] = destination
            records.append(
                {
                    "internal": source.relative_to(self.ready_dir).as_posix(),
                    "display": destination.relative_to(self.ready_dir).as_posix(),
                }
            )

        def remap(path: Path) -> Path:
            return renamed.get(path, path)

        self.outputs = [remap(path) for path in self.outputs]
        self.reference_fasta = remap(self.reference_fasta)
        self.normalized_gff = remap(self.normalized_gff)
        self.saf = remap(self.saf)
        for collection in (self.primary_bams, self.alternative_bams):
            for sample_bams in collection.values():
                for sample_id, path in list(sample_bams.items()):
                    sample_bams[sample_id] = remap(path)

        mapping_path = self.ready_dir / "Intermediate files" / "Export filename mapping.json"
        mapping_path.parent.mkdir(parents=True, exist_ok=True)
        mapping_path.write_text(
            json.dumps({"policy": "underscores replaced with spaces", "files": records}, indent=2) + "\n",
            encoding="utf-8",
        )
        self.outputs.append(mapping_path)

    def _record_fadu_audit_status(
        self,
        modality: str,
        sample_id: str,
        status: str,
        message: str,
    ) -> None:
        """Record optional FADU audit availability without invalidating core counts."""

        record = {
            "modality": modality,
            "sample_id": sample_id,
            "status": status,
            "message": message,
        }
        self.fadu_audit_status.append(record)
        if status != "complete" and message not in self.warnings:
            self.warnings.append(message)
        prefix = "FADU AUDIT" if status == "complete" else "WARNING - FADU AUDIT"
        self.runner._append_log(f"{prefix}: {message}")

    def _write_fadu_audit_status(self) -> None:
        if not self.fadu_audit_status:
            return
        path = self.ready_dir / "counts" / "fadu_audit_status.tsv"
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("w", encoding="utf-8", newline="\n") as handle:
            writer = csv.DictWriter(
                handle,
                fieldnames=["modality", "sample_id", "status", "message"],
                delimiter="\t",
            )
            writer.writeheader()
            writer.writerows(self.fadu_audit_status)
        self.outputs.append(path)

    def _emit(self, stage: str, message: str, percent: int) -> None:
        self.events.emit(
            "stage",
            message,
            stage=stage,
            status="running",
            percent=percent,
            step_current=self.stage_numbers[stage],
            step_total=self.total_steps,
        )

    def _checkpoint_path(self, name: str) -> Path:
        return self.checkpoint_dir / f"{safe_name(name)}.json"

    def _checkpoint_valid(self, name: str, outputs: Iterable[Path]) -> bool:
        if not self.resume or self.dry_run:
            return False
        checkpoint = self._checkpoint_path(name)
        if not checkpoint.is_file():
            return False
        try:
            payload = json.loads(checkpoint.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return False
        if payload.get("config_hash") != self.config_hash:
            return False
        expected = list(outputs)
        stored = payload.get("outputs")
        if not expected or not isinstance(stored, list):
            return False
        stored_by_path = {
            str(item.get("path")): item
            for item in stored
            if isinstance(item, dict) and item.get("path")
        }
        for path in expected:
            if not path.exists():
                return False
            item = stored_by_path.get(os.fspath(path))
            if item is None:
                return False
            stat = path.stat()
            if item.get("size") != stat.st_size or item.get("mtime_ns") != stat.st_mtime_ns:
                return False
        return True

    def _mark_checkpoint(self, name: str, outputs: Iterable[Path]) -> None:
        if self.dry_run:
            return
        output_records = []
        for path in outputs:
            if not path.exists():
                continue
            stat = path.stat()
            output_records.append(
                {
                    "path": os.fspath(path),
                    "size": stat.st_size,
                    "mtime_ns": stat.st_mtime_ns,
                }
            )
        payload = {
            "stage": name,
            "config_hash": self.config_hash,
            "finished_at": datetime.now(timezone.utc).isoformat(),
            "outputs": output_records,
        }
        target = self._checkpoint_path(name)
        temp = target.with_suffix(".json.tmp")
        temp.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        os.replace(temp, target)

    @staticmethod
    def _copy_or_decompress(source: Path, target: Path) -> None:
        target.parent.mkdir(parents=True, exist_ok=True)
        if source.name.lower().endswith(".gz"):
            with gzip.open(source, "rb") as incoming, target.open("wb") as outgoing:
                shutil.copyfileobj(incoming, outgoing, length=1024 * 1024)
        else:
            shutil.copy2(source, target)

    @staticmethod
    def _copy_file(source: Path, target: Path) -> None:
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)

    def _snapshot_configuration(self) -> None:
        target = self.project_dir / "project_config.json"
        target.write_text(
            json.dumps(self.config, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        (self.project_dir / "config.sha256").write_text(
            f"{self.config_hash}  project_config.json + input identity\n", encoding="utf-8"
        )
        (self.project_dir / "configuration_only.sha256").write_text(
            f"{self.configuration_hash}  project_config.json\n", encoding="utf-8"
        )
        if self.warnings:
            (self.project_dir / "configuration_warnings.txt").write_text(
                "\n".join(self.warnings) + "\n", encoding="utf-8"
            )

    def _write_input_manifest(self) -> None:
        manifest = self.ready_dir / "metadata" / "input_files.tsv"
        manifest.parent.mkdir(parents=True, exist_ok=True)
        rows: list[tuple[str, str, Path]] = [
            ("reference", "fasta", runtime_path(self.reference_config["fasta"])),
            ("reference", "annotation", runtime_path(self.reference_config["annotation"])),
        ]
        for index, sample in enumerate(included_samples(self.config), start=1):
            sample_id = str(sample["sample_id"])
            for key in ("short_r1", "short_r2", "long_reads", "pod5_dir"):
                raw = str(sample.get(key, "")).strip()
                if raw:
                    rows.append((sample_id, f"run{index:03d}_{key}", runtime_path(raw)))

        with manifest.open("w", encoding="utf-8", newline="\n") as handle:
            handle.write("sample_id\trole\tpath\ttype\tsize_bytes\tmodified_utc\n")
            for sample_id, role, path in rows:
                kind = "directory" if path.is_dir() else "file"
                size = path.stat().st_size if path.is_file() else ""
                modified = ""
                if path.exists():
                    modified = datetime.fromtimestamp(
                        path.stat().st_mtime, timezone.utc
                    ).isoformat()
                handle.write(
                    f"{sample_id}\t{role}\t{path}\t{kind}\t{size}\t{modified}\n"
                )
        self.outputs.append(manifest)

    def _write_sample_metadata(self) -> None:
        metadata_dir = self.ready_dir / "metadata"
        metadata_dir.mkdir(parents=True, exist_ok=True)
        sample_path = metadata_dir / "sample_metadata.tsv"
        run_path = metadata_dir / "sample_runs.tsv"

        grouped = grouped_samples(self.config)
        with sample_path.open("w", encoding="utf-8", newline="\n") as handle:
            handle.write(
                "sample_id\tcondition\treplicate\tbatch\ttechnical_runs\thas_short\thas_long\n"
            )
            for sample_id, rows in grouped.items():
                first = rows[0]
                handle.write(
                    "\t".join(
                        [
                            sample_id,
                            str(first.get("condition", "unspecified")),
                            str(first.get("replicate", "")),
                            str(first.get("batch", "")),
                            str(len(rows)),
                            "yes" if any(row.get("short_r1") for row in rows) else "no",
                            "yes"
                            if any(row.get("long_reads") or row.get("pod5_dir") for row in rows)
                            else "no",
                        ]
                    )
                    + "\n"
                )

        fields = [
            "run_id",
            "sample_id",
            "condition",
            "replicate",
            "batch",
            "short_r1",
            "short_r2",
            "long_reads",
            "pod5_dir",
            "long_platform",
        ]
        with run_path.open("w", encoding="utf-8", newline="\n") as handle:
            writer = csv.DictWriter(handle, fieldnames=fields, delimiter="\t", extrasaction="ignore")
            writer.writeheader()
            seen: dict[str, int] = defaultdict(int)
            for row in included_samples(self.config):
                sample_id = str(row["sample_id"])
                seen[sample_id] += 1
                payload = dict(row)
                payload["run_id"] = f"{sample_id}__run{seen[sample_id]:02d}"
                writer.writerow(payload)
        self.outputs.extend([sample_path, run_path])

    def _prepare_reference(self) -> None:
        reference_dir = self.ready_dir / "reference"
        expected = [
            self.reference_fasta,
            self.reference_fasta.with_suffix(".fasta.fai"),
            self.normalized_gff,
            self.saf,
            reference_dir / "gene_metadata.tsv",
            reference_dir / "gene_coordinates.tsv",
            reference_dir / "gene_lengths.tsv",
            reference_dir / "contig_sizes.tsv",
        ]
        if self._checkpoint_valid("reference", expected):
            summary_path = self.project_dir / "annotation_summary.json"
            if summary_path.is_file():
                self.annotation_summary = json.loads(summary_path.read_text(encoding="utf-8"))
            self.outputs.extend(expected)
            return

        fasta_source = runtime_path(self.reference_config["fasta"])
        annotation_source = runtime_path(self.reference_config["annotation"])
        self._copy_or_decompress(fasta_source, self.reference_fasta)
        original_suffix = ".gff3"
        lower = annotation_source.name.lower().removesuffix(".gz")
        if lower.endswith(".gtf"):
            original_suffix = ".gtf"
        original_annotation = reference_dir / f"annotation.original{original_suffix}"
        self._copy_or_decompress(annotation_source, original_annotation)

        self.annotation_summary = normalize_annotation(
            self.reference_fasta,
            original_annotation,
            reference_dir,
            feature_type=str(self.reference_config.get("feature_type", "auto")),
            id_attribute=str(self.reference_config.get("id_attribute", "auto")),
        )
        missing_contigs = int(self.annotation_summary.get("skipped_missing_contig", 0))
        out_of_bounds = int(self.annotation_summary.get("skipped_out_of_bounds", 0))
        id_collisions = int(self.annotation_summary.get("sanitized_id_collisions", 0))
        if missing_contigs:
            self.warnings.append(
                f"Annotation normalization skipped {missing_contigs} feature rows whose contig was absent from the FASTA."
            )
        if out_of_bounds:
            self.warnings.append(
                f"Annotation normalization skipped {out_of_bounds} feature rows extending beyond a FASTA contig."
            )
        if id_collisions:
            self.warnings.append(
                f"Annotation normalization disambiguated {id_collisions} gene ID collisions introduced by filename-safe ID cleaning; original IDs remain in gene_metadata.tsv."
            )
        summary_path = self.project_dir / "annotation_summary.json"
        summary_path.write_text(
            json.dumps(self.annotation_summary, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        self.runner.require_tools(["samtools"])
        self.runner.run(
            "reference_faidx",
            ["samtools", "faidx", *self._tool_args("samtools_faidx"), self.reference_fasta],
        )
        self.outputs.extend(expected + [original_annotation])
        self._mark_checkpoint("reference", expected)

    def _run_id_rows(self) -> list[tuple[str, dict[str, Any]]]:
        seen: dict[str, int] = defaultdict(int)
        result: list[tuple[str, dict[str, Any]]] = []
        for row in included_samples(self.config):
            sample_id = str(row["sample_id"])
            seen[sample_id] += 1
            result.append((f"{sample_id}__run{seen[sample_id]:02d}", row))
        return result

    def _fastqc(self, label: str, reads: Iterable[Path], output_dir: Path) -> None:
        read_list = list(reads)
        if not read_list:
            return
        output_dir.mkdir(parents=True, exist_ok=True)
        marker = output_dir / f".{safe_name(label)}.complete"
        if self._checkpoint_valid(f"fastqc_{label}", [marker]):
            return
        self.runner.require_tools(["fastqc"])
        self.runner.run(
            f"fastqc_{label}",
            [
                "fastqc", "--threads", str(min(self.threads, 12)), "--outdir", output_dir,
                *self._tool_args("fastqc"), *read_list,
            ],
        )
        if not self.dry_run:
            marker.write_text(self.config_hash + "\n", encoding="utf-8")
        self._mark_checkpoint(f"fastqc_{label}", [marker])

    def _prepare_short_reads(self) -> dict[str, tuple[Path, Path | None]]:
        selected = self.methods["short_qc"]
        clean_dir = self.ready_dir / "cleaned_fastq" / "short"
        raw_qc_dir = self.ready_dir / "qc" / "short_raw"
        clean_qc_dir = self.ready_dir / "qc" / "short_clean"
        clean_dir.mkdir(parents=True, exist_ok=True)
        prepared: dict[str, tuple[Path, Path | None]] = {}

        for run_id, row in self._run_id_rows():
            if not str(row.get("short_r1", "")).strip():
                continue
            r1 = runtime_path(row["short_r1"])
            r2 = runtime_path(row["short_r2"]) if str(row.get("short_r2", "")).strip() else None
            expected_r1 = clean_dir / f"{run_id}_R1.clean.fastq.gz"
            expected_r2 = clean_dir / f"{run_id}_R2.clean.fastq.gz" if r2 else None
            checkpoint_outputs = [expected_r1] + ([expected_r2] if expected_r2 else [])

            self._fastqc(f"raw_{run_id}", [r1] + ([r2] if r2 else []), raw_qc_dir)

            if selected == "qc_only":
                prepared[run_id] = (r1, r2)
                continue
            if self._checkpoint_valid(f"short_clean_{run_id}", checkpoint_outputs):
                prepared[run_id] = (expected_r1, expected_r2)
                continue

            if selected == "fastqc_fastp_multiqc":
                self.runner.require_tools(["fastp"])
                report_dir = self.ready_dir / "qc" / "fastp"
                report_dir.mkdir(parents=True, exist_ok=True)
                command: list[object] = [
                    "fastp",
                    "--thread",
                    str(min(self.threads, 16)),
                    "--in1",
                    r1,
                    "--out1",
                    expected_r1,
                    "--qualified_quality_phred",
                    str(int(self.options.get("short_quality", 20))),
                    "--unqualified_percent_limit",
                    str(int(self.options.get("short_unqualified_percent", 40))),
                    "--cut_front",
                    "--cut_tail",
                    "--cut_window_size",
                    "4",
                    "--cut_mean_quality",
                    str(int(self.options.get("short_quality", 20))),
                    "--length_required",
                    str(int(self.options.get("short_min_length", 30))),
                    "--json",
                    report_dir / f"{run_id}.fastp.json",
                    "--html",
                    report_dir / f"{run_id}.fastp.html",
                ]
                if r2 and expected_r2:
                    command.extend(["--in2", r2, "--out2", expected_r2, "--detect_adapter_for_pe"])
                command.extend(self._tool_args("fastp"))
                self.runner.run(f"fastp_{run_id}", command)
            elif selected == "fastqc_cutadapt_multiqc":
                self.runner.require_tools(["cutadapt"])
                command = [
                    "cutadapt",
                    "--cores",
                    str(self.threads),
                    "-q",
                    "20,20",
                    "--minimum-length",
                    str(int(self.options.get("short_min_length", 30))),
                    "-a",
                    str(self.methods["adapter_r1"]),
                    "-o",
                    expected_r1,
                ]
                if r2 and expected_r2:
                    adapter_r2 = str(self.methods.get("adapter_r2", "")).strip()
                    if adapter_r2:
                        command.extend(["-A", adapter_r2])
                    command.extend(["-p", expected_r2])
                    command.extend(self._tool_args("cutadapt"))
                    command.extend([r1, r2])
                else:
                    command.extend(self._tool_args("cutadapt"))
                    command.append(r1)
                self.runner.run(f"cutadapt_{run_id}", command)
            else:
                raise ConfigError(f"Unsupported short-read QC method: {selected}")

            self._mark_checkpoint(f"short_clean_{run_id}", checkpoint_outputs)
            prepared[run_id] = (expected_r1, expected_r2)
            self.outputs.extend(checkpoint_outputs)

        if selected != "qc_only":
            clean_reads = [path for pair in prepared.values() for path in pair if path is not None]
            self._fastqc("short_clean", clean_reads, clean_qc_dir)
        return prepared

    def _build_short_index(self, aligner: str) -> Path:
        index_dir = self.work_dir / "indexes" / aligner
        index_dir.mkdir(parents=True, exist_ok=True)
        prefix = index_dir / "reference"
        marker = index_dir / ".complete"
        if self._checkpoint_valid(f"index_{aligner}", [marker]):
            if aligner == "bowtie2" and len(list(index_dir.glob("reference*.bt2*"))) >= 6:
                return prefix
            if aligner == "hisat2" and len(list(index_dir.glob("reference*.ht2*"))) >= 8:
                return prefix
            if aligner == "bwa-mem2" and Path(str(self.reference_fasta) + ".0123").is_file():
                return self.reference_fasta

        if aligner == "bowtie2":
            self.runner.require_tools(["bowtie2-build"])
            self.runner.run(
                "bowtie2_build",
                ["bowtie2-build", "--threads", str(self.threads), *self._tool_args("bowtie2_build"), self.reference_fasta, prefix],
            )
        elif aligner == "bwa-mem2":
            self.runner.require_tools(["bwa-mem2"])
            prefix = self.reference_fasta
            self.runner.run(
                "bwa_mem2_index",
                ["bwa-mem2", "index", *self._tool_args("bwa_mem2_index"), self.reference_fasta],
            )
        elif aligner == "hisat2":
            self.runner.require_tools(["hisat2-build"])
            self.runner.run(
                "hisat2_build",
                ["hisat2-build", "-p", str(self.threads), *self._tool_args("hisat2_build"), self.reference_fasta, prefix],
            )
        else:
            raise ConfigError(f"Unknown short-read aligner: {aligner}")
        if not self.dry_run:
            marker.write_text(self.config_hash + "\n", encoding="utf-8")
        self._mark_checkpoint(f"index_{aligner}", [marker])
        return prefix

    def _short_aligner_roles(self) -> list[tuple[str, str]]:
        selected = self.methods["short_alignment"]
        if selected == "bowtie2_accuracy":
            return [("primary", "bowtie2")]
        if selected == "dual_bowtie2_bwa":
            return [("primary", "bowtie2"), ("alternative", "bwa-mem2")]
        if selected == "dual_bowtie2_hisat2":
            return [("primary", "bowtie2"), ("alternative", "hisat2")]
        if selected == "bwa_mem2":
            return [("primary", "bwa-mem2")]
        if selected == "hisat2_no_splice":
            return [("primary", "hisat2")]
        raise ConfigError(f"Unsupported short-read alignment method: {selected}")

    def _align_short_run(
        self,
        run_id: str,
        row: dict[str, Any],
        reads: tuple[Path, Path | None],
        role: str,
        aligner: str,
        index: Path,
    ) -> Path:
        sample_id = str(row["sample_id"])
        r1, r2 = reads
        out = self.work_dir / "alignment" / "short" / role / f"{run_id}.bam"
        out.parent.mkdir(parents=True, exist_ok=True)
        if self._checkpoint_valid(f"short_align_{role}_{aligner}_{run_id}", [out]):
            return out
        rg = f"@RG\\tID:{run_id}\\tSM:{sample_id}\\tLB:{sample_id}\\tPL:ILLUMINA\\tPU:{run_id}"

        self.runner.require_tools(["samtools"])
        if aligner == "bowtie2":
            self.runner.require_tools(["bowtie2"])
            preset = str(self.options.get("bowtie2_preset", "sensitive")).strip().lower() or "sensitive"
            mode = str(self.options.get("bowtie2_mode", "end-to-end")).strip().lower() or "end-to-end"
            args = [
                "bowtie2",
                f"--{mode}",
                "--threads",
                str(self.threads),
                "--rg-id",
                run_id,
                "--rg",
                f"SM:{sample_id}",
                "--rg",
                f"LB:{sample_id}",
                "--rg",
                "PL:ILLUMINA",
                "--rg",
                f"PU:{run_id}",
                "-x",
                os.fspath(index),
            ]
            if preset != "default":
                args.insert(2, f"--{preset}")
            args.extend(self._tool_args("bowtie2"))
            if r2:
                args.extend(["--no-mixed", "--no-discordant", "-1", os.fspath(r1), "-2", os.fspath(r2)])
            else:
                args.extend(["-U", os.fspath(r1)])
        elif aligner == "bwa-mem2":
            self.runner.require_tools(["bwa-mem2"])
            args = [
                "bwa-mem2", "mem", "-t", str(self.threads), "-Y", "-R", rg,
                *self._tool_args("bwa_mem2"), os.fspath(index), os.fspath(r1),
            ]
            if r2:
                args.append(os.fspath(r2))
        elif aligner == "hisat2":
            self.runner.require_tools(["hisat2"])
            args = [
                "hisat2",
                "--no-spliced-alignment",
                "--no-softclip",
                "-p",
                str(self.threads),
                "--rg-id",
                run_id,
                "--rg",
                f"SM:{sample_id}",
                "-x",
                os.fspath(index),
            ]
            args.extend(self._tool_args("hisat2"))
            if r2:
                args.extend(["-1", os.fspath(r1), "-2", os.fspath(r2)])
            else:
                args.extend(["-U", os.fspath(r1)])
        else:
            raise ConfigError(f"Unknown aligner: {aligner}")

        sort_options = self._quoted_tool_args("samtools_sort")
        sort_options = f" {sort_options}" if sort_options else ""
        script = f"{quote(args[0])} {' '.join(quote(item) for item in args[1:])} | samtools sort{sort_options} -@ {self.threads} -o {quote(out)} -"
        self.runner.run_shell(f"align_short_{role}_{aligner}_{run_id}", script)
        self._mark_checkpoint(f"short_align_{role}_{aligner}_{run_id}", [out])
        return out

    def _merge_bams(self, name: str, bams: list[Path], target: Path) -> Path:
        target.parent.mkdir(parents=True, exist_ok=True)
        bai = Path(str(target) + ".bai")
        if self._checkpoint_valid(name, [target, bai]):
            return target
        if not bams:
            raise ConfigError(f"No BAM inputs were available for {name}.")
        if len(bams) == 1:
            if self.dry_run:
                self.runner.run(f"copy_{name}", ["cp", "--", bams[0], target])
            else:
                self._copy_file(bams[0], target)
        else:
            self.runner.run(
                name,
                ["samtools", "merge", "-f", "-@", str(self.threads), *self._tool_args("samtools_merge"), target, *bams],
            )
        self.runner.run(
            f"index_{name}",
            ["samtools", "index", "-@", str(self.threads), *self._tool_args("samtools_index"), target],
        )
        self._mark_checkpoint(name, [target, bai])
        self.outputs.extend([target, bai])
        return target

    def _align_short(self, reads: dict[str, tuple[Path, Path | None]]) -> None:
        run_rows = dict(self._run_id_rows())
        for role, aligner in self._short_aligner_roles():
            index = self._build_short_index(aligner)
            per_sample: dict[str, list[Path]] = defaultdict(list)
            for run_id, pair in reads.items():
                row = run_rows[run_id]
                sample_id = str(row["sample_id"])
                per_sample[sample_id].append(
                    self._align_short_run(run_id, row, pair, role, aligner, index)
                )
                self.sample_layout[sample_id] = "paired" if pair[1] else "single"
            for sample_id, bams in per_sample.items():
                if self.methods.get("short_alignment") == "dual_bowtie2_hisat2":
                    target_name = f"{sample_id}.short.{aligner}.bam"
                else:
                    target_name = f"{sample_id}.short.{role}.bam"
                target = self.ready_dir / "bam" / "short" / role / target_name
                final = self._merge_bams(f"short_{role}_{aligner}_{sample_id}", bams, target)
                destination = self.primary_bams if role == "primary" else self.alternative_bams
                destination["short"][sample_id] = final

    def _long_preset(self, platform: str, aligner: str) -> str:
        if platform == "pacbio_hifi":
            return "map-hifi" if aligner == "minimap2" else "map-pb"
        if platform == "pacbio_clr":
            return "map-pb"
        return "map-ont"

    def _resolve_optional_script(self, env_name: str, relative: str, filename: str) -> Path | None:
        configured = str(self.methods.get(env_name.lower(), "")).strip()
        candidates = [
            runtime_path(configured) if configured else None,
            runtime_path(os.environ[env_name]) / filename if os.environ.get(env_name) else None,
            Path(__file__).resolve().parents[2] / "tools" / relative / filename,
        ]
        return next((path for path in candidates if path is not None and path.is_file()), None)

    def _prepare_long_reads(self) -> dict[str, tuple[Path, str]]:
        qc_method = self.methods["long_qc"]
        clean_dir = self.ready_dir / "cleaned_fastq" / "long"
        basecall_dir = self.ready_dir / "basecalls"
        clean_dir.mkdir(parents=True, exist_ok=True)
        basecall_dir.mkdir(parents=True, exist_ok=True)
        prepared: dict[str, tuple[Path, str]] = {}

        for run_id, row in self._run_id_rows():
            long_raw = str(row.get("long_reads", "")).strip()
            pod5_raw = str(row.get("pod5_dir", "")).strip()
            if not long_raw and not pod5_raw:
                continue
            platform = str(row["long_platform"])
            source_fastq: Path
            if pod5_raw:
                model = "sup" if self.methods["long_basecalling"] == "dorado_sup" else "hac"
                model = str(self.options.get("dorado_model", model)).strip() or model
                dorado_raw = str(self.options.get("dorado_path", "dorado")).strip() or "dorado"
                dorado = os.fspath(runtime_path(dorado_raw)) if dorado_raw != "dorado" else "dorado"
                calls_bam = basecall_dir / f"{run_id}.dorado.{safe_name(model, 'model')}.bam"
                source_fastq = clean_dir / f"{run_id}.basecalled.fastq.gz"
                if not self._checkpoint_valid(f"dorado_{run_id}", [calls_bam, source_fastq]):
                    self.runner.require_tools([dorado, "samtools", "pigz"])
                    self.runner.run(
                        f"dorado_{run_id}",
                        [dorado, "basecaller", model, *self._tool_args("dorado"), runtime_path(pod5_raw)],
                        stdout_path=calls_bam,
                    )
                    samtools_options = self._quoted_tool_args("samtools_fastq")
                    pigz_options = self._quoted_tool_args("pigz")
                    script = (
                        f"samtools fastq{' ' + samtools_options if samtools_options else ''} -@ {self.threads} {quote(calls_bam)} | "
                        f"pigz{' ' + pigz_options if pigz_options else ''} -p {self.threads} > {quote(source_fastq)}"
                    )
                    self.runner.run_shell(f"dorado_fastq_{run_id}", script)
                    self._mark_checkpoint(f"dorado_{run_id}", [calls_bam, source_fastq])
                self.outputs.extend([calls_bam, source_fastq])
            else:
                input_path = runtime_path(long_raw)
                if is_probably_bam(input_path):
                    source_fastq = clean_dir / f"{run_id}.from_bam.fastq.gz"
                    if not self._checkpoint_valid(f"long_bam_to_fastq_{run_id}", [source_fastq]):
                        self.runner.require_tools(["samtools", "pigz"])
                        samtools_options = self._quoted_tool_args("samtools_fastq")
                        pigz_options = self._quoted_tool_args("pigz")
                        script = (
                            f"samtools fastq{' ' + samtools_options if samtools_options else ''} -@ {self.threads} {quote(input_path)} | "
                            f"pigz{' ' + pigz_options if pigz_options else ''} -p {self.threads} > {quote(source_fastq)}"
                        )
                        self.runner.run_shell(f"long_bam_to_fastq_{run_id}", script)
                        self._mark_checkpoint(f"long_bam_to_fastq_{run_id}", [source_fastq])
                    self.outputs.append(source_fastq)
                else:
                    source_fastq = input_path

            final_fastq = source_fastq
            if bool(self.options.get("filter_long_reads", False)):
                final_fastq = clean_dir / f"{run_id}.filtered.fastq.gz"
                if not self._checkpoint_valid(f"long_filter_{run_id}", [final_fastq]):
                    self.runner.require_tools(["chopper", "pigz"])
                    reader = f"gzip -dc {quote(source_fastq)}" if source_fastq.name.endswith(".gz") else f"cat {quote(source_fastq)}"
                    chopper_options = self._quoted_tool_args("chopper")
                    pigz_options = self._quoted_tool_args("pigz")
                    script = (
                        f"{reader} | chopper --quality {float(self.options.get('long_min_quality', 10))} "
                        f"--minlength {int(self.options.get('long_min_length', 200))} --threads {self.threads}"
                        f"{' ' + chopper_options if chopper_options else ''} | "
                        f"pigz{' ' + pigz_options if pigz_options else ''} -p {self.threads} > {quote(final_fastq)}"
                    )
                    self.runner.run_shell(f"long_filter_{run_id}", script)
                    self._mark_checkpoint(f"long_filter_{run_id}", [final_fastq])
                self.outputs.append(final_fastq)

            qc_dir = self.ready_dir / "qc" / "long" / run_id
            qc_dir.mkdir(parents=True, exist_ok=True)
            if qc_method in {"nanoplot_longqc", "nanoplot", "long_qc_only"}:
                qc_inputs = [("raw", source_fastq)]
                if final_fastq != source_fastq:
                    qc_inputs.append(("filtered", final_fastq))
                for qc_label, qc_input in qc_inputs:
                    nanoplot_dir = qc_dir / f"NanoPlot_{qc_label}"
                    nanoplot_marker = nanoplot_dir / ".complete"
                    checkpoint = f"nanoplot_{qc_label}_{run_id}"
                    if not self._checkpoint_valid(checkpoint, [nanoplot_marker]):
                        self.runner.require_tools(["NanoPlot"])
                        self.runner.run(
                            checkpoint,
                            [
                                "NanoPlot", "--fastq", qc_input, "--threads", str(self.threads),
                                "--outdir", nanoplot_dir, *self._tool_args("nanoplot"),
                            ],
                        )
                        if not self.dry_run:
                            nanoplot_dir.mkdir(parents=True, exist_ok=True)
                            nanoplot_marker.write_text(self.config_hash + "\n", encoding="utf-8")
                        self._mark_checkpoint(checkpoint, [nanoplot_marker])
            if qc_method == "nanoplot_longqc":
                longqc = self._resolve_optional_script("LONGQC_HOME", "LongQC", "longQC.py")
                if longqc is None and not self.dry_run:
                    raise CommandFailed(
                        "LongQC was selected but longQC.py was not found. Run the optional-tools installer or select NanoPlot only."
                    )
                longqc = longqc or Path("longQC.py")
                preset = "ont-ligation" if platform.startswith("ont_") else "pb-sequel"
                longqc_dir = qc_dir / "LongQC"
                longqc_marker = longqc_dir / ".complete"
                if not self._checkpoint_valid(f"longqc_{run_id}", [longqc_marker]):
                    self.runner.run(
                        f"longqc_{run_id}",
                        [
                            "python", longqc, "sampleqc", "-x", preset, "-t", "-p", str(self.threads),
                            "-o", longqc_dir, *self._tool_args("longqc"), final_fastq,
                        ],
                    )
                    if not self.dry_run:
                        longqc_dir.mkdir(parents=True, exist_ok=True)
                        longqc_marker.write_text(self.config_hash + "\n", encoding="utf-8")
                    self._mark_checkpoint(f"longqc_{run_id}", [longqc_marker])
            prepared[run_id] = (final_fastq, platform)
        return prepared

    def _long_aligner_roles(self) -> list[tuple[str, str]]:
        selected = self.methods["long_alignment"]
        if selected == "minimap2":
            return [("primary", "minimap2")]
        if selected == "dual_minimap2_winnowmap":
            return [("primary", "minimap2"), ("alternative", "winnowmap")]
        if selected == "winnowmap2":
            return [("primary", "winnowmap")]
        raise ConfigError(f"Unsupported long-read alignment method: {selected}")

    def _winnowmap_repeats(self) -> Path:
        repeats = self.work_dir / "indexes" / "winnowmap" / "repetitive_k15.txt"
        marker = repeats.parent / ".complete"
        repeats.parent.mkdir(parents=True, exist_ok=True)
        if self._checkpoint_valid("winnowmap_repeats", [repeats, marker]):
            return repeats
        self.runner.require_tools(["meryl"])
        database = repeats.parent / "reference.meryl"
        count_options = self._quoted_tool_args("meryl_count")
        print_options = self._quoted_tool_args("meryl_print")
        script = (
            f"meryl k=15 count{' ' + count_options if count_options else ''} output {quote(database)} {quote(self.reference_fasta)} && "
            f"meryl print greater-than distinct=0.9998{' ' + print_options if print_options else ''} {quote(database)} > {quote(repeats)}"
        )
        self.runner.run_shell("winnowmap_repetitive_kmers", script)
        if not self.dry_run:
            marker.write_text(self.config_hash + "\n", encoding="utf-8")
        self._mark_checkpoint("winnowmap_repeats", [repeats, marker])
        return repeats

    def _align_long_run(
        self,
        run_id: str,
        row: dict[str, Any],
        reads: Path,
        platform: str,
        role: str,
        aligner: str,
    ) -> Path:
        sample_id = str(row["sample_id"])
        out = self.work_dir / "alignment" / "long" / role / f"{run_id}.bam"
        out.parent.mkdir(parents=True, exist_ok=True)
        if self._checkpoint_valid(f"long_align_{role}_{aligner}_{run_id}", [out]):
            return out
        preset = self._long_preset(platform, aligner)
        rg = f"@RG\\tID:{run_id}\\tSM:{sample_id}\\tLB:{sample_id}\\tPL:{'ONT' if platform.startswith('ont_') else 'PACBIO'}\\tPU:{run_id}"
        self.runner.require_tools(["samtools"])
        if aligner == "minimap2":
            self.runner.require_tools(["minimap2"])
            args = [
                "minimap2", "-a", "-x", preset, "--secondary=yes", "-t", str(self.threads),
                "-R", rg, *self._tool_args("minimap2"), self.reference_fasta, reads,
            ]
        elif aligner == "winnowmap":
            self.runner.require_tools(["winnowmap"])
            repeats = self._winnowmap_repeats()
            args = [
                "winnowmap", "-W", repeats, "-a", "-x", preset, "-t", str(self.threads),
                "-R", rg, *self._tool_args("winnowmap"), self.reference_fasta, reads,
            ]
        else:
            raise ConfigError(f"Unknown long-read aligner: {aligner}")
        sort_options = self._quoted_tool_args("samtools_sort")
        sort_options = f" {sort_options}" if sort_options else ""
        script = f"{quote(args[0])} {' '.join(quote(item) for item in args[1:])} | samtools sort{sort_options} -@ {self.threads} -o {quote(out)} -"
        self.runner.run_shell(f"align_long_{role}_{aligner}_{run_id}", script)
        self._mark_checkpoint(f"long_align_{role}_{aligner}_{run_id}", [out])
        return out

    def _align_long(self, reads: dict[str, tuple[Path, str]]) -> None:
        run_rows = dict(self._run_id_rows())
        for role, aligner in self._long_aligner_roles():
            per_sample: dict[str, list[Path]] = defaultdict(list)
            for run_id, (read_path, platform) in reads.items():
                row = run_rows[run_id]
                sample_id = str(row["sample_id"])
                per_sample[sample_id].append(
                    self._align_long_run(run_id, row, read_path, platform, role, aligner)
                )
                self.sample_layout[f"long::{sample_id}"] = "single"
            for sample_id, bams in per_sample.items():
                target = self.ready_dir / "bam" / "long" / role / f"{sample_id}.long.{role}.bam"
                final = self._merge_bams(f"long_{role}_{sample_id}", bams, target)
                destination = self.primary_bams if role == "primary" else self.alternative_bams
                destination["long"][sample_id] = final

    @staticmethod
    def _parse_flagstat(path: Path) -> tuple[int, int, str]:
        primary = 0
        mapped = 0
        percent = ""
        if not path.is_file():
            return primary, mapped, percent
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            if re.search(r"\bprimary$", line):
                primary = int(line.split()[0])
            if " primary mapped " in f" {line} ":
                mapped = int(line.split()[0])
                match = re.search(r"\(([^:]+)%", line)
                percent = match.group(1) if match else ""
        return primary, mapped, percent

    def _bam_qc(self) -> None:
        self.runner.require_tools(["samtools"])
        all_sets = (("primary", self.primary_bams), ("alternative", self.alternative_bams))
        for role, modalities in all_sets:
            for modality, sample_bams in modalities.items():
                for sample_id, bam in sample_bams.items():
                    qc_dir = self.ready_dir / "qc" / "alignment" / modality / role
                    qc_dir.mkdir(parents=True, exist_ok=True)
                    flagstat = qc_dir / f"{sample_id}.flagstat.txt"
                    stats = qc_dir / f"{sample_id}.samtools_stats.txt"
                    idxstats = qc_dir / f"{sample_id}.idxstats.tsv"
                    if not self._checkpoint_valid(f"bam_qc_{modality}_{role}_{sample_id}", [flagstat, stats, idxstats]):
                        self.runner.run(
                            f"quickcheck_{modality}_{role}_{sample_id}",
                            ["samtools", "quickcheck", "-v", *self._tool_args("samtools_quickcheck"), bam],
                        )
                        self.runner.run(
                            f"flagstat_{modality}_{role}_{sample_id}",
                            ["samtools", "flagstat", "-@", str(self.threads), *self._tool_args("samtools_flagstat"), bam],
                            stdout_path=flagstat,
                        )
                        self.runner.run(
                            f"stats_{modality}_{role}_{sample_id}",
                            ["samtools", "stats", "-@", str(self.threads), *self._tool_args("samtools_stats"), bam],
                            stdout_path=stats,
                        )
                        self.runner.run(
                            f"idxstats_{modality}_{role}_{sample_id}",
                            ["samtools", "idxstats", *self._tool_args("samtools_idxstats"), bam],
                            stdout_path=idxstats,
                        )
                        self._mark_checkpoint(f"bam_qc_{modality}_{role}_{sample_id}", [flagstat, stats, idxstats])
                    primary, mapped, percent = self._parse_flagstat(flagstat)
                    aligner = self._aligner_for(modality, role)
                    self.alignment_summary.append(
                        {
                            "sample_id": sample_id,
                            "modality": modality,
                            "role": role,
                            "aligner": aligner,
                            "primary_records": primary,
                            "mapped_primary_records": mapped,
                            "mapped_percent": percent,
                        }
                    )
                    self.outputs.extend([flagstat, stats, idxstats])

        summary_path = self.ready_dir / "qc" / "alignment" / "alignment_summary.tsv"
        summary_path.parent.mkdir(parents=True, exist_ok=True)
        fields = [
            "sample_id",
            "modality",
            "role",
            "aligner",
            "primary_records",
            "mapped_primary_records",
            "mapped_percent",
        ]
        with summary_path.open("w", encoding="utf-8", newline="\n") as handle:
            writer = csv.DictWriter(handle, fieldnames=fields, delimiter="\t")
            writer.writeheader()
            writer.writerows(self.alignment_summary)
        self.outputs.append(summary_path)

    def _aligner_for(self, modality: str, role: str) -> str:
        roles = self._short_aligner_roles() if modality == "short" else self._long_aligner_roles()
        return next((aligner for selected_role, aligner in roles if selected_role == role), "")

    @staticmethod
    def _strand_code(value: str) -> str:
        return {"unstranded": "0", "forward": "1", "reverse": "2"}.get(value, "0")

    @staticmethod
    def _fadu_strand(value: str) -> str:
        return {"unstranded": "no", "forward": "yes", "reverse": "reverse"}.get(value, "no")

    def _declared_strand(self, modality: str) -> str:
        key = f"{modality}_strand"
        return str(self.library.get(key, self.library.get("strand", "auto"))).strip().lower()

    def _featurecounts_command(
        self,
        bam: Path,
        output: Path,
        strand: str,
        *,
        paired: bool,
        long_read: bool = False,
    ) -> list[object]:
        command: list[object] = [
            "featureCounts",
            "-T",
            "1" if long_read else str(self.threads),
            "-F",
            "SAF",
            "-a",
            self.saf,
            "-o",
            output,
            "-s",
            self._strand_code(strand),
            "-Q",
            str(self.min_mapq),
            "--primary",
        ]
        if paired:
            command.extend(["-p", "--countReadPairs", "-B", "-C"])
        if long_read:
            command.append("-L")
        command.extend(self._tool_args("featurecounts"))
        command.append(bam)
        return command

    def _audit_strand(self, modality: str, sample_id: str, bam: Path) -> str:
        audit_dir = self.ready_dir / "qc" / "strand_audit" / modality / sample_id
        audit_dir.mkdir(parents=True, exist_ok=True)
        paired = modality == "short" and self.sample_layout.get(sample_id) == "paired"
        assigned: dict[str, int] = {}
        for strand in ("forward", "reverse"):
            output = audit_dir / f"{strand}.counts.tsv"
            summary = Path(str(output) + ".summary")
            if not self._checkpoint_valid(f"strand_{modality}_{sample_id}_{strand}", [output, summary]):
                self.runner.run(
                    f"strand_audit_{modality}_{sample_id}_{strand}",
                    self._featurecounts_command(
                        bam,
                        output,
                        strand,
                        paired=paired,
                        long_read=modality == "long",
                    ),
                )
                self._mark_checkpoint(f"strand_{modality}_{sample_id}_{strand}", [output, summary])
            assigned[strand] = parse_featurecounts_assigned(summary)

        total = assigned["forward"] + assigned["reverse"]
        dominance = max(assigned.values()) / total if total else 0.0
        minimum = int(self.options.get("strand_audit_min_assigned", 1000))
        threshold = float(self.options.get("strand_audit_dominance", 0.80))
        if total >= minimum and dominance >= threshold:
            inferred = "forward" if assigned["forward"] > assigned["reverse"] else "reverse"
        else:
            inferred = "unstranded"

        declared = self._declared_strand(modality)
        effective = inferred if declared == "auto" else declared
        status = "accepted"
        if declared in {"forward", "reverse"} and inferred in {"forward", "reverse"} and declared != inferred:
            status = "contradiction"
            message = (
                f"{modality} sample {sample_id}: declared {declared} but the count audit inferred {inferred}."
            )
            self.warnings.append(message)
            if bool(self.project_dir and self.config["project"].get("strict_strand_audit", True)) and not self.dry_run:
                raise ConfigError(message + " Correct the library setting or disable strict strand checking.")
        elif inferred == "unstranded":
            status = "inconclusive"
            if declared == "auto":
                self.warnings.append(
                    f"{modality} sample {sample_id}: strand audit was inconclusive; unstranded counting was used."
                )

        self.strand_summary.append(
            {
                "sample_id": sample_id,
                "modality": modality,
                "declared": declared,
                "inferred": inferred,
                "effective": effective,
                "forward_assigned": assigned["forward"],
                "reverse_assigned": assigned["reverse"],
                "dominance": round(dominance, 4),
                "status": status,
            }
        )
        self.effective_strand[(modality, sample_id)] = effective
        self.outputs.extend(
            [
                audit_dir / "forward.counts.tsv",
                audit_dir / "forward.counts.tsv.summary",
                audit_dir / "reverse.counts.tsv",
                audit_dir / "reverse.counts.tsv.summary",
            ]
        )
        return effective

    def _write_strand_summary(self) -> None:
        audit_path = self.ready_dir / "qc" / "strand_audit" / "strand_audit_summary.tsv"
        audit_path.parent.mkdir(parents=True, exist_ok=True)
        if not self.strand_summary:
            return
        fields = list(self.strand_summary[0])
        with audit_path.open("w", encoding="utf-8", newline="\n") as handle:
            writer = csv.DictWriter(handle, fieldnames=fields, delimiter="\t")
            writer.writeheader()
            writer.writerows(self.strand_summary)
        self.outputs.append(audit_path)

    def _run_primary_counts(self) -> None:
        method = self.methods["quantification"]
        self.runner.require_tools(["featureCounts"])
        if method == "skip_counts":
            for modality, sample_bams in self.primary_bams.items():
                for sample_id, bam in sample_bams.items():
                    self._audit_strand(modality, sample_id, bam)
            self._write_strand_summary()
            return
        for modality, sample_bams in self.primary_bams.items():
            per_sample: dict[str, dict[str, float]] = {}
            fadu_per_sample: dict[str, dict[str, float]] = {}
            for sample_id, bam in sample_bams.items():
                effective = self._audit_strand(modality, sample_id, bam)
                paired = modality == "short" and self.sample_layout.get(sample_id) == "paired"
                count_dir = self.ready_dir / "counts" / modality / method / "per_sample"

                if method in {"featurecounts", "featurecounts_fadu_audit"}:
                    audit_output = (
                        self.ready_dir
                        / "qc"
                        / "strand_audit"
                        / modality
                        / sample_id
                        / f"{effective}.counts.tsv"
                    )
                    audit_summary = Path(str(audit_output) + ".summary")
                    if effective in {"forward", "reverse"} and audit_output.is_file() and audit_summary.is_file():
                        # The selected audit pass used the same BAM, SAF, MAPQ,
                        # pairing, primary-alignment, long-read, and strand
                        # arguments as primary featureCounts. Reuse it exactly
                        # instead of running an identical third counting pass.
                        output = audit_output
                        summary = audit_summary
                        self.runner._append_log(
                            f"REUSE featureCounts: {modality} {sample_id} primary counts "
                            f"use the identical {effective}-strand audit output."
                        )
                    else:
                        count_dir.mkdir(parents=True, exist_ok=True)
                        output = count_dir / f"{sample_id}.featureCounts.tsv"
                        summary = Path(str(output) + ".summary")
                        if not self._checkpoint_valid(f"counts_featurecounts_{modality}_{sample_id}", [output, summary]):
                            self.runner.run(
                                f"featurecounts_{modality}_{sample_id}",
                                self._featurecounts_command(
                                    bam,
                                    output,
                                    effective,
                                    paired=paired,
                                    long_read=modality == "long",
                                ),
                            )
                            self._mark_checkpoint(f"counts_featurecounts_{modality}_{sample_id}", [output, summary])
                    per_sample[sample_id] = parse_featurecounts_counts(output)
                    if output.parent == count_dir:
                        self.outputs.extend([output, summary])

                if method == "htseq":
                    self.runner.require_tools(["htseq-count"])
                    count_dir.mkdir(parents=True, exist_ok=True)
                    output = count_dir / f"{sample_id}.htseq.tsv"
                    stranded = {"unstranded": "no", "forward": "yes", "reverse": "reverse"}[effective]
                    if not self._checkpoint_valid(f"counts_htseq_{modality}_{sample_id}", [output]):
                        self.runner.run(
                            f"htseq_{modality}_{sample_id}",
                            [
                                "htseq-count",
                                "--format=bam",
                                "--order=pos",
                                f"--stranded={stranded}",
                                "--type=gene",
                                "--idattr=ID",
                                "--nonunique=none",
                                *self._tool_args("htseq_count"),
                                bam,
                                self.normalized_gff,
                            ],
                            stdout_path=output,
                        )
                        self._mark_checkpoint(f"counts_htseq_{modality}_{sample_id}", [output])
                    per_sample[sample_id] = parse_htseq_counts(output)
                    self.outputs.append(output)

                if method in {"fadu", "featurecounts_fadu_audit"}:
                    optional_audit = method == "featurecounts_fadu_audit"
                    if modality == "long":
                        message = (
                            f"FADU audit skipped for {sample_id}: FADU is a short-fragment bacterial overlap audit and is not used for long reads. "
                            "The featureCounts integer matrix remains the exported analysis-ready count matrix."
                        )
                        self._record_fadu_audit_status(modality, sample_id, "skipped_long_read", message)
                        continue

                    fadu_script = self._resolve_optional_script("FADU_HOME", "FADU", "fadu.jl")
                    julia_path = shutil.which("julia")
                    if (fadu_script is None or julia_path is None) and not self.dry_run:
                        missing_parts = []
                        if fadu_script is None:
                            missing_parts.append("fadu.jl")
                        if julia_path is None:
                            missing_parts.append("Julia")
                        missing_text = " and ".join(missing_parts)
                        message = (
                            f"FADU audit skipped for {sample_id}: optional {missing_text} was not found. "
                            "The featureCounts integer matrix was exported successfully and remains valid for downstream differential expression. "
                            "Install optional FADU tools later only if the secondary overlap audit is required."
                        )
                        if optional_audit:
                            self._record_fadu_audit_status(
                                modality, sample_id, "skipped_missing_optional_tool", message
                            )
                            continue
                        raise CommandFailed(
                            f"FADU-only counting requires {missing_text}. Run the optional-tools installer or choose featureCounts."
                        )

                    fadu_script = fadu_script or Path("fadu.jl")
                    fadu_dir = self.ready_dir / "counts" / modality / "fadu" / sample_id
                    fadu_dir.mkdir(parents=True, exist_ok=True)
                    output = fadu_dir / f"{bam.stem}.counts.txt"
                    try:
                        if not self._checkpoint_valid(f"counts_fadu_{sample_id}", [output]):
                            command: list[object] = [
                                julia_path or "julia",
                                fadu_script,
                                "-g",
                                self.normalized_gff,
                                "-b",
                                bam,
                                "-o",
                                fadu_dir,
                                "-s",
                                self._fadu_strand(effective),
                                "-f",
                                "gene",
                                "-a",
                                "ID",
                            ]
                            if paired:
                                command.append("-p")
                            command.extend(self._tool_args("fadu"))
                            self.runner.run(f"fadu_{sample_id}", command)
                            self._mark_checkpoint(f"counts_fadu_{sample_id}", [output])
                        fadu_per_sample[sample_id] = parse_fadu_counts(output)
                        self.outputs.append(output)
                        self._record_fadu_audit_status(
                            modality,
                            sample_id,
                            "complete",
                            f"FADU audit completed for {sample_id}. The fractional audit is stored separately from the featureCounts matrix.",
                        )
                    except Exception as exc:
                        if not optional_audit:
                            raise
                        message = (
                            f"FADU audit failed for {sample_id} and was skipped: {exc}. "
                            "The featureCounts integer matrix was already exported successfully and the pipeline will continue."
                        )
                        self._record_fadu_audit_status(
                            modality, sample_id, "failed_optional_audit", message
                        )

            if per_sample:
                label = "featurecounts" if method.startswith("featurecounts") else method
                if modality == "short" and self.methods.get("short_alignment") == "dual_bowtie2_hisat2":
                    label = f"bowtie2_{label}"
                matrix = self.ready_dir / "counts" / modality / f"{label}_raw_counts.tsv"
                write_count_matrix(matrix, per_sample)
                self.outputs.append(matrix)
            if fadu_per_sample:
                matrix = self.ready_dir / "counts" / modality / "fadu_fractional_counts.tsv"
                write_count_matrix(matrix, fadu_per_sample)
                self.outputs.append(matrix)

        if self.methods.get("short_alignment") == "dual_bowtie2_hisat2" and self.alternative_bams.get("short"):
            # Dual Bowtie2 + HISAT2 mode deliberately quantifies the two alignments
            # independently.  The alternative matrix is never merged with the
            # Bowtie2 matrix and is not treated as an additional biological sample.
            hisat2_counts: dict[str, dict[str, float]] = {}
            for sample_id, bam in self.alternative_bams["short"].items():
                effective = self.effective_strand.get(("short", sample_id), self._declared_strand("short"))
                if effective == "auto":
                    effective = "unstranded"
                paired = self.sample_layout.get(sample_id) == "paired"
                if method in {"featurecounts", "featurecounts_fadu_audit"}:
                    count_dir = self.ready_dir / "counts" / "short" / method / "hisat2" / "per_sample"
                    count_dir.mkdir(parents=True, exist_ok=True)
                    output = count_dir / f"{sample_id}.hisat2.featureCounts.tsv"
                    summary = Path(str(output) + ".summary")
                    checkpoint = f"counts_featurecounts_short_hisat2_{sample_id}"
                    if not self._checkpoint_valid(checkpoint, [output, summary]):
                        self.runner.run(
                            f"featurecounts_short_hisat2_{sample_id}",
                            self._featurecounts_command(
                                bam, output, effective, paired=paired, long_read=False
                            ),
                        )
                        self._mark_checkpoint(checkpoint, [output, summary])
                    hisat2_counts[sample_id] = parse_featurecounts_counts(output)
                    self.outputs.extend([output, summary])
                elif method == "htseq":
                    self.runner.require_tools(["htseq-count"])
                    count_dir = self.ready_dir / "counts" / "short" / "htseq" / "hisat2" / "per_sample"
                    count_dir.mkdir(parents=True, exist_ok=True)
                    output = count_dir / f"{sample_id}.hisat2.htseq.tsv"
                    stranded = {"unstranded": "no", "forward": "yes", "reverse": "reverse"}[effective]
                    checkpoint = f"counts_htseq_short_hisat2_{sample_id}"
                    if not self._checkpoint_valid(checkpoint, [output]):
                        self.runner.run(
                            f"htseq_short_hisat2_{sample_id}",
                            [
                                "htseq-count",
                                "--format=bam",
                                "--order=pos",
                                f"--stranded={stranded}",
                                "--type=gene",
                                "--idattr=ID",
                                "--nonunique=none",
                                *self._tool_args("htseq_count"),
                                bam,
                                self.normalized_gff,
                            ],
                            stdout_path=output,
                        )
                        self._mark_checkpoint(checkpoint, [output])
                    hisat2_counts[sample_id] = parse_htseq_counts(output)
                    self.outputs.append(output)
                elif method == "skip_counts":
                    continue
                elif method == "fadu":
                    # FADU is fractional and is kept as an optional audit layer.
                    # The dual-aligner workbook guarantee concerns raw integer
                    # matrices, so use featureCounts or HTSeq when two count
                    # sheets are desired.
                    continue

            if hisat2_counts:
                label = "featurecounts" if method.startswith("featurecounts") else method
                matrix = self.ready_dir / "counts" / "short" / f"hisat2_{label}_raw_counts.tsv"
                write_count_matrix(matrix, hisat2_counts)
                self.outputs.append(matrix)

        self._write_fadu_audit_status()
        self._write_strand_summary()

    def _coverage_command(
        self,
        bam: Path,
        output: Path,
        normalization: str,
        strand_argument: str | None,
        include_flag: int | None = None,
        exclude_flag: int = 2304,
    ) -> list[object]:
        output_format = "bigwig" if output.suffix.lower() == ".bw" else "bedgraph"
        command: list[object] = [
            "bamCoverage",
            "--bam",
            bam,
            "--outFileName",
            output,
            "--outFileFormat",
            output_format,
            "--binSize",
            "1",
            "--numberOfProcessors",
            str(self.threads),
            "--minMappingQuality",
            str(self.min_mapq),
            "--samFlagExclude",
            str(exclude_flag),
            "--normalizeUsing",
            normalization,
            "--exactScaling",
        ]
        if strand_argument:
            command.extend(["--filterRNAstrand", strand_argument])
        if include_flag is not None:
            command.extend(["--samFlagInclude", str(include_flag)])
        command.extend(self._tool_args("bamcoverage"))
        return command

    def _make_coverage(self) -> None:
        method = self.methods["coverage"]
        self.runner.require_tools(["bamCoverage"])
        for modality, sample_bams in self.primary_bams.items():
            for sample_id, bam in sample_bams.items():
                effective = self.effective_strand.get((modality, sample_id), self._declared_strand(modality))
                if effective == "auto":
                    effective = "unstranded"
                root = self.ready_dir / "coverage" / modality / sample_id
                root.mkdir(parents=True, exist_ok=True)
                jobs: list[tuple[str, str | None, str, int | None, int]] = []
                suffixes = (".bw",)
                if method == "cpm_bigwig_stranded":
                    if effective in {"forward", "reverse"}:
                        if modality == "short":
                            for label in ("plus_transcript", "minus_transcript"):
                                requested = "forward" if label == "plus_transcript" else "reverse"
                                argument = requested if effective == "reverse" else ("reverse" if requested == "forward" else "forward")
                                jobs.append((f"cpm.{label}", argument, "CPM", None, 2304))
                        else:
                            plus_include = None if effective == "forward" else 16
                            plus_exclude = 2320 if effective == "forward" else 2304
                            minus_include = 16 if effective == "forward" else None
                            minus_exclude = 2304 if effective == "forward" else 2320
                            jobs.extend(
                                [
                                    ("cpm.plus_transcript", None, "CPM", plus_include, plus_exclude),
                                    ("cpm.minus_transcript", None, "CPM", minus_include, minus_exclude),
                                ]
                            )
                    else:
                        jobs.append(("cpm", None, "CPM", None, 2304))
                else:
                    jobs.append(("raw", None, "None", None, 2304))
                if method == "raw_and_cpm_stranded":
                    suffixes = (".bw", ".bedgraph")
                    jobs.append(("cpm", None, "CPM", None, 2304))
                    if effective in {"forward", "reverse"}:
                        if modality == "short":
                            for label in ("plus_transcript", "minus_transcript"):
                                requested = "forward" if label == "plus_transcript" else "reverse"
                                argument = requested if effective == "reverse" else ("reverse" if requested == "forward" else "forward")
                                jobs.append((f"raw.{label}", argument, "None", None, 2304))
                                jobs.append((f"cpm.{label}", argument, "CPM", None, 2304))
                        else:
                            plus_include = None if effective == "forward" else 16
                            plus_exclude = 2320 if effective == "forward" else 2304
                            minus_include = 16 if effective == "forward" else None
                            minus_exclude = 2304 if effective == "forward" else 2320
                            jobs.extend(
                                [
                                    ("raw.plus_transcript", None, "None", plus_include, plus_exclude),
                                    ("cpm.plus_transcript", None, "CPM", plus_include, plus_exclude),
                                    ("raw.minus_transcript", None, "None", minus_include, minus_exclude),
                                    ("cpm.minus_transcript", None, "CPM", minus_include, minus_exclude),
                                ]
                            )

                for label, strand_argument, normalization, include_flag, exclude_flag in jobs:
                    for suffix in suffixes:
                        output = root / f"{sample_id}.{label}{suffix}"
                        checkpoint = f"coverage_{modality}_{sample_id}_{label}_{suffix[1:]}"
                        if not self._checkpoint_valid(checkpoint, [output]):
                            self.runner.run(
                                checkpoint,
                                self._coverage_command(
                                    bam,
                                    output,
                                    normalization,
                                    strand_argument,
                                    include_flag,
                                    exclude_flag,
                                ),
                            )
                            self._mark_checkpoint(checkpoint, [output])
                        self.outputs.append(output)

    def _write_igv_session(self) -> None:
        browser_root = self.ready_dir / "Intermediate files" / "Browser files"
        igv_dir = browser_root / "IGV"
        igv_dir.mkdir(parents=True, exist_ok=True)
        session = igv_dir / "Analysis ready session.xml"
        resources: list[str] = []
        for modality, sample_bams in self.primary_bams.items():
            for sample_id, bam in sample_bams.items():
                relative = os.path.relpath(bam, igv_dir).replace(os.sep, "/")
                resources.append(f'    <Resource path="{relative}" name="{sample_id} {modality} primary"/>')
        for path in sorted((browser_root / "Coverage tracks").rglob("*.bw")):
            relative = os.path.relpath(path, igv_dir).replace(os.sep, "/")
            resources.append(f'    <Resource path="{relative}"/>')
        genome = os.path.relpath(self.reference_fasta, igv_dir).replace(os.sep, "/")
        annotation = os.path.relpath(self.normalized_gff, igv_dir).replace(os.sep, "/")
        resources.append(f'    <Resource path="{annotation}" name="Normalized annotation"/>')
        session.write_text(
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?>\n"
            f'<Session genome="{genome}" locus="All" version="8">\n'
            "  <Resources>\n"
            + "\n".join(resources)
            + "\n  </Resources>\n</Session>\n",
            encoding="utf-8",
        )
        (igv_dir / "README.txt").write_text(
            "Open Analysis ready session.xml in IGV. Relative paths point to the retained Alignments and Browser files folders.\n",
            encoding="utf-8",
        )
        self.outputs.extend([session, igv_dir / "README.txt"])

    def _run_multiqc(self) -> None:
        output_dir = self.ready_dir / "qc" / "multiqc"
        output_dir.mkdir(parents=True, exist_ok=True)
        report = output_dir / "multiqc_report.html"
        if self._checkpoint_valid("multiqc", [report]):
            self.outputs.append(report)
            return
        self.runner.require_tools(["multiqc"])
        self.runner.run(
            "multiqc",
            [
                "multiqc", self.run_root, "--outdir", output_dir, "--force",
                "--filename", "multiqc_report.html", *self._tool_args("multiqc"),
            ],
        )
        self._mark_checkpoint("multiqc", [report])
        self.outputs.append(report)

    def _write_versions(self) -> None:
        tools = [
            "python",
            "samtools",
            "fastqc",
            "multiqc",
            "featureCounts",
            "bamCoverage",
        ]
        for key in ("short_qc", "short_alignment", "long_qc", "long_alignment", "long_basecalling"):
            value = str(self.methods.get(key, ""))
            if "fastp" in value:
                tools.append("fastp")
            if "cutadapt" in value:
                tools.append("cutadapt")
            if "bowtie2" in value:
                tools.extend(["bowtie2", "bowtie2-build"])
            if "bwa" in value:
                tools.append("bwa-mem2")
            if "hisat2" in value:
                tools.append("hisat2")
            if "nanoplot" in value:
                tools.append("NanoPlot")
            if "minimap2" in value:
                tools.append("minimap2")
            if "winnowmap" in value:
                tools.extend(["winnowmap", "meryl"])
            if "dorado" in value:
                dorado_raw = str(self.options.get("dorado_path", "dorado")).strip() or "dorado"
                tools.append(os.fspath(runtime_path(dorado_raw)) if dorado_raw != "dorado" else "dorado")
        if self.methods.get("quantification") in {"fadu", "featurecounts_fadu_audit"}:
            tools.append("julia")
        if self.methods.get("quantification") == "htseq":
            tools.append("htseq-count")

        version_path = self.ready_dir / "metadata" / "Software versions.tsv"
        version_path.parent.mkdir(parents=True, exist_ok=True)
        provenance_lines: list[str] = []
        with version_path.open("w", encoding="utf-8", newline="\n") as handle:
            handle.write("tool\tresolved_path\texecutable_sha256\tversion_text\n")
            for tool in sorted(set(tools)):
                self.runner.check_stop()
                resolved = shutil.which(tool)
                if not resolved:
                    handle.write(f"{tool}\tNOT FOUND\t\t\n")
                    provenance_lines.append(f"TOOL\t{tool}\tNOT FOUND")
                    continue
                digest = sha256_file(Path(resolved)) if Path(resolved).is_file() else ""
                version = ""
                for flag in ("--version", "-V", "-v", "version"):
                    try:
                        result = subprocess.run(
                            [resolved, flag],
                            stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT,
                            text=True,
                            timeout=10,
                            check=False,
                        )
                        version = " ".join(result.stdout.splitlines()[:2]).strip()
                        if result.returncode == 0 and version:
                            break
                        version = ""
                    except (OSError, subprocess.TimeoutExpired):
                        continue
                clean_version = version.replace(chr(9), " ")
                handle.write(f"{tool}\t{resolved}\t{digest}\t{clean_version}\n")
                provenance_lines.append(
                    f"TOOL\t{tool}\tpath={resolved}\tsha256={digest}\tversion={clean_version}"
                )
        self.outputs.append(version_path)

        append = self.runner._append_log
        append("")
        append("=" * 96)
        append("THIRD-PARTY SOFTWARE PROVENANCE")
        append("=" * 96)
        append("Compiled executables cannot expose their original source lines at runtime.")
        append("The log records exact executable hashes plus a bounded package identity table containing build, channel, license, dependency, binary URL, package hash, upstream URL, and complete metadata-file hash fields when supplied by the distributor.")
        append("Conda file inventories (files and paths_data.paths) are intentionally not printed: they are installation manifests, not source code or generated analysis code. The metadata_sha256 field fingerprints every complete original record without creating a multi-hundred-thousand-line log.")
        for line in provenance_lines:
            append(line)

        package_path = self.ready_dir / "metadata" / "Third-party package provenance.tsv"
        explicit_path = self.ready_dir / "metadata" / "Conda explicit package URLs.txt"
        package_fields = [
            "package", "version", "build", "build_number", "subdir", "channel",
            "license", "license_family", "package_url", "package_sha256", "package_md5",
            "requested_spec", "dependencies", "upstream_urls", "metadata_file",
            "metadata_sha256", "metadata_status",
        ]
        package_records: list[dict[str, str]] = []
        raw_conda_prefix = os.environ.get("CONDA_PREFIX", "").strip()
        conda_meta = (
            Path(raw_conda_prefix) / "conda-meta"
            if raw_conda_prefix
            else Path("/__conda_prefix_not_set__")
        )
        if conda_meta.is_dir():
            for metadata_path in sorted(conda_meta.glob("*.json")):
                self.runner.check_stop()
                package_records.append(_conda_package_record(metadata_path))
        else:
            append("CONDA PACKAGE METADATA\tNOT AVAILABLE\tCONDA_PREFIX was not set to an environment with conda-meta")

        with package_path.open("w", encoding="utf-8", newline="") as handle:
            writer = csv.DictWriter(
                handle,
                fieldnames=package_fields,
                delimiter="\t",
                lineterminator="\n",
            )
            writer.writeheader()
            writer.writerows(package_records)
        with explicit_path.open("w", encoding="utf-8", newline="\n") as handle:
            handle.write("@EXPLICIT\n")
            for record in package_records:
                package_url = record["package_url"]
                package_hash = record["package_sha256"] or record["package_md5"]
                if package_url:
                    suffix = f"#{package_hash}" if package_hash and "#" not in package_url else ""
                    handle.write(package_url + suffix + "\n")
                else:
                    handle.write(
                        f"# {record['package']}={record['version']}={record['build']} "
                        f"metadata_sha256={record['metadata_sha256']}\n"
                    )
        self.outputs.extend([package_path, explicit_path])

        append("CONDA PACKAGE FIELDS\t" + "\t".join(package_fields))
        for record in package_records:
            self.runner.check_stop()
            append("CONDA PACKAGE\t" + "\t".join(record[field] for field in package_fields))
        append(f"CONDA PACKAGE COUNT\t{len(package_records)}")
        append("END THIRD-PARTY SOFTWARE PROVENANCE")
        append("=" * 96)

    def _compact_outputs(self, workbook: Path) -> None:
        moves = compact_successful_export(
            self.ready_dir,
            self.work_dir,
            workbook,
            self.runner._append_log,
        )

        self.reference_fasta = remap_path(self.reference_fasta, moves)
        self.normalized_gff = remap_path(self.normalized_gff, moves)
        self.saf = remap_path(self.saf, moves)
        for collection in (self.primary_bams, self.alternative_bams):
            for sample_bams in collection.values():
                for sample_id, path in list(sample_bams.items()):
                    sample_bams[sample_id] = remap_path(path, moves)

        remapped_outputs: list[Path] = []
        seen: set[Path] = set()
        for path in self.outputs:
            candidate = remap_path(path, moves)
            if candidate.exists() and candidate not in seen:
                remapped_outputs.append(candidate)
                seen.add(candidate)
        self.outputs = remapped_outputs

    def _copy_provenance(self) -> None:
        provenance_dir = self.ready_dir / "Intermediate files" / "Provenance"
        provenance_dir.mkdir(parents=True, exist_ok=True)
        candidates: list[tuple[Path, Path]] = [
            (self.project_dir / "project_config.json", provenance_dir / "Project configuration.json"),
            (self.project_dir / "config.sha256", provenance_dir / "config.sha256"),
            (self.project_dir / "configuration_only.sha256", provenance_dir / "configuration only.sha256"),
            (self.project_dir / "annotation_summary.json", provenance_dir / "Annotation summary.json"),
            (self.project_dir / "configuration_warnings.txt", provenance_dir / "Configuration warnings.txt"),
            (self.project_dir / "logs" / "commands.sh", provenance_dir / "Commands.sh"),
            (self.project_dir / "logs" / "command_plan.json", provenance_dir / "Command plan.json"),
        ]
        append = self.runner._append_log
        append("")
        append("FINAL EXPORT AND ROOT CLEANUP CODE")
        for source, target in candidates:
            if not source.is_file():
                continue
            append(f"CLEANUP CODE\tshutil.copy2({os.fspath(source)!r}, {os.fspath(target)!r})")
            shutil.copy2(source, target)
            self.outputs.append(target)

        append(
            "CLEANUP CODE\tAfter successful manifest/checksum creation, remove only the pipeline-owned "
            f"directories {os.fspath(self.project_dir)!r} and {os.fspath(self.state_dir)!r}, plus the exact "
            f"GUI request file {os.fspath(self.run_root / 'rnaseq_project.json')!r} when present."
        )
        append(
            "CLEANUP CODE\tSeal the complete pipeline log only after the workbook, compact export, "
            "report, run manifest, and first checksum pass have succeeded."
        )
        append("END FINAL EXPORT AND ROOT CLEANUP CODE")

    def _seal_complete_log(self) -> Path:
        complete_log = self.ready_dir / "Intermediate files" / "Complete pipeline log.txt"
        shutil.copy2(self.runner.pipeline_log, complete_log)
        if complete_log not in self.outputs:
            self.outputs.append(complete_log)
        return complete_log

    def _publish_minimal_result_root(self) -> None:
        """Publish only four user-facing items after a verified successful run.

        The pipeline may use ``analysis_ready`` while commands are running.  Only
        after all final workbooks, QC, provenance and BAM/BAI checks succeed do we
        flatten the completed export into the selected Results folder.
        """
        staging = self.ready_dir
        if staging.resolve() == self.run_root.resolve():
            return
        workbook = staging / "Counts & Annotation.xlsx"
        qc_html = staging / "QC Analysis.html"
        alignments = staging / "Alignments"
        staged_intermediate = staging / "Intermediate files"
        required = [workbook, qc_html, staged_intermediate]
        if not alignments.is_dir() or not any(alignments.rglob("*.bam")):
            raise RuntimeError("Final publication was blocked because verified BAM files are missing.")
        if any(not path.exists() for path in required):
            missing = ", ".join(str(path.name) for path in required if not path.exists())
            raise RuntimeError(f"Final publication was blocked because required export items are missing: {missing}")

        final_bam = self.run_root / "BAM-BAI-IGV"
        final_intermediate = self.run_root / "intermediate"
        final_bam.mkdir(parents=True, exist_ok=True)

        def merge_tree(source: Path, destination: Path) -> None:
            if not source.exists():
                return
            destination.mkdir(parents=True, exist_ok=True)
            for child in sorted(source.iterdir(), key=lambda item: item.name.casefold()):
                target = destination / child.name
                if child.is_dir():
                    merge_tree(child, target)
                    try:
                        child.rmdir()
                    except OSError:
                        pass
                else:
                    if target.exists():
                        if target.is_dir():
                            shutil.rmtree(target)
                        else:
                            target.unlink()
                    shutil.move(os.fspath(child), os.fspath(target))
            try:
                source.rmdir()
            except OSError:
                pass

        if final_intermediate.exists():
            merge_tree(staged_intermediate, final_intermediate)
        else:
            shutil.move(os.fspath(staged_intermediate), os.fspath(final_intermediate))

        # Normalize the internal handoff layout without exposing extra root folders.
        browser = final_intermediate / "Browser files"
        if browser.is_dir():
            merge_tree(browser / "Reference", final_intermediate / "Reference")
            merge_tree(browser / "Coverage tracks", final_intermediate / "Coverage tracks")
            old_igv = browser / "IGV"
            if old_igv.exists():
                shutil.rmtree(old_igv, ignore_errors=True)
            try:
                browser.rmdir()
            except OSError:
                pass
        qc_internal = final_intermediate / "QC"
        merge_tree(final_intermediate / "Detailed QC", qc_internal)
        merge_tree(final_intermediate / "QC reports", qc_internal / "MultiQC")
        merge_tree(final_intermediate / "QC summaries", qc_internal / "Summaries")

        # Move every BAM/BAI into one level. Existing filenames normally encode
        # short/long and primary/audit roles; collision fallback adds path context.
        used_names: set[str] = {item.name.casefold() for item in final_bam.iterdir() if item.is_file()}
        for bam in sorted(alignments.rglob("*.bam")):
            name = bam.name
            if name.casefold() in used_names:
                context = ".".join(bam.relative_to(alignments).parts[:-1])
                name = f"{bam.stem}.{context}.bam" if context else bam.name
            target = final_bam / name
            index = 2
            while target.name.casefold() in used_names or target.exists():
                target = final_bam / f"{Path(name).stem}.{index}.bam"
                index += 1
            used_names.add(target.name.casefold())
            bai = Path(str(bam) + ".bai")
            shutil.move(os.fspath(bam), os.fspath(target))
            if bai.is_file():
                shutil.move(os.fspath(bai), os.fspath(Path(str(target) + ".bai")))
        shutil.rmtree(alignments, ignore_errors=True)

        # Publish the two main files directly in the user-selected result folder.
        for source, target in (
            (workbook, self.run_root / "Counts & Annotation.xlsx"),
            (qc_html, self.run_root / "QC Analysis.html"),
        ):
            if target.exists():
                target.unlink()
            shutil.move(os.fspath(source), os.fspath(target))

        processing_report = staging / "Analysis Ready Report.html"
        if processing_report.is_file():
            target = final_intermediate / "RNA-seq Processing Report.html"
            if target.exists():
                target.unlink()
            shutil.move(os.fspath(processing_report), os.fspath(target))

        # Preserve any unexpected pipeline-owned leftovers rather than deleting them.
        leftovers = [item for item in staging.iterdir() if item.exists()]
        if leftovers:
            retained = final_intermediate / "Other retained outputs"
            retained.mkdir(parents=True, exist_ok=True)
            for item in leftovers:
                target = retained / item.name
                if target.exists():
                    if target.is_dir():
                        shutil.rmtree(target)
                    else:
                        target.unlink()
                shutil.move(os.fspath(item), os.fspath(target))
        try:
            staging.rmdir()
        except OSError:
            pass

        # Rebuild a simple IGV session for the published flat BAM folder.
        reference = final_intermediate / "Reference" / "reference.fasta"
        annotation = final_intermediate / "Reference" / "annotation.normalized.gff3"
        resources: list[str] = []
        for bam in sorted(final_bam.glob("*.bam")):
            resources.append(f'    <Resource path="{bam.name}" name="{bam.stem}"/>')
        coverage_root = final_intermediate / "Coverage tracks"
        if coverage_root.is_dir():
            for path in sorted(coverage_root.rglob("*.bw")):
                relative = os.path.relpath(path, final_bam).replace(os.sep, "/")
                resources.append(f'    <Resource path="{relative}"/>')
        if annotation.is_file():
            relative = os.path.relpath(annotation, final_bam).replace(os.sep, "/")
            resources.append(f'    <Resource path="{relative}" name="Normalized annotation"/>')
        genome = os.path.relpath(reference, final_bam).replace(os.sep, "/") if reference.is_file() else ""
        session = final_bam / "IGV session.xml"
        session.write_text(
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?>\n"
            f'<Session genome="{genome}" locus="All" version="8">\n'
            "  <Resources>\n" + "\n".join(resources) + "\n  </Resources>\n</Session>\n",
            encoding="utf-8",
        )
        (final_bam / "README.txt").write_text(
            "Open IGV session.xml in IGV. BAM/BAI files are in this folder; reference and coverage files are retained under ../intermediate/.\n",
            encoding="utf-8",
        )
        self.ready_dir = self.run_root

    def _final_report(self, status: str) -> None:
        def advance(step: int, message: str, percent: int) -> None:
            self.runner.check_stop()
            self.runner._append_log(f"FINALIZATION {step}/8: {message}")
            self.events.emit(
                "stage_progress",
                message,
                stage="export",
                status="running",
                percent=percent,
                step_current=self.stage_numbers["export"],
                step_total=self.total_steps,
            )

        advance(1, "Recording executable and bounded third-party package provenance", 97)
        self._write_versions()
        advance(2, "Creating the count-and-annotation workbook and combined QC dashboard", 97)
        workbook = create_processing_workbook(self.ready_dir, self.config, self.warnings)
        self.outputs.append(workbook)
        qc_report = generate_qc_report(
            self.ready_dir / "qc",
            self.ready_dir / "QC Analysis.html",
            project_name=str(self.config.get("project", {}).get("name", "RNA-seq project")),
            analysis_type=self.analysis_type,
            alignment_summary=self.alignment_summary,
            strand_summary=self.strand_summary,
            warnings=self.warnings,
        )
        self.outputs.append(qc_report)
        if status == "complete":
            advance(3, "Verifying BAM/BAI and compacting regenerable outputs", 98)
            self._compact_outputs(workbook)
        else:
            advance(3, "Retaining dry-run planning outputs", 98)
        advance(4, "Applying readable export names and writing the IGV session", 98)
        self._apply_export_filename_policy()
        self._write_igv_session()
        advance(5, "Copying configuration and command provenance", 98)
        self._copy_provenance()
        advance(6, "Creating the analysis-ready HTML report", 99)
        report = generate_html_report(
            self.ready_dir,
            self.config,
            warnings=self.warnings,
            annotation_summary=self.annotation_summary,
            alignment_summary=self.alignment_summary,
            strand_summary=self.strand_summary,
            status=status,
        )
        manifest = (
            self.ready_dir / "Intermediate files" / "Run manifest.json"
            if status == "complete"
            else self.ready_dir / "Run manifest.json"
        )
        checksum = self.ready_dir / "Intermediate files" / "Checksums.sha256"
        complete_log = self.ready_dir / "Intermediate files" / "Complete pipeline log.txt"
        self.outputs.extend([report, manifest, checksum, complete_log])
        advance(7, "Writing the run manifest", 99)
        write_run_manifest(
            manifest,
            self.config,
            status=status,
            warnings=self.warnings,
            outputs=self.outputs,
        )
        advance(8, "Sealing the complete log and checksums", 99)
        self.runner._append_log(
            "FINAL CHECKSUM PASS 1: hashing the finalized export, including the sealed complete log"
        )
        self._seal_complete_log()
        write_checksums(self.ready_dir)
        self.runner._append_log("FINAL CHECKSUM PASS 1 COMPLETE")
        self.runner._append_log(
            "FINAL EXPORT COMPLETE: Counts & Annotation workbook, combined QC HTML, BAM/BAI, compact folders, report, manifest, "
            "provenance, and checksums were written successfully"
        )
        self.runner._append_log(
            "Refreshing only the Complete pipeline log.txt checksum entry so the final completion lines are fingerprinted without rehashing unchanged BAM files."
        )
        self._seal_complete_log()
        refresh_checksum_entries(self.ready_dir, [complete_log])

    def finalize_runtime_state(self, config_path: Path) -> list[str]:
        """Publish the verified minimal result root and remove run-only machinery."""
        if self.dry_run:
            return []
        required = [
            self.ready_dir / "Counts & Annotation.xlsx",
            self.ready_dir / "QC Analysis.html",
            self.ready_dir / "Intermediate files" / "Complete pipeline log.txt",
            self.ready_dir / "Intermediate files" / "Checksums.sha256",
            self.ready_dir / "Intermediate files" / "Run manifest.json",
        ]
        if any(not path.is_file() for path in required):
            return ["Runtime cleanup skipped because the verified compact export files are incomplete."]

        warnings: list[str] = []
        try:
            self._publish_minimal_result_root()
        except (OSError, RuntimeError) as exc:
            return [f"Final result publication could not be completed: {exc}"]

        targets: list[Path] = [self.project_dir, self.state_dir]
        resolved_config = config_path.resolve()
        if resolved_config.parent == self.run_root and resolved_config.name == "rnaseq_project.json":
            targets.append(resolved_config)
        for target in targets:
            try:
                if target.is_dir():
                    shutil.rmtree(target)
                elif target.is_file():
                    target.unlink()
            except OSError as exc:
                warnings.append(f"Could not remove pipeline-owned runtime path {target}: {exc}")
        return warnings

    def _emit_python_code_trace(self) -> None:
        """Record compact reproducibility fingerprints without dumping source code."""
        backend_root = Path(__file__).resolve().parents[1]
        app_root = backend_root.parent
        source_files: list[tuple[Path, Path]] = [
            (path.relative_to(app_root), path)
            for path in backend_root.rglob("*.py")
            if "__pycache__" not in path.parts
        ]
        for path in (
            app_root / "rnaseq_gui.ps1",
            app_root / "environment" / "run_pipeline_windows.ps1",
            app_root / "environment" / "run_in_environment.sh",
            app_root / "environment" / "environment-core.yml",
            app_root / "method_catalog.json",
        ):
            if path.is_file():
                source_files.append((path.relative_to(app_root), path))
        source_files.sort(key=lambda item: item[0].as_posix())

        append = self.runner._append_log
        append("")
        append("=" * 96)
        append("APPLICATION PROVENANCE SUMMARY")
        append("=" * 96)
        append("Normal runs record compact SHA-256 fingerprints instead of copying packaged source code into the live log.")
        append("The complete active configuration is saved separately by the pipeline for reproducibility.")
        append("Third-party tools are recorded separately by resolved executable path and version.")
        append(f"Configuration SHA256: {self.config_hash}")
        append("")
        append("EXECUTION COMMAND")
        entrypoint = backend_root / "scripts" / "run_pipeline.py"
        command = [sys.executable, str(entrypoint), "--config", "<active project JSON>"]
        if self.dry_run:
            command.append("--dry-run")
        append(subprocess.list2cmdline(command))

        append("")
        append("PACKAGED SOURCE FINGERPRINTS")
        for label, source in source_files:
            self.runner.check_stop()
            digest = hashlib.sha256(source.read_bytes()).hexdigest()
            append(f"{label.as_posix()}\tSHA256={digest}\tBYTES={source.stat().st_size}")
        append("END APPLICATION PROVENANCE SUMMARY")
        append("=" * 96)

    def run(self) -> Path:
        self.events.emit(
            "run_started",
            "Initializing project and recording inputs",
            stage="initialize",
            status="running",
            percent=0,
            step_current=self.stage_numbers["initialize"],
            step_total=self.total_steps,
            details={"dry_run": self.dry_run, "config_hash": self.config_hash},
        )
        try:
            self.runner._append_log("INITIALIZATION 1/4: recording compact application provenance and active configuration")
            self._emit_python_code_trace()
            self.runner._append_log("INITIALIZATION 2/4: saving the project configuration")
            self._snapshot_configuration()
            self.runner._append_log("INITIALIZATION 3/4: recording input file identities")
            self._write_input_manifest()
            self.runner._append_log("INITIALIZATION 4/4: writing biological sample metadata")
            self._write_sample_metadata()
            self.events.emit(
                "stage_finished",
                "Project configuration and inputs recorded",
                stage="initialize",
                status="finished",
                percent=4,
                step_current=self.stage_numbers["initialize"],
                step_total=self.total_steps,
            )

            self._emit("reference", "Normalizing and indexing the bacterial reference", 7)
            self._prepare_reference()

            if self.analysis_type in {"short", "both"}:
                self._emit("short_qc", "Assessing and cleaning short reads", 18)
                short_reads = self._prepare_short_reads()
                self._emit("short_alignment", "Aligning short reads", 35)
                self._align_short(short_reads)

            if self.analysis_type in {"long", "both"}:
                self._emit("long_qc", "Preparing and assessing long reads", 46)
                long_reads = self._prepare_long_reads()
                self._emit("long_alignment", "Aligning long reads", 58)
                self._align_long(long_reads)

            self._emit("bam_qc", "Validating BAM and BAI exports", 67)
            self._bam_qc()

            self._emit("counts", "Auditing strand orientation and exporting raw counts", 75)
            self._run_primary_counts()

            self._emit("coverage", "Creating analysis-ready coverage tracks", 84)
            self._make_coverage()

            self._emit("multiqc", "Combining quality reports", 91)
            self._run_multiqc()

            self._emit("export", "Writing checksums, provenance, and IGV session", 97)
            self._final_report("dry_run" if self.dry_run else "complete")
            self.events.emit(
                "run_finished",
                "RNA-seq processing completed",
                stage="complete",
                status="complete",
                percent=100,
                step_current=self.total_steps,
                step_total=self.total_steps,
                details={"analysis_ready": os.fspath(self.ready_dir)},
            )
            return self.ready_dir
        except PipelineStopped as exc:
            self.events.emit("run_stopped", str(exc), stage="stopped", status="stopped")
            write_run_manifest(
                self.ready_dir / "Run manifest.json",
                self.config,
                status="stopped",
                warnings=self.warnings,
                outputs=self.outputs,
            )
            raise
        except Exception as exc:
            self.events.emit(
                "run_failed",
                str(exc),
                stage="failed",
                status="error",
            )
            write_run_manifest(
                self.ready_dir / "Run manifest.json",
                self.config,
                status="error",
                warnings=[*self.warnings, str(exc)],
                outputs=self.outputs,
            )
            raise
