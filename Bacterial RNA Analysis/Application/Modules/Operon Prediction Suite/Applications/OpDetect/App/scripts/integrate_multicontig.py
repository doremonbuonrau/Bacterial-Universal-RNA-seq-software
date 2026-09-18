#!/usr/bin/env python3
"""Contig- and replicate-aware OpDetect coverage integration.

Each biological replicate remains a separate model channel.  Unlike the
upstream script, this implementation does not silently copy the first replicate
to fill all six channels.  Replicate padding and order-consensus are handled
later by ``prepare_replicate_input.py`` and ``predict_opdetect.py``.
"""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import pandas as pd

ANNOTATION_COLUMNS = [
    "Chromosome", "ena", "gene", "start", "end", ".1", "strand", ".2", "name"
]
COVERAGE_COLUMNS = ["Chromosome", "base_number", "coverage"]
MAX_REPLICATES = 6


def gene_coverage(
    coverage: pd.DataFrame, start: int, end: int, reverse: bool = False
) -> np.ndarray:
    values = coverage["coverage"].iloc[start:end].to_numpy(dtype=np.float32).flatten()
    return values[::-1] if reverse else values


def pair_consecutive(
    df: pd.DataFrame, *, reverse: bool = False, circular: bool = True
) -> pd.DataFrame:
    """Pair adjacent genes on one strand.

    Circular replicons retain the upstream last-to-first pair. Linear replicons
    stop at the final gene and therefore produce ``n - 1`` pairs on a strand.
    """
    if len(df) < 2:
        return pd.DataFrame()

    ordered = df.sort_values("start", ascending=not reverse).reset_index(drop=True)
    if circular:
        second = ordered.shift(-1)
        second.iloc[-1] = ordered.iloc[0]
        first = ordered
    else:
        first = ordered.iloc[:-1].reset_index(drop=True)
        second = ordered.iloc[1:].reset_index(drop=True)

    return pd.concat([first.add_suffix("_1"), second.add_suffix("_2")], axis=1)


def add_intergenic(
    row: pd.Series,
    coverage: pd.DataFrame,
    genome_length: int,
    *,
    reverse: bool = False,
    circular: bool = True,
) -> pd.Series:
    wrap = False
    if reverse:
        start = int(row.end_2)
        end = int(row.start_1)
        if circular and int(row.start_1) < int(row.start_2):
            wrap = True
    else:
        start = int(row.end_1)
        end = int(row.start_2)
        if circular and int(row.start_2) < int(row.start_1):
            wrap = True

    length = end - start - 1
    if wrap:
        part_1 = coverage["coverage"].iloc[start + 1 :].to_numpy(dtype=np.float32)
        part_2 = coverage["coverage"].iloc[:end].to_numpy(dtype=np.float32)
        intergenic = np.concatenate([part_1, part_2])
        if reverse:
            intergenic = intergenic[::-1]
    elif length > 0:
        intergenic = gene_coverage(coverage, start + 1, end, reverse=reverse)
    else:
        intergenic = np.zeros(1, dtype=np.float32)

    row["gene_1"] = row.coverage_1
    row["intergenic"] = intergenic
    row["gene_2"] = row.coverage_2
    return row


def features_for_contig(
    annotation: pd.DataFrame,
    coverage: pd.DataFrame,
    contig: str,
    *,
    circular: bool,
) -> pd.DataFrame:
    ann = annotation[annotation["Chromosome"] == contig].copy()
    cov = coverage[coverage["Chromosome"] == contig].copy()
    empty_columns = ["name_1", "name_2", "gene_1", "intergenic", "gene_2"]
    if ann.empty:
        return pd.DataFrame(columns=empty_columns)
    if cov.empty:
        raise ValueError(f"Coverage file contains no rows for annotated contig {contig!r}")

    cov = cov.sort_values("base_number").reset_index(drop=True)
    expected_positions = np.arange(1, len(cov) + 1)
    observed_positions = cov["base_number"].to_numpy()
    if not np.array_equal(observed_positions, expected_positions):
        raise ValueError(
            f"Coverage positions for contig {contig!r} are not complete consecutive values "
            f"1..{len(cov)}"
        )

    genome_length = len(cov)
    frames: list[pd.DataFrame] = []
    for strand, reverse in (("+", False), ("-", True)):
        strand_ann = ann[ann["strand"] == strand].copy().reset_index(drop=True)
        if len(strand_ann) < 2:
            continue
        strand_ann["coverage"] = strand_ann.apply(
            lambda row: gene_coverage(
                cov, int(row.start), int(row.end), reverse=reverse
            ),
            axis=1,
        )
        pairs = pair_consecutive(strand_ann, reverse=reverse, circular=circular)
        if pairs.empty:
            continue
        pairs = pairs.apply(
            lambda row: add_intergenic(
                row,
                cov,
                genome_length,
                reverse=reverse,
                circular=circular,
            ),
            axis=1,
        )
        frames.append(pairs[empty_columns])

    if not frames:
        return pd.DataFrame(columns=empty_columns)
    return pd.concat(frames, ignore_index=True)


