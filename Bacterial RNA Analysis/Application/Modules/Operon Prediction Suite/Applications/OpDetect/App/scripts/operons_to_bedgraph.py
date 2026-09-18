#!/usr/bin/env python3
"""Create a signed IGV bedGraph track from predicted OpDetect operons.

The fourth bedGraph column is the mean OpDetect edge probability for forward
operons and its negative value for reverse operons. It is a model score, not a
statistical p-value. Magnitude ranges from 0 to 1.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import pandas as pd


def read_annotation(path: Path) -> dict[str, tuple[str, int, int, str]]:
    columns = ["chrom", "source", "feature", "start", "end", "score", "strand", "phase", "name"]
    frame = pd.read_csv(path, sep="\t", names=columns, dtype={"chrom": str, "name": str})
    return {
        str(row.name): (str(row.chrom), int(row.start), int(row.end), str(row.strand))
        for row in frame.itertuples(index=False)
    }


def split_wrapped_intervals(genes: list[str], annotation: dict[str, tuple[str, int, int, str]]) -> list[tuple[int, int]]:
    intervals = sorted((annotation[gene][1], annotation[gene][2]) for gene in genes)
    if len(intervals) < 2:
        return intervals
    gaps = [(intervals[index + 1][0] - intervals[index][1], index) for index in range(len(intervals) - 1)]
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
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    operons = pd.read_csv(args.operons, sep="\t")
    required = {"chromosome", "strand", "wraps_origin", "genes", "mean_edge_probability"}
    missing = required.difference(operons.columns)
    if missing:
        raise SystemExit(f"Operon table is missing columns: {sorted(missing)}")
    annotation = read_annotation(args.annotation_bed)

    records: list[tuple[str, int, int, float]] = []
    for row in operons.itertuples(index=False):
        genes = [gene for gene in str(row.genes).split(",") if gene]
        unknown = [gene for gene in genes if gene not in annotation]
        if unknown:
            raise SystemExit(f"Predicted operon contains genes absent from the annotation: {unknown[:5]}")
        probability = max(0.0, min(1.0, float(row.mean_edge_probability)))
        value = probability if str(row.strand) == "+" else -probability
        wraps = str(row.wraps_origin).strip().lower() in {"true", "1", "yes"}
        if wraps:
            intervals = split_wrapped_intervals(genes, annotation)
        else:
            gene_intervals = [(annotation[gene][1], annotation[gene][2]) for gene in genes]
            intervals = [(min(start for start, _ in gene_intervals), max(end for _, end in gene_intervals))]
        chrom = str(row.chromosome)
        for start, end in intervals:
            if end > start:
                records.append((chrom, start, end, value))

    records.sort(key=lambda item: (item[0], item[1], item[2], -abs(item[3])))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(
            'track type=bedGraph name="OpDetect predicted operons" '
            'description="Signed mean OpDetect probability; positive=forward, negative=reverse; not a p-value" '
            'visibility=full autoScale=off viewLimits=-1:1 color=0,128,0 altColor=180,0,0\n'
        )
        for chrom, start, end, value in records:
            handle.write(f"{chrom}\t{start}\t{end}\t{value:.6f}\n")

    print(
        f"Wrote {len(records)} predicted-operon bedGraph interval(s) for {len(operons)} operon(s) to {args.output}. "
        "The value is signed mean model probability, not a statistical p-value."
    )


if __name__ == "__main__":
    main()
