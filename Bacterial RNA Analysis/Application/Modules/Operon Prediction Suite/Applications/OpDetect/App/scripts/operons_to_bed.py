#!/usr/bin/env python3
"""Convert the predicted-operon table into an IGV-compatible BED6 track."""

from __future__ import annotations

import argparse
from pathlib import Path
import math
import pandas as pd


def read_annotation(path: Path) -> dict[str, tuple[str, int, int, str]]:
    columns = ["chrom", "source", "feature", "start", "end", "score", "strand", "phase", "name"]
    frame = pd.read_csv(path, sep="\t", names=columns, dtype={"chrom": str, "name": str})
    result: dict[str, tuple[str, int, int, str]] = {}
    for row in frame.itertuples(index=False):
        result[str(row.name)] = (str(row.chrom), int(row.start), int(row.end), str(row.strand))
    return result


def read_contig_lengths(path: Path) -> dict[str, int]:
    lengths: dict[str, int] = {}
    with path.open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            if not line.strip():
                continue
            fields = line.rstrip("\n\r").split("\t")
            if len(fields) < 3:
                raise SystemExit(f"Invalid coverage row at line {line_number} in {path}")
            chrom = fields[0]
            position = int(fields[1])
            lengths[chrom] = max(lengths.get(chrom, 0), position)
    return lengths


def bed_score(probability: float) -> int:
    if math.isnan(probability):
        return 0
    return max(0, min(1000, int(round(probability * 1000))))


def write_row(handle, chrom: str, start: int, end: int, name: str, score: int, strand: str) -> None:
    if end <= start:
        return
    handle.write(f"{chrom}\t{start}\t{end}\t{name}\t{score}\t{strand}\n")


def split_wrapped_intervals(
    genes: list[str], annotation: dict[str, tuple[str, int, int, str]]
) -> list[tuple[int, int]]:
    intervals = sorted((annotation[gene][1], annotation[gene][2]) for gene in genes)
    if len(intervals) < 2:
        return intervals
    gaps: list[tuple[int, int]] = []
    for index in range(len(intervals) - 1):
        gap = intervals[index + 1][0] - intervals[index][1]
        gaps.append((gap, index))
    _, split_index = max(gaps, key=lambda item: item[0])
    first = intervals[: split_index + 1]
    second = intervals[split_index + 1 :]
    return [
        (min(start for start, _ in first), max(end for _, end in first)),
        (min(start for start, _ in second), max(end for _, end in second)),
    ]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--operons", required=True, type=Path)
    parser.add_argument("--annotation-bed", required=True, type=Path)
    parser.add_argument("--coverage-file", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    operons = pd.read_csv(args.operons, sep="\t")
    annotation = read_annotation(args.annotation_bed)
    contig_lengths = read_contig_lengths(args.coverage_file)
    required = {"operon_id", "chromosome", "strand", "wraps_origin", "genes", "mean_edge_probability", "gene_count"}
    missing = required.difference(operons.columns)
    if missing:
        raise SystemExit(f"Operon table is missing columns: {sorted(missing)}")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    record_count = 0
    wrapped_count = 0
    with args.output.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(
            'track name="OpDetect predicted operons" description="Replicate-consensus OpDetect operons" useScore=1 visibility=pack\n'
        )
        for row in operons.itertuples(index=False):
            genes = [gene for gene in str(row.genes).split(",") if gene]
            unknown = [gene for gene in genes if gene not in annotation]
            if unknown:
                raise SystemExit(f"Operon {row.operon_id} contains genes missing from annotation: {unknown[:5]}")
            chrom = str(row.chromosome)
            strand = str(row.strand)
            probability = float(row.mean_edge_probability)
            score = bed_score(probability)
            base_name = f"{str(row.operon_id).replace('_', '-')}|genes={int(row.gene_count)}|p={probability:.3f}"
            wraps = str(row.wraps_origin).strip().lower() in {"true", "1", "yes"}

            intervals = [(annotation[gene][1], annotation[gene][2]) for gene in genes]
            if not intervals:
                continue
            if wraps:
                wrapped_count += 1
                parts = split_wrapped_intervals(genes, annotation)
                if chrom not in contig_lengths:
                    raise SystemExit(f"No contig length was found for wrapped operon on {chrom}")
                for part_number, (start, end) in enumerate(parts, start=1):
                    write_row(handle, chrom, start, end, f"{base_name}|part={part_number}", score, strand)
                    record_count += 1
            else:
                start = min(interval[0] for interval in intervals)
                end = max(interval[1] for interval in intervals)
                write_row(handle, chrom, start, end, base_name, score, strand)
                record_count += 1

    print(
        f"Wrote {record_count} BED records for {len(operons)} predicted operon(s) "
        f"({wrapped_count} crossing a circular origin) to {args.output}"
    )


if __name__ == "__main__":
    main()