def read_samples(samples_tsv: Path) -> list[str]:
    samples = pd.read_csv(samples_tsv, sep="\t", dtype=str).fillna("")
    first_column = samples.columns[0]
    values = [str(value).strip() for value in samples[first_column].tolist() if str(value).strip()]
    if not 1 <= len(values) <= MAX_REPLICATES:
        raise SystemExit(
            f"Provide 1 to {MAX_REPLICATES} biological replicates; found {len(values)}"
        )
    if len(values) != len(set(values)):
        raise SystemExit("Replicate names must be unique")
    return values


def read_topology(topology_file: Path, contigs: list[str]) -> dict[str, bool]:
    topology = pd.read_csv(topology_file, sep="\t", dtype=str).fillna("")
    required = {"contig", "topology"}
    if not required.issubset(topology.columns):
        raise SystemExit("Topology file must contain contig and topology columns")

    mapping: dict[str, bool] = {}
    for row in topology.itertuples(index=False):
        contig = str(getattr(row, "contig")).strip()
        value = str(getattr(row, "topology")).strip().lower()
        if value not in {"circular", "linear"}:
            raise SystemExit(f"Invalid topology for {contig!r}: {value!r}")
        mapping[contig] = value == "circular"

    missing = [contig for contig in contigs if contig not in mapping]
    if missing:
        raise SystemExit(
            "Topology file is missing annotated contig(s): " + ", ".join(missing)
        )
    return mapping


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--organism", required=True)
    parser.add_argument("--data-root", required=True, type=Path)
    parser.add_argument("--annotation-name", default="gene_annotation.bed")
    parser.add_argument("--coverage-prefix", default="base_cov")
    parser.add_argument("--samples-tsv", required=True, type=Path)
    parser.add_argument("--topology-file", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    organism_dir = args.data_root / args.organism
    annotation_path = organism_dir / args.annotation_name
    if not annotation_path.is_file():
        raise SystemExit(f"Annotation file not found: {annotation_path}")

    annotation = pd.read_csv(annotation_path, names=ANNOTATION_COLUMNS, sep="\t")
    annotation["Chromosome"] = annotation["Chromosome"].astype(str)
    annotation["start"] = annotation["start"].astype(int)
    annotation["end"] = annotation["end"].astype(int)
    contigs = list(dict.fromkeys(annotation["Chromosome"].tolist()))
    topology = read_topology(args.topology_file, contigs)
    sample_names = read_samples(args.samples_tsv)

    sequences: list[pd.DataFrame] = []
    for replicate_index, sample_name in enumerate(sample_names):
        coverage_path = organism_dir / f"{args.coverage_prefix}_{sample_name}"
        if not coverage_path.is_file():
            raise SystemExit(f"Coverage file not found for replicate {sample_name}: {coverage_path}")

        coverage = pd.read_csv(coverage_path, names=COVERAGE_COLUMNS, sep="\t")
        coverage["Chromosome"] = coverage["Chromosome"].astype(str)
        coverage["base_number"] = coverage["base_number"].astype(int)
        coverage["coverage"] = coverage["coverage"].astype(np.float32)

        missing = [contig for contig in contigs if contig not in set(coverage["Chromosome"])]
        if missing:
            raise SystemExit(
                f"Coverage file {coverage_path.name} is missing annotated contig(s): "
                + ", ".join(missing)
            )

        replicate_frames = [
            features_for_contig(
                annotation,
                coverage,
                contig,
                circular=topology[contig],
            )
            for contig in contigs
        ]
        replicate_features = pd.concat(replicate_frames, ignore_index=True)
        if replicate_features.empty:
            raise SystemExit(f"No gene-pair features were generated from {coverage_path}")
        replicate_features.columns = [
            "name_1",
            "name_2",
            f"gene_1_{replicate_index}",
            f"intergenic_{replicate_index}",
            f"gene_2_{replicate_index}",
        ]
        sequences.append(replicate_features)
        print(
            f"Integrated replicate {sample_name}: {len(replicate_features)} gene pairs "
            f"across {len(contigs)} contig(s)"
        )

    features = sequences[0]
    for replicate_index in range(1, len(sequences)):
        features = pd.merge(
            features,
            sequences[replicate_index],
            on=["name_1", "name_2"],
            how="inner",
            validate="one_to_one",
        )
    features.dropna(inplace=True)
    features["label"] = -1
    features.reset_index(drop=True, inplace=True)
    features.attrs["replicate_names"] = sample_names
    features.attrs["replicate_count"] = len(sample_names)
    features.attrs["topology"] = {
        contig: ("circular" if is_circular else "linear")
        for contig, is_circular in topology.items()
    }

    args.output.parent.mkdir(parents=True, exist_ok=True)
    features.to_pickle(args.output)
    print(
        f"Saved {len(features)} integrated gene pairs from {len(sample_names)} real "
        f"biological replicate(s) to {args.output}"
    )


if __name__ == "__main__":
    main()
