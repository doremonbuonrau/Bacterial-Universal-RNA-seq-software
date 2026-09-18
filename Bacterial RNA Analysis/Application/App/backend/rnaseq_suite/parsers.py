from __future__ import annotations

import csv
import hashlib
from pathlib import Path
from typing import Mapping


def parse_featurecounts_assigned(summary_path: Path) -> int:
    if not summary_path.is_file():
        return 0
    with summary_path.open("r", encoding="utf-8", errors="replace") as handle:
        reader = csv.reader(handle, delimiter="\t")
        for row in reader:
            if row and row[0] == "Assigned" and len(row) >= 2:
                try:
                    return int(float(row[1]))
                except ValueError:
                    return 0
    return 0


def parse_featurecounts_counts(path: Path) -> dict[str, float]:
    counts: dict[str, float] = {}
    if not path.is_file():
        return counts
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            if not raw.strip() or raw.startswith("#"):
                continue
            fields = raw.rstrip("\r\n").split("\t")
            if fields[0] == "Geneid" or len(fields) < 2:
                continue
            try:
                counts[fields[0]] = float(fields[-1])
            except ValueError:
                continue
    return counts


def parse_htseq_counts(path: Path) -> dict[str, float]:
    counts: dict[str, float] = {}
    if not path.is_file():
        return counts
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            fields = raw.rstrip("\r\n").split("\t")
            if len(fields) != 2 or fields[0].startswith("__"):
                continue
            try:
                counts[fields[0]] = float(fields[1])
            except ValueError:
                continue
    return counts


def parse_fadu_counts(path: Path) -> dict[str, float]:
    counts: dict[str, float] = {}
    if not path.is_file():
        return counts
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        for row in reader:
            gene_id = row.get("featureID") or row.get("gene_id") or row.get("Name")
            value = row.get("counts") or row.get("num_alignments")
            if not gene_id or value is None:
                continue
            try:
                counts[gene_id] = float(value)
            except ValueError:
                continue
    return counts


def write_count_matrix(path: Path, per_sample: Mapping[str, Mapping[str, float]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    samples = sorted(per_sample)
    genes = sorted({gene for counts in per_sample.values() for gene in counts})
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write("gene_id\t" + "\t".join(samples) + "\n")
        for gene in genes:
            values = []
            for sample in samples:
                value = per_sample[sample].get(gene, 0)
                if float(value).is_integer():
                    values.append(str(int(value)))
                else:
                    values.append(f"{value:.8g}")
            handle.write(gene + "\t" + "\t".join(values) + "\n")


def sha256_file(path: Path, chunk_size: int = 1024 * 1024) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(chunk_size), b""):
            digest.update(chunk)
    return digest.hexdigest()

