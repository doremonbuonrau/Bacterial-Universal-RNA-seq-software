#!/usr/bin/env python3
"""Group robust adjacent OpDetect gene-pair edges into candidate operons."""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import pandas as pd


def read_topology(path: Path | None) -> dict[str, str]:
    if path is None or not path.is_file():
        return {}
    table = pd.read_csv(path, sep="\t", dtype=str).fillna("")
    if not {"contig", "topology"}.issubset(table.columns):
        raise SystemExit("Topology file must contain contig and topology columns")
    return {
        str(row.contig): str(row.topology).lower()
        for row in table.itertuples(index=False)
    }


class UnionFind:
    def __init__(self, size: int) -> None:
        self.parent = list(range(size))

    def find(self, value: int) -> int:
        while self.parent[value] != value:
            self.parent[value] = self.parent[self.parent[value]]
            value = self.parent[value]
        return value

    def union(self, first: int, second: int) -> None:
        root_first = self.find(first)
        root_second = self.find(second)
        if root_first != root_second:
            self.parent[root_second] = root_first


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--predictions", required=True, type=Path)
    parser.add_argument("--annotation-bed", required=True, type=Path)
    parser.add_argument("--topology-file", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--threshold", type=float, default=0.5)
    parser.add_argument("--min-support", type=float, default=0.60)
    args = parser.parse_args()

    predictions = pd.read_csv(args.predictions)
    required = {"name_1", "name_2", "prob"}
    missing = required.difference(predictions.columns)
    if missing:
        raise SystemExit(f"Prediction file is missing columns: {sorted(missing)}")

    columns = ["chromosome", "source", "feature", "start", "end", "score", "strand", "phase", "name"]
    annotation = pd.read_csv(args.annotation_bed, sep="\t", names=columns)
    annotation["start"] = annotation["start"].astype(int)
    annotation["end"] = annotation["end"].astype(int)
    annotation["name"] = annotation["name"].astype(str)
    topology = read_topology(args.topology_file)

    edge_info: dict[tuple[str, str], tuple[float, float, bool]] = {}
    for row in predictions.itertuples(index=False):
        if pd.isna(row.prob):
            continue
        probability = float(row.prob)
        support = float(getattr(row, "support_fraction", 1.0))
        if hasattr(row, "robust_pred") and pd.notna(getattr(row, "robust_pred")):
            positive = int(getattr(row, "robust_pred")) == 1
        else:
            positive = probability >= args.threshold and support >= args.min_support
        value = (probability, support, positive)
        edge_info[(str(row.name_1), str(row.name_2))] = value
        edge_info[(str(row.name_2), str(row.name_1))] = value

    groups: list[dict[str, object]] = []
    operon_number = 1
    for (chromosome, strand), frame in annotation.groupby(["chromosome", "strand"], sort=False):
        ascending = strand == "+"
        ordered = frame.sort_values("start", ascending=ascending).reset_index(drop=True)
        gene_count = len(ordered)
        if gene_count < 2:
            continue

        is_circular = topology.get(str(chromosome), "circular") == "circular"
        uf = UnionFind(gene_count)
        positive_edges: dict[tuple[int, int], tuple[float, float]] = {}

        adjacent_pairs = [(index, index + 1) for index in range(gene_count - 1)]
        if is_circular:
            adjacent_pairs.append((gene_count - 1, 0))

        for first_index, second_index in adjacent_pairs:
            gene_1 = str(ordered.loc[first_index, "name"])
            gene_2 = str(ordered.loc[second_index, "name"])
            probability, support, positive = edge_info.get(
                (gene_1, gene_2), (float("nan"), float("nan"), False)
            )
            if positive:
                uf.union(first_index, second_index)
                positive_edges[(first_index, second_index)] = (probability, support)

        components: dict[int, list[int]] = {}
        for index in range(gene_count):
            components.setdefault(uf.find(index), []).append(index)

        for indexes in components.values():
            if len(indexes) < 2:
                continue
            index_set = set(indexes)
            component_edges: list[tuple[float, float]] = []
            wraps_origin = False
            for (first_index, second_index), metrics in positive_edges.items():
                if first_index in index_set and second_index in index_set:
                    component_edges.append(metrics)
                    if first_index == gene_count - 1 and second_index == 0:
                        wraps_origin = True

            selected = ordered.iloc[indexes]
            gene_names = selected["name"].astype(str).tolist()
            probabilities = [item[0] for item in component_edges]
            supports = [item[1] for item in component_edges]
            groups.append(
                {
                    "operon_id": f"OpDetect_operon_{operon_number:05d}",
                    "chromosome": chromosome,
                    "strand": strand,
                    "topology": "circular" if is_circular else "linear",
                    "wraps_origin": wraps_origin,
                    "gene_count": len(gene_names),
                    "genes": ",".join(gene_names),
                    "start": int(selected["start"].min()),
                    "end": int(selected["end"].max()),
                    "min_edge_probability": float(np.min(probabilities)),
                    "mean_edge_probability": float(np.mean(probabilities)),
                    "min_support_fraction": float(np.min(supports)),
                    "mean_support_fraction": float(np.mean(supports)),
                }
            )
            operon_number += 1

    output = pd.DataFrame(
        groups,
        columns=[
            "operon_id",
            "chromosome",
            "strand",
            "topology",
            "wraps_origin",
            "gene_count",
            "genes",
            "start",
            "end",
            "min_edge_probability",
            "mean_edge_probability",
            "min_support_fraction",
            "mean_support_fraction",
        ],
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    output.to_csv(args.output, sep="\t", index=False)
    print(
        f"Wrote {len(output)} robust candidate operons with at least two genes "
        f"to {args.output}"
    )


if __name__ == "__main__":
    main()
