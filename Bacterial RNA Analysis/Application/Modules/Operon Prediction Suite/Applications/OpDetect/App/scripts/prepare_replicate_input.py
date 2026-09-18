#!/usr/bin/env python3
"""Prepare variable-count biological replicates for the fixed six-channel model.

The real replicate channels are preserved separately.  Six-channel arrangements
are created only during prediction, where multiple balanced replicate orders are
averaged to reduce padding and channel-order bias.
"""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import pandas as pd
from scipy import signal

MODEL_LENGTH = 150
MAX_REPLICATES = 6


def resized_lengths(g1: int, ig: int, g2: int) -> tuple[int, int, int]:
    total = g1 + ig + g2
    if total <= 0:
        raise ValueError("A gene-pair sequence has zero total length")
    l_g1 = max(int((g1 / total) * MODEL_LENGTH), 2)
    l_g2 = max(int((g2 / total) * MODEL_LENGTH), 2)
    l_ig = max(MODEL_LENGTH - l_g1 - l_g2, 2)
    current = l_g1 + l_ig + l_g2
    if current != MODEL_LENGTH:
        diff = current - MODEL_LENGTH
        values = [l_g1, l_ig, l_g2]
        largest = int(np.argmax(values))
        values[largest] -= diff
        l_g1, l_ig, l_g2 = values
    if min(l_g1, l_ig, l_g2) < 2 or l_g1 + l_ig + l_g2 != MODEL_LENGTH:
        raise ValueError(
            f"Could not allocate model sequence lengths: {l_g1}, {l_ig}, {l_g2}"
        )
    return l_g1, l_ig, l_g2


def prepare_one(gene_1: np.ndarray, intergenic: np.ndarray, gene_2: np.ndarray) -> np.ndarray:
    gene_1 = np.asarray(gene_1, dtype=np.float32)
    intergenic = np.asarray(intergenic, dtype=np.float32)
    gene_2 = np.asarray(gene_2, dtype=np.float32)
    l_g1, l_ig, l_g2 = resized_lengths(len(gene_1), len(intergenic), len(gene_2))

    g1 = signal.resample(gene_1, l_g1).astype(np.float32)
    ig = signal.resample(intergenic, l_ig).astype(np.float32)
    g2 = signal.resample(gene_2, l_g2).astype(np.float32)

    maximum = float(max(np.max(g1), np.max(ig), np.max(g2)))
    minimum = float(min(np.min(g1), np.min(ig), np.min(g2)))
    if maximum - minimum != 0:
        g1 = (g1 - minimum) / (maximum - minimum)
        ig = (ig - minimum) / (maximum - minimum)
        g2 = (g2 - minimum) / (maximum - minimum)
    else:
        g1 = g1 - minimum
        ig = ig - minimum
        g2 = g2 - minimum

    g1 = signal.savgol_filter(g1, 4, 3, mode="nearest").astype(np.float32)
    ig = signal.savgol_filter(ig, 4, 3, mode="nearest").astype(np.float32)
    g2 = signal.savgol_filter(g2, 4, 3, mode="nearest").astype(np.float32)

    g1_channel = np.concatenate(
        [g1, np.zeros(l_ig, dtype=np.float32), np.zeros(l_g2, dtype=np.float32)]
    )
    ig_channel = np.concatenate(
        [np.zeros(l_g1, dtype=np.float32), ig, np.zeros(l_g2, dtype=np.float32)]
    )
    g2_channel = np.concatenate(
        [np.zeros(l_g1, dtype=np.float32), np.zeros(l_ig, dtype=np.float32), g2]
    )
    return np.stack([g1_channel, ig_channel, g2_channel], axis=-1)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--integrated", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--gene-pairs", required=True, type=Path)
    args = parser.parse_args()

    data = pd.read_pickle(args.integrated)
    replicate_names = list(data.attrs.get("replicate_names", []))
    if not replicate_names:
        replicate_indices = sorted(
            int(column.rsplit("_", 1)[1])
            for column in data.columns
            if column.startswith("gene_1_")
        )
        replicate_names = [f"replicate_{index + 1}" for index in replicate_indices]
    replicate_count = len(replicate_names)
    if not 1 <= replicate_count <= MAX_REPLICATES:
        raise SystemExit(
            f"Expected 1 to {MAX_REPLICATES} real replicates; found {replicate_count}"
        )
    if data.empty:
        raise SystemExit("Integrated dataset contains no gene pairs")

    tensor = np.empty(
        (len(data), replicate_count, MODEL_LENGTH, 3), dtype=np.float32
    )
    for row_index, row in enumerate(data.itertuples(index=False)):
        row_dict = row._asdict()
        for replicate_index in range(replicate_count):
            tensor[row_index, replicate_index] = prepare_one(
                row_dict[f"gene_1_{replicate_index}"],
                row_dict[f"intergenic_{replicate_index}"],
                row_dict[f"gene_2_{replicate_index}"],
            )
        if (row_index + 1) % 1000 == 0:
            print(f"Prepared {row_index + 1} of {len(data)} gene pairs", flush=True)

    # Force native Unicode arrays rather than pandas object arrays.  This keeps
    # the compressed NPZ readable with NumPy's safe default allow_pickle=False.
    names_1 = np.asarray(data["name_1"].astype(str).tolist(), dtype=np.str_)
    names_2 = np.asarray(data["name_2"].astype(str).tolist(), dtype=np.str_)
    labels = data.get("label", pd.Series([-1] * len(data))).to_numpy(dtype=np.int8)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(
        args.output,
        replicate_tensor=tensor,
        name_1=names_1,
        name_2=names_2,
        label=labels,
        replicate_names=np.asarray(replicate_names, dtype=str),
    )

    gene_pairs = pd.DataFrame(
        {"name_1": names_1, "name_2": names_2, "label": labels}
    )
    args.gene_pairs.parent.mkdir(parents=True, exist_ok=True)
    gene_pairs.to_csv(args.gene_pairs, index=False)
    print(
        f"Prepared {len(data)} gene pairs with {replicate_count} real biological "
        f"replicate channel(s)"
    )
    print(f"Saved replicate-aware model input to {args.output}")


if __name__ == "__main__":
    main()
