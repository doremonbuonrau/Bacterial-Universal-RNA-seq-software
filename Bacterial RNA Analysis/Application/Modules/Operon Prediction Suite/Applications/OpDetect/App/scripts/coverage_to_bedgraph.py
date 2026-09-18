#!/usr/bin/env python3
"""Convert OpDetect per-base coverage files into compact bedGraph tracks.

Input files are expected to be produced by ``bedtools genomecov -d`` and contain
three tab-separated columns: contig, 1-based position, and depth. Consecutive
bases with the same value are merged into standard 0-based, half-open bedGraph
intervals. Zero-depth intervals are omitted to keep tracks compact.
"""

from __future__ import annotations

import argparse
from contextlib import ExitStack
from itertools import zip_longest
from pathlib import Path
import re
from typing import Iterable, Iterator, TextIO


def safe_name(value: str) -> str:
    value = value.strip().replace("_", "-")
    value = re.sub(r"[^A-Za-z0-9.-]+", "-", value)
    value = re.sub(r"-+", "-", value).strip("-.")
    return value or "sample"


def parse_line(line: str, path: Path, line_number: int) -> tuple[str, int, float]:
    fields = line.rstrip("\n\r").split("\t")
    if len(fields) < 3:
        raise SystemExit(f"Invalid coverage row in {path} at line {line_number}: expected 3 columns")
    try:
        return fields[0], int(fields[1]), float(fields[2])
    except ValueError as exc:
        raise SystemExit(f"Invalid coverage value in {path} at line {line_number}: {line.rstrip()}") from exc


def format_value(value: float) -> str:
    if value.is_integer():
        return str(int(value))
    return f"{value:.6f}".rstrip("0").rstrip(".")


def write_segments(records: Iterable[tuple[str, int, float]], output: Path, track_name: str) -> int:
    output.parent.mkdir(parents=True, exist_ok=True)
    segments = 0
    current_chrom: str | None = None
    current_start = 0
    current_end = 0
    current_value = 0.0

    def flush(handle: TextIO) -> None:
        nonlocal segments
        if current_chrom is not None and current_value != 0:
            handle.write(
                f"{current_chrom}\t{current_start}\t{current_end}\t{format_value(current_value)}\n"
            )
            segments += 1

    with output.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(
            f'track type=bedGraph name="{track_name}" description="OpDetect RNA-seq coverage" visibility=full\n'
        )
        for chrom, position_1, value in records:
            start0 = position_1 - 1
            end0 = position_1
            if position_1 < 1:
                raise SystemExit(f"Coverage positions must be 1-based and positive; found {position_1}")
            if (
                current_chrom == chrom
                and current_end == start0
                and current_value == value
            ):
                current_end = end0
                continue
            flush(handle)
            current_chrom = chrom
            current_start = start0
            current_end = end0
            current_value = value
        flush(handle)
    return segments


def read_coverage(path: Path) -> Iterator[tuple[str, int, float]]:
    with path.open("r", encoding="utf-8", errors="strict") as handle:
        for line_number, line in enumerate(handle, start=1):
            if not line.strip():
                continue
            yield parse_line(line, path, line_number)


def mean_records(paths: list[Path]) -> Iterator[tuple[str, int, float]]:
    with ExitStack() as stack:
        handles = [stack.enter_context(path.open("r", encoding="utf-8")) for path in paths]
        for row_number, rows in enumerate(zip_longest(*handles), start=1):
            if any(row is None for row in rows):
                raise SystemExit("Coverage files have different numbers of rows; mean bedGraph cannot be created")
            parsed = [parse_line(row, path, row_number) for row, path in zip(rows, paths)]
            chrom, position, _ = parsed[0]
            if any(item[0] != chrom or item[1] != position for item in parsed[1:]):
                raise SystemExit(
                    f"Coverage files are not coordinate-aligned at row {row_number}; mean bedGraph cannot be created"
                )
            mean_value = round(sum(item[2] for item in parsed) / len(parsed), 6)
            yield chrom, position, mean_value


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--coverage-dir", required=True, type=Path)
    parser.add_argument("--coverage-prefix", default="base_cov")
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--mean-output", required=True, type=Path)
    parser.add_argument("--index-output", required=True, type=Path)
    args = parser.parse_args()

    prefix = args.coverage_prefix + "_"
    files = sorted(
        path for path in args.coverage_dir.iterdir()
        if path.is_file() and path.name.startswith(prefix)
    )
    if not files:
        raise SystemExit(
            f"No coverage files beginning with {prefix!r} were found in {args.coverage_dir}"
        )

    args.output_dir.mkdir(parents=True, exist_ok=True)
    index_rows: list[tuple[str, str, int]] = []
    for path in files:
        sample = path.name[len(prefix):]
        output_name = f"{safe_name(sample)}.coverage.bedgraph"
        output = args.output_dir / output_name
        segments = write_segments(read_coverage(path), output, f"{sample} coverage")
        index_rows.append((sample, output_name, segments))
        print(f"Wrote {segments} non-zero coverage segments for {sample} to {output}")

    mean_segments = write_segments(
        mean_records(files), args.mean_output, "Mean replicate coverage"
    )
    print(
        f"Wrote {mean_segments} mean replicate coverage segments across {len(files)} replicate(s) "
        f"to {args.mean_output}"
    )

    args.index_output.parent.mkdir(parents=True, exist_ok=True)
    with args.index_output.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write("replicate\tbedgraph-file\tnon-zero-segments\n")
        for sample, filename, segments in index_rows:
            handle.write(f"{sample}\tcoverage/{filename}\t{segments}\n")
        handle.write(
            f"MEAN\tcoverage/{args.mean_output.name}\t{mean_segments}\n"
        )
    print(f"Wrote coverage track index to {args.index_output}")


if __name__ == "__main__":
    main()
