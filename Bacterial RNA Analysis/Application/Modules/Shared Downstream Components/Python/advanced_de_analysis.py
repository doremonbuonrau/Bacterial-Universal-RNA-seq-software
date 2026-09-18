#!/usr/bin/env python3
"""Bacterial-relevant exploratory and multi-contrast RNA-seq analyses.

The analyses in this module complement the core DESeq2/edgeR/limma-voom fit.
They are intentionally based only on the fitted model outputs, normalized
expression matrix, and sample metadata produced by ``de_analysis.R``.  This
keeps statistical testing in the established R engines while adding the
sample diagnostics, comparison views, and expression-pattern analyses that
are useful in multi-group bacterial studies.
"""
from __future__ import annotations

import itertools
import json
import math
import re
import sys
from collections import defaultdict
from pathlib import Path
from typing import Callable, Iterable

import numpy as np
import pandas as pd
import plotly.graph_objects as go
from plotly.subplots import make_subplots

from interactive_plots import VOLCANO_COLORSCALE, safe_neg_log10, write_plot


SELECTION_TAG = "BRA_SELECTION"
PALETTE = ["#2f8f83", "#d1775b", "#5f83bd", "#c4962c", "#8267a8", "#4f9b62", "#bd5f83", "#6c7a72"]
STATUS_COLUMNS = ["analysis", "status", "detail", "output"]


def read_config(path: Path) -> dict:
    with path.open(encoding="utf-8-sig") as handle:
        return json.load(handle)


def read_tsv(path: Path) -> pd.DataFrame:
    return pd.read_csv(path, sep="\t", dtype={"gene_id": "string"})


def write_tsv(frame: pd.DataFrame, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    frame.to_csv(path, sep="\t", index=False, lineterminator="\n")


def first_column(frame: pd.DataFrame, names: Iterable[str]) -> str | None:
    folded = {str(column).casefold(): str(column) for column in frame.columns}
    for name in names:
        if name.casefold() in folded:
            return folded[name.casefold()]
    return None


def selection(term_id: object, label: object, genes: Iterable[object]) -> list[str]:
    clean = []
    seen: set[str] = set()
    for value in genes:
        gene = str(value or "").strip()
        if gene and gene not in seen:
            seen.add(gene)
            clean.append(gene)
    return [SELECTION_TAG, str(term_id), str(label), "|".join(clean)]


def point_selection(gene: object, *extra: object) -> list[str]:
    value = str(gene or "").strip()
    return [SELECTION_TAG, value, value, value, *(str(item) for item in extra)]


def finite_numeric(frame: pd.DataFrame) -> pd.DataFrame:
    result = frame.apply(pd.to_numeric, errors="coerce")
    return result.replace([np.inf, -np.inf], np.nan)


def zscore_rows(values: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    means = np.nanmean(values, axis=1, keepdims=True)
    standard = np.nanstd(values, axis=1, ddof=0, keepdims=True)
    valid = np.isfinite(standard[:, 0]) & (standard[:, 0] > np.finfo(float).eps)
    output = np.zeros_like(values, dtype=float)
    output[valid] = (values[valid] - means[valid]) / standard[valid]
    return output, valid


def pca_coordinates(expression: pd.DataFrame, components: int = 3) -> tuple[np.ndarray, np.ndarray]:
    variances = expression.var(axis=1, ddof=0).sort_values(ascending=False)
    keep = variances.head(min(2000, len(variances))).index
    # Recent pandas releases may expose a read-only NumPy view.  PCA centers
    # the matrix in place, so request an owned, writable array explicitly.
    samples = expression.loc[keep].T.to_numpy(dtype=float, copy=True)
    samples -= np.nanmean(samples, axis=0, keepdims=True)
    samples = np.nan_to_num(samples, nan=0.0, posinf=0.0, neginf=0.0)
    u, singular, _ = np.linalg.svd(samples, full_matrices=False)
    count = min(components, len(singular))
    scores = u[:, :count] * singular[:count]
    if count < components:
        scores = np.pad(scores, ((0, 0), (0, components - count)))
    variance = singular**2
    explained = variance / max(float(variance.sum()), np.finfo(float).tiny)
    if len(explained) < components:
        explained = np.pad(explained, (0, components - len(explained)))
    return scores, explained[:components]


def average_linkage(distance: np.ndarray, labels: list[str]) -> tuple[list[int], pd.DataFrame, list[tuple[float, float, float, float]]]:
    """Deterministic average-linkage clustering without a SciPy dependency."""
    n = len(labels)
    if n <= 1:
        return list(range(n)), pd.DataFrame(columns=["step", "left_cluster", "right_cluster", "distance", "sample_count"]), []
    members: dict[int, tuple[int, ...]] = {index: (index,) for index in range(n)}
    children: dict[int, tuple[int, int]] = {}
    heights: dict[int, float] = {index: 0.0 for index in range(n)}
    active = list(range(n))
    rows: list[dict[str, object]] = []
    next_id = n

    def pair_distance(a: int, b: int) -> float:
        block = distance[np.ix_(members[a], members[b])]
        value = float(np.nanmean(block))
        return value if np.isfinite(value) else float("inf")

    while len(active) > 1:
        pairs = []
        for left_index, left in enumerate(active[:-1]):
            for right in active[left_index + 1 :]:
                pairs.append((pair_distance(left, right), min(members[left]), min(members[right]), left, right))
        height, _, _, left, right = min(pairs)
        if min(members[right]) < min(members[left]):
            left, right = right, left
        members[next_id] = members[left] + members[right]
        children[next_id] = (left, right)
        heights[next_id] = max(float(height), heights[left], heights[right])
        rows.append({
            "step": len(rows) + 1,
            "left_cluster": "; ".join(labels[index] for index in members[left]),
            "right_cluster": "; ".join(labels[index] for index in members[right]),
            "distance": heights[next_id],
            "sample_count": len(members[next_id]),
        })
        active = [item for item in active if item not in {left, right}] + [next_id]
        next_id += 1

    root = active[0]

    def leaves(node: int) -> list[int]:
        if node < n:
            return [node]
        left, right = children[node]
        return leaves(left) + leaves(right)

    order = leaves(root)
    x_positions = {leaf: float(position) for position, leaf in enumerate(order)}
    segments: list[tuple[float, float, float, float]] = []

    def node_x(node: int) -> float:
        if node in x_positions:
            return x_positions[node]
        left, right = children[node]
        value = (node_x(left) + node_x(right)) / 2.0
        x_positions[node] = value
        return value

    def draw(node: int) -> None:
        if node < n:
            return
        left, right = children[node]
        draw(left)
        draw(right)
        xl, xr = node_x(left), node_x(right)
        yl, yr, top = heights[left], heights[right], heights[node]
        segments.extend([(xl, yl, xl, top), (xr, yr, xr, top), (xl, top, xr, top)])

    draw(root)
    return order, pd.DataFrame(rows), segments


def fuzzy_c_means(values: np.ndarray, clusters: int, fuzzifier: float = 2.0, starts: int = 8, seed: int = 173) -> tuple[np.ndarray, np.ndarray, float]:
    if values.ndim != 2 or values.shape[0] < clusters:
        raise ValueError("Fuzzy clustering requires at least as many variable genes as clusters.")
    if fuzzifier <= 1:
        raise ValueError("The fuzzy-clustering exponent must be greater than 1.")
    rng = np.random.default_rng(seed)
    best: tuple[np.ndarray, np.ndarray, float] | None = None
    exponent = 2.0 / (fuzzifier - 1.0)
    for _ in range(max(1, starts)):
        membership = rng.dirichlet(np.ones(clusters), size=values.shape[0])
        previous = float("inf")
        for _iteration in range(300):
            weights = membership**fuzzifier
            centroids = (weights.T @ values) / np.maximum(weights.sum(axis=0)[:, None], np.finfo(float).tiny)
            distances = np.linalg.norm(values[:, None, :] - centroids[None, :, :], axis=2)
            zero_rows = np.any(distances <= 1e-12, axis=1)
            updated = np.zeros_like(membership)
            normal_rows = ~zero_rows
            if normal_rows.any():
                inverse = np.maximum(distances[normal_rows], 1e-12) ** (-exponent)
                updated[normal_rows] = inverse / inverse.sum(axis=1, keepdims=True)
            for row in np.where(zero_rows)[0]:
                hits = np.where(distances[row] <= 1e-12)[0]
                updated[row, hits] = 1.0 / len(hits)
            objective = float(np.sum((updated**fuzzifier) * (distances**2)))
            delta = float(np.max(np.abs(updated - membership)))
            membership = updated
            if delta < 1e-6 or abs(previous - objective) < 1e-9:
                break
            previous = objective
        weights = membership**fuzzifier
        centroids = (weights.T @ values) / np.maximum(weights.sum(axis=0)[:, None], np.finfo(float).tiny)
        distances = np.linalg.norm(values[:, None, :] - centroids[None, :, :], axis=2)
        objective = float(np.sum((membership**fuzzifier) * (distances**2)))
        if best is None or objective < best[2]:
            best = membership.copy(), centroids.copy(), objective
    assert best is not None
    return best


class AdvancedDE:
    def __init__(self, config_path: Path):
        self.config_path = config_path
        self.config = read_config(config_path)
        self.output = Path(str(self.config["output_dir"]))
        self.output.mkdir(parents=True, exist_ok=True)
        self.status: list[dict[str, str]] = []

        expression_path = self.output / "plot_expression_matrix.tsv"
        metadata_path = self.output / "analysis_metadata.tsv"
        result_path = self.output / "differential_expression.tsv"
        for required in (expression_path, metadata_path, result_path):
            if not required.is_file():
                raise FileNotFoundError(f"Advanced DE analysis requires: {required}")

        expression_frame = read_tsv(expression_path)
        gene_col = first_column(expression_frame, ("gene_id", "gene", "id")) or str(expression_frame.columns[0])
        expression_frame[gene_col] = expression_frame[gene_col].astype("string").str.strip()
        expression_frame = expression_frame.dropna(subset=[gene_col]).drop_duplicates(gene_col).set_index(gene_col)
        self.expression = finite_numeric(expression_frame).dropna(how="all").fillna(0.0)

        self.metadata = read_tsv(metadata_path)
        self.sample_column = str(self.config.get("sample_column") or self.metadata.columns[0])
        if self.sample_column not in self.metadata.columns:
            raise ValueError(f"Sample-ID column is absent from analysis metadata: {self.sample_column}")
        self.metadata[self.sample_column] = self.metadata[self.sample_column].astype("string").str.strip()
        self.metadata = self.metadata.drop_duplicates(self.sample_column).set_index(self.sample_column)
        missing = [sample for sample in self.expression.columns if sample not in self.metadata.index]
        if missing:
            raise ValueError("Sample metadata is missing expression columns: " + ", ".join(missing))
        self.metadata = self.metadata.loc[list(self.expression.columns)].copy()

        self.condition_column = str(self.config.get("condition_column") or "")
        if self.condition_column not in self.metadata.columns:
            raise ValueError(f"Condition column is absent from analysis metadata: {self.condition_column}")
        self.conditions = self.metadata[self.condition_column].astype("string").fillna("Unassigned")

        self.adjusted_expression: pd.DataFrame | None = None
        adjusted_path = self.output / "batch_corrected_plot_expression.tsv"
        if adjusted_path.is_file():
            adjusted = read_tsv(adjusted_path)
            adjusted_gene = first_column(adjusted, ("gene_id", "gene", "id")) or str(adjusted.columns[0])
            adjusted[adjusted_gene] = adjusted[adjusted_gene].astype("string").str.strip()
            adjusted = adjusted.dropna(subset=[adjusted_gene]).drop_duplicates(adjusted_gene).set_index(adjusted_gene)
            adjusted = finite_numeric(adjusted).reindex(index=self.expression.index, columns=self.expression.columns)
            if adjusted.notna().any().any():
                self.adjusted_expression = adjusted.fillna(self.expression)

        long_path = self.output / "differential_expression_long.tsv"
        self.de = read_tsv(long_path if long_path.is_file() else result_path)
        if "gene_id" not in self.de.columns:
            self.de = self.de.rename(columns={self.de.columns[0]: "gene_id"})
        self.de["gene_id"] = self.de["gene_id"].astype("string").str.strip()
        if "contrast" not in self.de.columns:
            label = str(self.config.get("test_level") or "Test") + " versus " + str(self.config.get("reference_level") or "Reference")
            self.de["contrast"] = label
        self.de["contrast"] = self.de["contrast"].astype("string")
        self.contrast_order = list(dict.fromkeys(self.de["contrast"].dropna().astype(str)))

    def record(self, analysis: str, status: str, detail: str, output: str = "") -> None:
        self.status.append({"analysis": analysis, "status": status, "detail": detail, "output": output})
        print(f"ADVANCED_DE\t{status.upper()}\t{analysis}\t{detail}", flush=True)

    def run_stage(self, name: str, function: Callable[[], list[str] | str | None]) -> None:
        try:
            result = function()
            outputs = [result] if isinstance(result, str) else (result or [])
            self.record(name, "completed", "Analysis completed.", "; ".join(outputs))
        except Exception as exc:
            self.record(name, "skipped", str(exc))

    @property
    def preferred_expression(self) -> pd.DataFrame:
        return self.adjusted_expression if self.adjusted_expression is not None else self.expression

    def sample_distributions(self) -> list[str]:
        stages = [("Normalized", self.expression)]
        if self.adjusted_expression is not None:
            stages.append(("Batch-adjusted for visualization", self.adjusted_expression))
        summary_rows: list[dict[str, object]] = []
        traces: list[go.Box] = []
        stage_trace_indices: dict[str, list[int]] = defaultdict(list)
        condition_by_sample = {
            str(sample): str(self.conditions.loc[sample])
            for sample in self.expression.columns
        }
        condition_order = list(dict.fromkeys(condition_by_sample.values()))
        condition_colors = {
            condition: PALETTE[index % len(PALETTE)]
            for index, condition in enumerate(condition_order)
        }
        for stage, matrix in stages:
            stage_legend_groups: set[str] = set()
            for sample in matrix.columns:
                values = matrix[sample].to_numpy(dtype=float)
                values = values[np.isfinite(values)]
                if not len(values):
                    continue
                condition = condition_by_sample.get(str(sample), "Unassigned")
                summary_rows.append({
                    "stage": stage,
                    "sample_id": sample,
                    "condition": condition,
                    "genes": len(values),
                    "minimum": float(np.min(values)),
                    "q1": float(np.quantile(values, 0.25)),
                    "median": float(np.median(values)),
                    "mean": float(np.mean(values)),
                    "q3": float(np.quantile(values, 0.75)),
                    "maximum": float(np.max(values)),
                })
                stage_trace_indices[stage].append(len(traces))
                show_condition = condition not in stage_legend_groups
                stage_legend_groups.add(condition)
                traces.append(go.Box(
                    x=[str(sample)] * len(values),
                    y=values,
                    name=condition,
                    legendgroup=condition,
                    showlegend=show_condition,
                    boxpoints=False,
                    marker_color=condition_colors[condition],
                    visible=stage == stages[0][0],
                    meta={"bra_kind": "sample_expression_distribution", "bra_color_group": condition},
                    hovertemplate=(
                        f"<b>{sample}</b><br>Condition: {condition}"
                        f"<br>expression: %{{y:.4g}}<extra>{stage}</extra>"
                    ),
                ))
        write_tsv(pd.DataFrame(summary_rows), self.output / "sample_expression_distribution.tsv")
        fig = go.Figure(traces)
        buttons = []
        for stage, _matrix in stages:
            visible = [False] * len(traces)
            for index in stage_trace_indices[stage]:
                visible[index] = True
            buttons.append({"label": stage, "method": "update", "args": [{"visible": visible}, {"title": f"Sample expression distributions · {stage}"}]})
        fig.update_layout(
            title=f"Sample expression distributions · {stages[0][0]}",
            yaxis_title="Normalized log-expression",
            xaxis={"title": "Sample", "categoryorder": "array", "categoryarray": [str(value) for value in self.expression.columns]},
            showlegend=True,
            legend={"title": {"text": self.condition_column}},
            updatemenus=[{"buttons": buttons, "x": 1.0, "xanchor": "right", "y": 1.16}] if len(buttons) > 1 else [],
        )
        path = self.output / "sample_expression_distributions_interactive.html"
        write_plot(fig, path)
        return [path.name, "sample_expression_distribution.tsv"]

    def correlations_and_clustering(self) -> list[str]:
        method = str(self.config.get("advanced_correlation_method") or "pearson").casefold()
        if method not in {"pearson", "spearman", "kendall"}:
            method = "pearson"
        stages = [("Normalized", self.expression)]
        if self.adjusted_expression is not None:
            stages.append(("Batch-adjusted", self.adjusted_expression))
        long_rows = []
        heatmaps = []
        clustering_frame: pd.DataFrame | None = None
        clustering_segments: list[tuple[float, float, float, float]] = []
        clustering_labels: list[str] = []
        clustering_stage = stages[-1][0]
        for stage, matrix in stages:
            correlation = matrix.corr(method=method, min_periods=max(3, min(20, len(matrix) // 4)))
            distance = np.clip(1.0 - correlation.to_numpy(dtype=float), 0.0, 2.0)
            distance = np.nan_to_num(distance, nan=1.0, posinf=2.0, neginf=0.0)
            np.fill_diagonal(distance, 0.0)
            order, merges, segments = average_linkage(distance, list(correlation.index.astype(str)))
            ordered = correlation.iloc[order, order]
            for sample_a in correlation.index:
                for sample_b in correlation.columns:
                    long_rows.append({"stage": stage, "method": method.title(), "sample_a": sample_a, "sample_b": sample_b, "correlation": correlation.loc[sample_a, sample_b]})
            custom = [[[str(row_sample), str(column_sample), stage] for column_sample in ordered.columns] for row_sample in ordered.index]
            heatmaps.append(go.Heatmap(z=ordered.to_numpy(), x=list(ordered.columns), y=list(ordered.index), zmin=-1, zmax=1, colorscale="RdBu", reversescale=True, colorbar={"title": f"{method.title()} r"}, customdata=custom, hovertemplate="%{y} × %{x}<br>correlation: %{z:.4f}<extra></extra>", visible=stage == stages[0][0]))
            if stage == clustering_stage:
                clustering_frame = merges.copy()
                clustering_frame.insert(0, "stage", stage)
                clustering_frame.insert(1, "method", method.title())
                clustering_segments = segments
                clustering_labels = [str(correlation.index[index]) for index in order]
        write_tsv(pd.DataFrame(long_rows), self.output / "sample_correlation_matrix.tsv")
        if clustering_frame is not None:
            write_tsv(clustering_frame, self.output / "sample_hierarchical_clustering.tsv")

        heatmap_fig = go.Figure(heatmaps)
        buttons = []
        for index, (stage, _matrix) in enumerate(stages):
            visible = [position == index for position in range(len(heatmaps))]
            buttons.append({"label": stage, "method": "update", "args": [{"visible": visible}, {"title": f"Sample correlation · {stage}"}]})
        heatmap_fig.update_layout(title=f"Sample correlation · {stages[0][0]}", xaxis_title="Sample", yaxis_title="Sample", updatemenus=[{"buttons": buttons, "x": 1.0, "xanchor": "right", "y": 1.16}] if len(buttons) > 1 else [])
        heatmap_path = self.output / "sample_correlation_interactive.html"
        write_plot(heatmap_fig, heatmap_path)

        dendrogram = go.Figure()
        for x0, y0, x1, y1 in clustering_segments:
            dendrogram.add_trace(go.Scatter(x=[x0, x1], y=[y0, y1], mode="lines", line={"color": "#365f49", "width": 2}, hoverinfo="skip", showlegend=False))
        # Leave half a leaf of horizontal padding on both sides. Without this,
        # the first dendrogram branch is drawn directly on the y axis and a
        # narrow embedded report can make the tree look like one thick axis.
        sample_count = len(clustering_labels)
        dendrogram.update_layout(
            title=f"Hierarchical sample clustering · {clustering_stage} · {method.title()}",
            xaxis={
                "tickmode": "array", "tickvals": list(range(sample_count)),
                "ticktext": clustering_labels, "tickangle": -35, "title": "Sample",
                "range": [-0.65, max(0.65, sample_count - 0.35)],
                "automargin": True, "domain": [0.03, 0.995],
                "showgrid": False, "zeroline": False,
            },
            yaxis={
                "title": "Average-linkage distance (1 − correlation)",
                "automargin": True, "rangemode": "tozero", "domain": [0.08, 0.98],
                "showgrid": False, "zeroline": False,
            },
            height=720,
            margin={"l": 105, "r": 38, "t": 76, "b": 135},
            meta={"bra_kind": "sample_dendrogram"},
        )
        dendrogram_path = self.output / "sample_dendrogram_interactive.html"
        write_plot(dendrogram, dendrogram_path)
        return [heatmap_path.name, dendrogram_path.name, "sample_correlation_matrix.tsv", "sample_hierarchical_clustering.tsv"]

    def pca_3d(self) -> list[str]:
        stages = [("Normalized", self.expression)]
        if self.adjusted_expression is not None:
            stages.append(("Batch-adjusted", self.adjusted_expression))
        coordinate_rows = []
        traces = []
        stage_trace_indices: dict[str, list[int]] = defaultdict(list)
        stage_explained: dict[str, np.ndarray] = {}
        for stage_index, (stage, matrix) in enumerate(stages):
            scores, explained = pca_coordinates(matrix, 3)
            stage_explained[stage] = explained
            for index, sample in enumerate(matrix.columns):
                row = {"stage": stage, "sample_id": sample, "PC1": scores[index, 0], "PC2": scores[index, 1], "PC3": scores[index, 2], "PC1_percent": explained[0] * 100, "PC2_percent": explained[1] * 100, "PC3_percent": explained[2] * 100}
                for column in self.metadata.columns:
                    row[str(column)] = self.metadata.iloc[index][column]
                coordinate_rows.append(row)
            condition_values = self.conditions.astype(str).tolist()
            levels = list(dict.fromkeys(condition_values))
            colours = {level: PALETTE[position % len(PALETTE)] for position, level in enumerate(levels)}
            for level in levels:
                selected = np.asarray([value == level for value in condition_values])
                stage_trace_indices[stage].append(len(traces))
                traces.append(go.Scatter3d(
                    x=scores[selected, 0], y=scores[selected, 1], z=scores[selected, 2], mode="markers+text", name=level,
                    legendgroup=level, text=list(np.asarray(matrix.columns)[selected]), textposition="top center", visible=stage_index == 0,
                    marker={"size": 7, "color": colours[level], "line": {"color": "#314a3b", "width": 0.5}},
                    customdata=np.column_stack([np.asarray(matrix.columns)[selected], np.asarray(condition_values)[selected]]),
                    hovertemplate="<b>%{customdata[0]}</b><br>condition: %{customdata[1]}<br>PC1: %{x:.4g}<br>PC2: %{y:.4g}<br>PC3: %{z:.4g}<extra>" + stage + "</extra>",
                ))
        write_tsv(pd.DataFrame(coordinate_rows), self.output / "sample_pca_coordinates.tsv")
        buttons = []
        for stage, _matrix in stages:
            explained = stage_explained[stage]
            visible = [False] * len(traces)
            for position in stage_trace_indices[stage]:
                visible[position] = True
            buttons.append({"label": stage, "method": "update", "args": [{"visible": visible}, {"title": f"Interactive 3D PCA · {stage}", "scene.xaxis.title": f"PC1 ({explained[0]*100:.1f}%)", "scene.yaxis.title": f"PC2 ({explained[1]*100:.1f}%)", "scene.zaxis.title": f"PC3 ({explained[2]*100:.1f}%)"}]})
        first_explained = stage_explained[stages[0][0]]
        fig = go.Figure(traces)
        fig.update_layout(title=f"Interactive 3D PCA · {stages[0][0]}", scene={"xaxis_title": f"PC1 ({first_explained[0]*100:.1f}%)", "yaxis_title": f"PC2 ({first_explained[1]*100:.1f}%)", "zaxis_title": f"PC3 ({first_explained[2]*100:.1f}%)", "bgcolor": "#ffffff"}, updatemenus=[{"buttons": buttons, "x": 1.0, "xanchor": "right", "y": 1.12}] if len(buttons) > 1 else [], legend={"title": {"text": self.condition_column}, "orientation": "h", "y": -0.12})
        path = self.output / "sample_pca_3d_interactive.html"
        write_plot(fig, path)
        return [path.name, "sample_pca_coordinates.tsv"]

    def source_of_variation(self) -> list[str]:
        excluded = {self.sample_column.casefold(), ".condition", ".batch"}
        factors: list[str] = []
        sample_count = len(self.metadata)
        for column in self.metadata.columns:
            folded = str(column).casefold()
            if folded in excluded or re.search(r"(?:sample.?id|replicate|technical.?run|run.?id)$", folded):
                continue
            values = self.metadata[column]
            unique = values.dropna().astype(str).str.strip().replace("", np.nan).dropna().nunique()
            if 2 <= unique <= min(20, max(2, sample_count // 2 + 1)) or str(column) in {self.condition_column, str(self.config.get("batch_column") or "")}:
                factors.append(str(column))
        factors = list(dict.fromkeys(factors))
        if not factors:
            raise ValueError("No repeated condition, batch, or phenotype factors are available for source-of-variation analysis.")

        stages = [("Normalized", self.expression)]
        if self.adjusted_expression is not None:
            stages.append(("Batch-adjusted", self.adjusted_expression))
        rows = []
        for stage, matrix in stages:
            matrix_values = matrix.to_numpy(dtype=float)
            for factor in factors:
                groups = self.metadata[factor].astype("string").fillna("Missing").to_numpy()
                effects = []
                for gene_values in matrix_values:
                    valid = np.isfinite(gene_values)
                    values = gene_values[valid]
                    group_values = groups[valid]
                    if len(values) < 3:
                        continue
                    total = float(np.sum((values - np.mean(values)) ** 2))
                    if total <= np.finfo(float).eps:
                        continue
                    between = 0.0
                    for level in pd.unique(group_values):
                        selected = values[group_values == level]
                        if len(selected):
                            between += len(selected) * float((np.mean(selected) - np.mean(values)) ** 2)
                    effects.append(min(1.0, max(0.0, between / total)))
                if not effects:
                    continue
                array = np.asarray(effects)
                rows.append({"stage": stage, "factor": factor, "factor_levels": int(pd.Series(groups).nunique()), "genes_evaluated": len(array), "mean_eta_squared": float(np.mean(array)), "q1_eta_squared": float(np.quantile(array, 0.25)), "median_eta_squared": float(np.median(array)), "q3_eta_squared": float(np.quantile(array, 0.75))})
        result = pd.DataFrame(rows)
        if result.empty:
            raise ValueError("No variable genes were available for source-of-variation analysis.")
        write_tsv(result, self.output / "source_of_variation.tsv")
        fig = go.Figure()
        for index, (stage, group) in enumerate(result.groupby("stage", sort=False)):
            fig.add_trace(go.Bar(x=group["factor"], y=group["median_eta_squared"], name=stage, marker_color=PALETTE[index], error_y={"type": "data", "symmetric": False, "array": (group["q3_eta_squared"] - group["median_eta_squared"]).clip(lower=0), "arrayminus": (group["median_eta_squared"] - group["q1_eta_squared"]).clip(lower=0)}, customdata=np.column_stack([group["mean_eta_squared"], group["genes_evaluated"], group["factor_levels"]]), hovertemplate="<b>%{x}</b><br>median η²: %{y:.4f}<br>mean η²: %{customdata[0]:.4f}<br>genes: %{customdata[1]}<br>levels: %{customdata[2]}<extra>%{fullData.name}</extra>"))
        fig.update_layout(title="Source of variation across expressed genes", xaxis_title="Sample factor", yaxis_title="Variance explained (η²; median with IQR)", barmode="group", legend={"orientation": "h", "y": 1.10})
        path = self.output / "source_of_variation_interactive.html"
        write_plot(fig, path)
        return [path.name, "source_of_variation.tsv"]

    def pvalue_histogram(self) -> list[str]:
        p_col = first_column(self.de, ("pvalue", "PValue", "P.Value", "raw_p_value"))
        if p_col is None:
            raise ValueError("No raw p-value column is available. Adjusted p-values are not used for the null-distribution diagnostic.")
        bins = np.linspace(0.0, 1.0, 21)
        rows = []
        traces = []
        for contrast_index, contrast in enumerate(self.contrast_order):
            frame = self.de.loc[self.de["contrast"].astype(str).eq(contrast), ["gene_id", p_col]].copy()
            frame[p_col] = pd.to_numeric(frame[p_col], errors="coerce")
            frame = frame.loc[frame[p_col].between(0, 1, inclusive="both")].copy()
            indices = np.minimum(np.searchsorted(bins, frame[p_col].to_numpy(), side="right") - 1, len(bins) - 2)
            counts = []
            custom = []
            for index in range(len(bins) - 1):
                genes = frame.loc[indices == index, "gene_id"].dropna().astype(str).tolist()
                counts.append(len(genes))
                label = f"p ∈ [{bins[index]:.2f}, {bins[index+1]:.2f}{']' if index == len(bins)-2 else ')'}"
                custom.append(selection(f"p_bin_{index+1}", label, genes))
                rows.append({"contrast": contrast, "bin_start": bins[index], "bin_end": bins[index + 1], "gene_count": len(genes)})
            centers = (bins[:-1] + bins[1:]) / 2
            traces.append(go.Bar(x=centers, y=counts, width=0.047, name=contrast, customdata=custom, visible=contrast_index == 0, marker_color=PALETTE[contrast_index % len(PALETTE)], selected={"marker":{"color":"#7b2cbf","opacity":1.0}}, unselected={"marker":{"opacity":0.30}}, hovertemplate="%{customdata[2]}<br>genes: %{y}<br><b>Click to show these genes</b><extra>" + contrast + "</extra>"))
        write_tsv(pd.DataFrame(rows), self.output / "de_pvalue_histogram.tsv")
        buttons = [{"label": contrast, "method": "update", "args": [{"visible": [position == index for position in range(len(traces))]}, {"title": f"Raw p-value distribution · {contrast}"}]} for index, contrast in enumerate(self.contrast_order)]
        fig = go.Figure(traces)
        tick_values = [float(value) for value in centers[::2]]
        if not tick_values or tick_values[-1] != float(centers[-1]):
            tick_values.append(float(centers[-1]))
        tick_text = [f"{value:.3g}" for value in tick_values]
        fig.update_layout(
            title=f"Raw p-value distribution · {self.contrast_order[0]}",
            xaxis={
                "title": "Raw p-value",
                "range": [0.0, 1.0],
                "tickmode": "array",
                "tickvals": tick_values,
                "ticktext": tick_text,
                "tickangle": -35,
                "automargin": True,
            },
            yaxis_title="Tested genes",
            bargap=0.03,
            updatemenus=[{"buttons": buttons, "x": 1.0, "xanchor": "right", "y": 1.15}] if len(buttons) > 1 else [],
        )
        path = self.output / "de_pvalue_histogram_interactive.html"
        write_plot(fig, path)
        return [path.name, "de_pvalue_histogram.tsv"]

    def gene_rank(self) -> list[str]:
        lfc_col = first_column(self.de, ("log2FoldChange", "logFC", "log2fc"))
        stat_col = first_column(self.de, ("stat", "t", "WaldStatistic", "score"))
        p_col = first_column(self.de, ("pvalue", "PValue", "P.Value", "padj", "FDR"))
        function_col = first_column(
            self.de,
            (
                "product",
                "function",
                "gene_function",
                "functional_annotation",
                "annotation",
                "gene_product",
                "protein_function",
                "protein_product",
                "description",
            ),
        )
        if lfc_col is None:
            raise ValueError("A log2 fold-change column is required for gene ranking.")
        rows = []
        traces = []
        for contrast_index, contrast in enumerate(self.contrast_order):
            frame = self.de.loc[self.de["contrast"].astype(str).eq(contrast)].copy()
            frame[lfc_col] = pd.to_numeric(frame[lfc_col], errors="coerce")
            if stat_col:
                score = pd.to_numeric(frame[stat_col], errors="coerce")
            elif p_col:
                score = np.sign(frame[lfc_col]) * safe_neg_log10(frame[p_col])
            else:
                score = frame[lfc_col]
            frame["rank_score"] = score
            frame = frame.dropna(subset=["gene_id", "rank_score"]).sort_values("rank_score", ascending=False).reset_index(drop=True)
            frame["rank"] = np.arange(1, len(frame) + 1)
            if function_col:
                function_values = frame[function_col].fillna("").astype(str).str.strip()
                function_values = function_values.mask(function_values.str.casefold().isin({"nan", "none", "na"}), "")
            else:
                function_values = pd.Series("", index=frame.index, dtype="string")
            frame["function_product"] = function_values.mask(function_values.eq(""), "Function not available")
            for row in frame[["gene_id", "rank", "rank_score", lfc_col, "function_product"]].itertuples(index=False, name=None):
                rows.append({"contrast": contrast, "gene_id": row[0], "rank": row[1], "rank_score": row[2], "log2FoldChange": row[3], "function_product": row[4]})
            custom = [
                point_selection(gene, contrast, rank, function_product)
                for gene, rank, function_product in zip(frame["gene_id"], frame["rank"], frame["function_product"])
            ]
            traces.append(go.Scattergl(
                x=frame["rank"], y=frame["rank_score"], mode="markers", name=contrast,
                customdata=custom, visible=contrast_index == 0,
                marker={"size": 6, "color": frame[lfc_col], "colorscale": VOLCANO_COLORSCALE, "cmid": 0, "showscale": True, "colorbar": {"title": "log₂ FC"}, "opacity": 0.78},
                selected={"marker": {"color": "#7b2cbf", "size": 10, "opacity": 1.0}},
                unselected={"marker": {"opacity": 0.18}},
                hovertemplate=(
                    "<b>%{customdata[1]}</b><br>Function / product: %{customdata[6]}"
                    "<br>rank: %{x}<br>score: %{y:.4g}"
                    "<br><b>Click to show the annotated gene row</b><extra>" + contrast + "</extra>"
                ),
            ))
        write_tsv(pd.DataFrame(rows), self.output / "de_gene_rank.tsv")
        buttons = [{"label": contrast, "method": "update", "args": [{"visible": [position == index for position in range(len(traces))]}, {"title": f"Ranked differential-expression statistic · {contrast}"}]} for index, contrast in enumerate(self.contrast_order)]
        fig = go.Figure(traces)
        fig.update_layout(
            title=f"Ranked differential-expression statistic · {self.contrast_order[0]}",
            xaxis_title="Gene rank", yaxis_title="Signed test statistic",
            updatemenus=[{"buttons": buttons, "x": 0.88, "xanchor": "right", "y": 1.15}] if len(buttons) > 1 else [],
            showlegend=False, meta={"bra_kind": "de_gene_rank"},
        )
        path = self.output / "de_gene_rank_interactive.html"
        write_plot(fig, path)
        return [path.name, "de_gene_rank.tsv"]

    def top_variable_heatmap(self) -> list[str]:
        matrix = self.preferred_expression
        limit = max(20, min(500, int(self.config.get("advanced_heatmap_genes") or 100)))
        variances = matrix.var(axis=1, ddof=0).sort_values(ascending=False)
        genes = list(variances.head(min(limit, len(variances))).index.astype(str))
        selected = matrix.loc[genes]
        scaled, valid = zscore_rows(selected.to_numpy(dtype=float))
        selected = selected.loc[np.asarray(valid)]
        genes = list(selected.index.astype(str))
        scaled = scaled[valid]
        if not len(genes):
            raise ValueError("No variable genes are available for the top-variable-gene heatmap.")
        output = pd.DataFrame(selected.to_numpy(), columns=selected.columns)
        output.insert(0, "gene_id", genes)
        write_tsv(output, self.output / "top_variable_gene_expression.tsv")
        custom = [[[SELECTION_TAG, gene, gene, gene, sample] for sample in selected.columns] for gene in genes]
        fig = go.Figure(go.Heatmap(z=scaled, x=list(selected.columns), y=genes, colorscale="RdBu", reversescale=True, zmid=0, colorbar={"title": "Gene Z score"}, customdata=custom, hovertemplate="<b>%{customdata[1]}</b><br>sample: %{customdata[4]}<br>Z score: %{z:.4g}<br><b>Click to show this gene</b><extra></extra>"))
        all_scaled, all_valid = zscore_rows(matrix.to_numpy(dtype=float))
        all_gene_names = list(matrix.index.astype(str))
        selectable = {
            gene: [float(value) for value in all_scaled[index]]
            for index, gene in enumerate(all_gene_names) if bool(all_valid[index])
        }
        default_title = f"Top {len(genes)} variable genes"
        default_height = max(650, min(1500, 13 * len(genes) + 180))
        fig.update_layout(
            title=default_title, xaxis_title="Sample", yaxis_title="Gene",
            height=default_height,
            meta={
                "bra_kind": "top_variable_gene_heatmap",
                "bra_samples": [str(value) for value in matrix.columns],
                "bra_heatmap_by_gene": selectable,
                "bra_default_title": default_title,
                "bra_default_height": default_height,
            },
        )
        path = self.output / "top_variable_genes_heatmap_interactive.html"
        write_plot(fig, path)
        return [path.name, "top_variable_gene_expression.tsv"]

    def single_gene_expression(self) -> list[str]:
        matrix = self.preferred_expression
        limit = max(10, min(200, int(self.config.get("advanced_single_gene_choices") or 100)))
        genes = list(matrix.var(axis=1, ddof=0).nlargest(min(limit, len(matrix))).index.astype(str))
        if not genes:
            raise ValueError("No variable genes are available for single-gene expression plots.")
        rows = []
        condition_values = self.conditions.astype(str).tolist()
        for gene in genes:
            values = matrix.loc[gene].to_numpy(dtype=float)
            for sample, condition, value in zip(matrix.columns, condition_values, values):
                rows.append({"gene_id": gene, "sample_id": sample, "condition": condition, "normalized_log_expression": value})
        write_tsv(pd.DataFrame(rows), self.output / "single_gene_expression.tsv")
        trace = go.Box(
            x=[], y=[], name="Selected gene", boxpoints="all", jitter=0.28, pointpos=0,
            width=0.55, marker={"size": 7, "color": PALETTE[0]}, customdata=[],
            hoveron="boxes", hoverinfo="all", yhoverformat=".6f",
        )
        expression_by_gene = {
            str(gene): [float(value) for value in matrix.loc[gene].to_numpy(dtype=float)]
            for gene in matrix.index.astype(str)
        }
        fig = go.Figure([trace])
        fig.update_layout(
            title="", xaxis_title=self.condition_column,
            yaxis_title="Normalized log-expression", showlegend=False,
            xaxis={"type": "category"},
            annotations=[{
                "name": "BRA_SINGLE_GENE_EMPTY",
                "text": "Please click an individual gene in the interactive spreadsheet<br>to display its expression statistics.",
                "xref": "paper", "yref": "paper", "x": 0.5, "y": 0.52,
                "showarrow": False, "align": "center",
                "font": {"size": 16, "color": "#557064"},
            }],
            meta={
                "bra_kind": "single_gene_expression",
                "bra_samples": [str(value) for value in matrix.columns],
                "bra_conditions": condition_values,
                "bra_test_level": str(self.config.get("test_level") or ""),
                "bra_expression_by_gene": expression_by_gene,
            },
        )
        path = self.output / "single_gene_expression_interactive.html"
        write_plot(fig, path)
        return [path.name, "single_gene_expression.tsv"]

    def multi_contrast_overlap(self) -> list[str]:
        if len(self.contrast_order) < 2:
            raise ValueError("At least two treatment-versus-control contrasts are required.")
        contrasts = self.contrast_order[:12]
        padj_col = first_column(self.de, ("padj", "FDR", "adj.P.Val", "p.adjust"))
        lfc_col = first_column(self.de, ("log2FoldChange", "logFC", "log2fc"))
        if padj_col is None or lfc_col is None:
            raise ValueError("Adjusted p-values and log2 fold changes are required for overlap analysis.")
        cutoff = float(self.config.get("padj_cutoff", 0.05))
        lfc_cutoff = float(self.config.get("lfc_cutoff", 1.0))
        membership: dict[str, set[str]] = {}
        for contrast in contrasts:
            frame = self.de.loc[self.de["contrast"].astype(str).eq(contrast)].copy()
            padj = pd.to_numeric(frame[padj_col], errors="coerce")
            lfc = pd.to_numeric(frame[lfc_col], errors="coerce")
            membership[contrast] = set(frame.loc[padj.le(cutoff) & lfc.abs().ge(lfc_cutoff), "gene_id"].dropna().astype(str))
        all_genes = sorted(set().union(*membership.values()))
        if not all_genes:
            raise ValueError("No genes pass the configured adjusted-p and fold-change thresholds in any contrast.")
        pattern_genes: dict[tuple[bool, ...], list[str]] = defaultdict(list)
        member_rows = []
        for gene in all_genes:
            pattern = tuple(gene in membership[contrast] for contrast in contrasts)
            pattern_genes[pattern].append(gene)
            active = [contrast for contrast, included in zip(contrasts, pattern) if included]
            member_rows.append({"gene_id": gene, "intersection": " & ".join(active), "contrast_count": len(active), **{contrast: included for contrast, included in zip(contrasts, pattern)}})
        ordered = sorted(pattern_genes.items(), key=lambda item: (-len(item[1]), -sum(item[0]), tuple(not value for value in item[0])))[:30]
        intersection_rows = []
        for index, (pattern, genes) in enumerate(ordered, start=1):
            active = [contrast for contrast, included in zip(contrasts, pattern) if included]
            intersection_rows.append({"intersection_id": index, "intersection": " & ".join(active), "contrast_count": len(active), "gene_count": len(genes)})
        write_tsv(pd.DataFrame(intersection_rows), self.output / "de_overlap_intersections.tsv")
        write_tsv(pd.DataFrame(member_rows), self.output / "de_overlap_members.tsv")

        fig = make_subplots(rows=2, cols=1, shared_xaxes=True, row_heights=[0.64, 0.36], vertical_spacing=0.04)
        x_values = list(range(1, len(ordered) + 1))
        bar_custom = []
        for index, (pattern, genes) in enumerate(ordered, start=1):
            active = [contrast for contrast, included in zip(contrasts, pattern) if included]
            bar_custom.append(selection(f"intersection_{index}", " & ".join(active), genes))
        fig.add_trace(go.Bar(x=x_values, y=[len(genes) for _pattern, genes in ordered], marker_color="#2f8f83", customdata=bar_custom, hovertemplate="<b>%{customdata[2]}</b><br>genes: %{y}<br><b>Click to show this intersection</b><extra></extra>", showlegend=False), row=1, col=1)
        for x_value, (pattern, genes) in zip(x_values, ordered):
            active_indices = [index for index, included in enumerate(pattern) if included]
            if len(active_indices) > 1:
                fig.add_trace(go.Scatter(x=[x_value, x_value], y=[min(active_indices), max(active_indices)], mode="lines", line={"color": "#173426", "width": 2}, hoverinfo="skip", showlegend=False), row=2, col=1)
            inactive = [index for index, included in enumerate(pattern) if not included]
            if inactive:
                fig.add_trace(go.Scatter(x=[x_value] * len(inactive), y=inactive, mode="markers", marker={"size": 8, "color": "#dfe7e1"}, hoverinfo="skip", showlegend=False), row=2, col=1)
            custom = [selection(f"intersection_{x_value}", " & ".join(contrast for contrast, included in zip(contrasts, pattern) if included), genes) for _ in active_indices]
            fig.add_trace(go.Scatter(x=[x_value] * len(active_indices), y=active_indices, mode="markers", marker={"size": 11, "color": "#173426"}, customdata=custom, hovertemplate="%{customdata[2]}<br><b>Click to show genes</b><extra></extra>", showlegend=False), row=2, col=1)
        fig.update_yaxes(title_text="Genes", row=1, col=1)
        fig.update_yaxes(tickmode="array", tickvals=list(range(len(contrasts))), ticktext=contrasts, autorange="reversed", row=2, col=1)
        fig.update_xaxes(title_text="Observed exclusive intersections", tickmode="array", tickvals=x_values, ticktext=[str(value) for value in x_values], row=2, col=1)
        fig.update_layout(title="Multi-contrast differential-expression overlap (UpSet)", height=max(680, 360 + 42 * len(contrasts)))
        path = self.output / "de_upset_interactive.html"
        write_plot(fig, path)

        outputs = [path.name, "de_overlap_intersections.tsv", "de_overlap_members.tsv"]
        if len(contrasts) <= 3:
            venn = go.Figure()
            colours = ["#2f8f83", "#d1775b", "#5f83bd"]
            if len(contrasts) == 2:
                centres = [(0.40, 0.50), (0.60, 0.50)]
                radius = 0.28
                positions = {
                    (True, False): (0.28, 0.50),
                    (False, True): (0.72, 0.50),
                    (True, True): (0.50, 0.50),
                }
                label_positions = [(0.28, 0.84), (0.72, 0.84)]
            else:
                centres = [(0.40, 0.59), (0.60, 0.59), (0.50, 0.40)]
                radius = 0.27
                positions = {
                    (True, False, False): (0.27, 0.68),
                    (False, True, False): (0.73, 0.68),
                    (False, False, True): (0.50, 0.20),
                    (True, True, False): (0.50, 0.73),
                    (True, False, True): (0.39, 0.42),
                    (False, True, True): (0.61, 0.42),
                    (True, True, True): (0.50, 0.53),
                }
                label_positions = [(0.24, 0.89), (0.76, 0.89), (0.50, 0.06)]
            for index, ((centre_x, centre_y), colour) in enumerate(zip(centres, colours)):
                venn.add_shape(
                    type="circle",
                    x0=centre_x - radius,
                    x1=centre_x + radius,
                    y0=centre_y - radius,
                    y1=centre_y + radius,
                    fillcolor=colour,
                    opacity=0.22,
                    line={"color": colour, "width": 3},
                    layer="below",
                )
                label_x, label_y = label_positions[index]
                venn.add_annotation(
                    x=label_x,
                    y=label_y,
                    text=f"<b>{chr(65 + index)}</b> · {contrasts[index]}",
                    showarrow=False,
                    font={"color": colours[index], "size": 13},
                    align="center",
                )
            region_x = []
            region_y = []
            region_text = []
            region_custom = []
            for pattern, (position_x, position_y) in positions.items():
                genes = pattern_genes.get(pattern, [])
                active = [contrast for contrast, included in zip(contrasts, pattern) if included]
                label = " & ".join(active)
                region_x.append(position_x)
                region_y.append(position_y)
                region_text.append(str(len(genes)))
                region_custom.append([*selection("venn_" + "_".join(str(int(value)) for value in pattern), label, genes), len(genes)])
            venn.add_trace(
                go.Scatter(
                    x=region_x,
                    y=region_y,
                    mode="markers+text",
                    marker={"size": 42, "color": "rgba(255,255,255,0.01)", "line": {"width": 0}},
                    text=region_text,
                    textposition="middle center",
                    textfont={"size": 16, "color": "#173426"},
                    customdata=region_custom,
                    hovertemplate="<b>%{customdata[2]}</b><br>exclusive genes: %{customdata[4]}<br><b>Click to show this region</b><extra></extra>",
                    showlegend=False,
                )
            )
            venn.update_xaxes(visible=False, range=[0, 1], fixedrange=True)
            venn.update_yaxes(visible=False, range=[0, 1], fixedrange=True, scaleanchor="x", scaleratio=1)
            venn.update_layout(
                title=f"Differential-expression overlap (Venn) · {len(contrasts)} contrasts",
                height=680,
                margin={"l": 30, "r": 30, "t": 80, "b": 35},
                dragmode=False,
            )
            venn_path = self.output / "de_venn_interactive.html"
            write_plot(venn, venn_path)
            outputs.insert(1, venn_path.name)
        return outputs

    def fold_change_comparison(self) -> list[str]:
        if len(self.contrast_order) < 2:
            raise ValueError("At least two treatment-versus-control contrasts are required.")
        lfc_col = first_column(self.de, ("log2FoldChange", "logFC", "log2fc"))
        padj_col = first_column(self.de, ("padj", "FDR", "adj.P.Val", "p.adjust"))
        if lfc_col is None or padj_col is None:
            raise ValueError("Adjusted p-values and log2 fold changes are required for fold-change comparison.")
        cutoff = float(self.config.get("padj_cutoff", 0.05))
        lfc_cutoff = float(self.config.get("lfc_cutoff", 1.0))
        pairs = list(itertools.combinations(self.contrast_order, 2))[:10]
        pair_frames = []
        traces = []
        category_colors = {"Concordant significant": "#2f8f83", "Discordant significant": "#d1544a", "One contrast significant": "#c4962c", "Not significant": "#b8c2bc"}
        for pair_index, (left, right) in enumerate(pairs):
            a = self.de.loc[self.de["contrast"].astype(str).eq(left), ["gene_id", lfc_col, padj_col]].copy().rename(columns={lfc_col: "log2FC_x", padj_col: "padj_x"})
            b = self.de.loc[self.de["contrast"].astype(str).eq(right), ["gene_id", lfc_col, padj_col]].copy().rename(columns={lfc_col: "log2FC_y", padj_col: "padj_y"})
            frame = a.merge(b, on="gene_id", how="inner")
            for column in ("log2FC_x", "padj_x", "log2FC_y", "padj_y"):
                frame[column] = pd.to_numeric(frame[column], errors="coerce")
            frame = frame.dropna(subset=["log2FC_x", "log2FC_y"])
            sig_x = frame["padj_x"].le(cutoff) & frame["log2FC_x"].abs().ge(lfc_cutoff)
            sig_y = frame["padj_y"].le(cutoff) & frame["log2FC_y"].abs().ge(lfc_cutoff)
            frame["classification"] = "Not significant"
            frame.loc[sig_x ^ sig_y, "classification"] = "One contrast significant"
            both = sig_x & sig_y
            frame.loc[both & (np.sign(frame["log2FC_x"]) == np.sign(frame["log2FC_y"])), "classification"] = "Concordant significant"
            frame.loc[both & (np.sign(frame["log2FC_x"]) != np.sign(frame["log2FC_y"])), "classification"] = "Discordant significant"
            frame.insert(0, "contrast_x", left)
            frame.insert(1, "contrast_y", right)
            pair_frames.append(frame)
            custom = [point_selection(gene, left, right, category, px, py) for gene, category, px, py in zip(frame["gene_id"], frame["classification"], frame["padj_x"], frame["padj_y"])]
            traces.append(go.Scattergl(x=frame["log2FC_x"], y=frame["log2FC_y"], mode="markers", name=f"{left} × {right}", visible=pair_index == 0, marker={"size": 7, "color": [category_colors[value] for value in frame["classification"]], "opacity": 0.75}, customdata=custom, hovertemplate="<b>%{customdata[1]}</b><br>" + left + ": %{x:.4g}<br>" + right + ": %{y:.4g}<br>class: %{customdata[6]}<br>adjusted p: %{customdata[7]:.3g}, %{customdata[8]:.3g}<br><b>Click to show this gene</b><extra></extra>"))
        write_tsv(pd.concat(pair_frames, ignore_index=True), self.output / "fold_change_comparisons.tsv")
        for label, color in category_colors.items():
            traces.append(go.Scatter(x=[None], y=[None], mode="markers", name=label, marker={"size": 9, "color": color}, showlegend=True))
        pair_trace_count = len(pairs)
        buttons = []
        for index, (left, right) in enumerate(pairs):
            visible = [position == index for position in range(pair_trace_count)] + [True] * len(category_colors)
            buttons.append({"label": f"{left} × {right}", "method": "update", "args": [{"visible": visible}, {"title": f"Fold-change comparison · {left} × {right}", "xaxis.title": f"log₂ fold change · {left}", "yaxis.title": f"log₂ fold change · {right}"}]})
        first_left, first_right = pairs[0]
        fig = go.Figure(traces)
        fig.add_hline(y=0, line_color="#65736b", line_width=1)
        fig.add_vline(x=0, line_color="#65736b", line_width=1)
        fig.add_shape(type="line", x0=-100, y0=-100, x1=100, y1=100, line={"color": "#8b958f", "dash": "dot"})
        fig.update_layout(title=f"Fold-change comparison · {first_left} × {first_right}", xaxis_title=f"log₂ fold change · {first_left}", yaxis_title=f"log₂ fold change · {first_right}", legend={"orientation": "h", "y": -0.18}, updatemenus=[{"buttons": buttons, "x": 1.0, "xanchor": "right", "y": 1.18}] if len(buttons) > 1 else [])
        path = self.output / "fold_change_comparison_interactive.html"
        write_plot(fig, path)
        return [path.name, "fold_change_comparisons.tsv"]

    def trend_clustering(self) -> list[str]:
        order = []
        for value in [self.config.get("reference_level"), *(self.config.get("test_levels") or [])]:
            text = str(value or "").strip()
            if text and text not in order:
                order.append(text)
        for value in self.conditions.astype(str):
            if value not in order:
                order.append(value)
        order = [value for value in order if value in set(self.conditions.astype(str))]
        if len(order) < 3:
            raise ValueError("Expression-pattern clustering requires at least three ordered condition levels.")
        matrix = self.preferred_expression
        means = pd.DataFrame(index=matrix.index)
        for condition in order:
            samples = list(self.conditions.index[self.conditions.astype(str).eq(condition)])
            means[condition] = matrix[samples].mean(axis=1)
        variable = means.var(axis=1, ddof=0).sort_values(ascending=False)
        limit = max(50, min(5000, int(self.config.get("advanced_trend_genes") or 1000)))
        means = means.loc[variable.head(min(limit, len(variable))).index]
        scaled, valid = zscore_rows(means.to_numpy(dtype=float))
        means = means.loc[np.asarray(valid)]
        scaled = scaled[valid]
        if len(means) < 20:
            raise ValueError("At least 20 variable genes are required for stable expression-pattern clustering.")
        requested = int(self.config.get("advanced_trend_clusters") or 0)
        clusters = requested if requested >= 2 else min(6, max(2, len(order) + 1))
        clusters = min(clusters, max(2, len(means) // 10))
        fuzzifier = float(self.config.get("advanced_trend_fuzzifier") or 2.0)
        membership, centroids, objective = fuzzy_c_means(scaled, clusters, fuzzifier=fuzzifier)
        assignments = membership.argmax(axis=1)
        strength = membership.max(axis=1)
        assignment_frame = pd.DataFrame({"gene_id": means.index.astype(str), "trend_cluster": assignments + 1, "membership": strength, "ambiguous_membership_below_0.5": strength < 0.5})
        for cluster_index in range(clusters):
            assignment_frame[f"membership_pattern_{cluster_index + 1}"] = membership[:, cluster_index]
        for index, condition in enumerate(order):
            assignment_frame[f"mean_expression__{condition}"] = means.iloc[:, index].to_numpy()
            assignment_frame[f"zscore__{condition}"] = scaled[:, index]
        write_tsv(assignment_frame, self.output / "expression_trend_clusters.tsv")
        condition_mean_frame = means.copy()
        condition_mean_frame.insert(0, "gene_id", condition_mean_frame.index.astype(str))
        condition_mean_frame.reset_index(drop=True, inplace=True)
        write_tsv(condition_mean_frame, self.output / "expression_condition_means.tsv")
        centroid_rows = []
        for cluster_index in range(clusters):
            for condition_index, condition in enumerate(order):
                centroid_rows.append({"trend_cluster": cluster_index + 1, "condition_order": condition_index + 1, "condition": condition, "centroid_zscore": centroids[cluster_index, condition_index], "genes_assigned": int(np.sum(assignments == cluster_index)), "objective": objective, "fuzzifier": fuzzifier})
        write_tsv(pd.DataFrame(centroid_rows), self.output / "expression_trend_centroids.tsv")

        columns = 2
        rows = math.ceil(clusters / columns)
        fig = make_subplots(rows=rows, cols=columns, subplot_titles=[f"Pattern {index + 1} · {int(np.sum(assignments == index))} genes" for index in range(clusters)], horizontal_spacing=0.10, vertical_spacing=max(0.06, 0.14 / rows))
        for cluster_index in range(clusters):
            row = cluster_index // columns + 1
            column = cluster_index % columns + 1
            indices = np.where(assignments == cluster_index)[0]
            strongest = indices[np.argsort(strength[indices])[::-1][: min(100, len(indices))]]
            xs: list[object] = []
            ys: list[object] = []
            custom: list[object] = []
            for gene_index in strongest:
                gene = str(means.index[gene_index])
                xs.extend(order + [None])
                ys.extend(list(scaled[gene_index]) + [None])
                custom.extend([point_selection(gene, cluster_index + 1, condition) for condition in order] + [None])
            if xs:
                fig.add_trace(go.Scattergl(x=xs, y=ys, mode="lines", line={"color": "rgba(85,112,96,0.18)", "width": 1}, customdata=custom, hovertemplate="<b>%{customdata[1]}</b><br>condition: %{x}<br>Z score: %{y:.3g}<br><b>Click to show this gene</b><extra></extra>", showlegend=False), row=row, col=column)
            cluster_genes = assignment_frame.loc[assignment_frame["trend_cluster"].eq(cluster_index + 1), "gene_id"].astype(str).tolist()
            centroid_custom = [selection(f"trend_cluster_{cluster_index + 1}", f"Expression pattern {cluster_index + 1}", cluster_genes) for _condition in order]
            fig.add_trace(go.Scatter(x=order, y=centroids[cluster_index], mode="lines+markers", line={"color": PALETTE[cluster_index % len(PALETTE)], "width": 4}, marker={"size": 9}, customdata=centroid_custom, name=f"Pattern {cluster_index + 1}", hovertemplate="<b>%{customdata[2]}</b><br>condition: %{x}<br>centroid Z score: %{y:.3g}<br>assigned genes: " + str(len(cluster_genes)) + "<br><b>Click to show cluster genes</b><extra></extra>"), row=row, col=column)
            fig.update_xaxes(title_text="Ordered condition", row=row, col=column)
            fig.update_yaxes(title_text="Expression Z score", row=row, col=column)
        fig.update_layout(title=f"Fuzzy expression-pattern clustering · {len(means)} variable genes · m={fuzzifier:g}", height=max(650, rows * 330), showlegend=False)
        path = self.output / "expression_trend_clusters_interactive.html"
        write_plot(fig, path)
        return [path.name, "expression_trend_clusters.tsv", "expression_trend_centroids.tsv", "expression_condition_means.tsv"]

    def finalize_status(self) -> None:
        status_frame = pd.DataFrame(self.status, columns=STATUS_COLUMNS)
        write_tsv(status_frame, self.output / "advanced_de_analysis_status.tsv")
        summary_path = self.output / "analysis_summary.json"
        summary = {}
        if summary_path.is_file():
            try:
                summary = json.loads(summary_path.read_text(encoding="utf-8-sig"))
            except Exception:
                summary = {}
        summary["advanced_exploratory_analyses"] = {
            "reference_basis": ["TOmicsVis (Miao et al., 2023)", "Shiny-Seq (Sundararajan et al., 2019)"],
            "parameters": {
                "correlation_method": str(self.config.get("advanced_correlation_method") or "pearson"),
                "pca_variable_gene_limit": 2000,
                "heatmap_gene_limit": max(20, min(500, int(self.config.get("advanced_heatmap_genes") or 100))),
                "single_gene_choice_limit": max(10, min(200, int(self.config.get("advanced_single_gene_choices") or 100))),
                "trend_gene_limit": max(50, min(5000, int(self.config.get("advanced_trend_genes") or 1000))),
                "trend_cluster_request": int(self.config.get("advanced_trend_clusters") or 0),
                "trend_cluster_auto_rule": "min(6, number of condition levels + 1), then limited to at least 10 genes per cluster",
                "trend_fuzzifier": float(self.config.get("advanced_trend_fuzzifier") or 2.0),
                "trend_random_seed": 173,
                "trend_random_starts": 8,
                "ambiguous_membership_threshold": 0.5,
            },
            "batch_adjusted_visualization": self.adjusted_expression is not None,
            "stages": self.status,
        }
        summary_path.write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    def run(self) -> None:
        stages: list[tuple[str, Callable[[], list[str] | str | None]]] = [
            ("Sample expression distributions", self.sample_distributions),
            ("Sample correlation and hierarchical clustering", self.correlations_and_clustering),
            ("Interactive 3D PCA", self.pca_3d),
            ("Source of variation", self.source_of_variation),
            ("Raw p-value diagnostic", self.pvalue_histogram),
            ("Gene-rank analysis", self.gene_rank),
            ("Top-variable-gene heatmap", self.top_variable_heatmap),
            ("Single-gene expression explorer", self.single_gene_expression),
            ("Multi-contrast overlap (UpSet / Venn)", self.multi_contrast_overlap),
            ("Fold-change versus fold-change", self.fold_change_comparison),
            ("Condition expression-pattern clustering", self.trend_clustering),
        ]
        for name, function in stages:
            self.run_stage(name, function)
        self.finalize_status()


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: advanced_de_analysis.py CONFIG.json", file=sys.stderr)
        return 2
    analysis = AdvancedDE(Path(sys.argv[1]).resolve())
    analysis.run()
    completed = sum(item["status"] == "completed" for item in analysis.status)
    skipped = len(analysis.status) - completed
    print(f"ADVANCED_DE_SUMMARY\tcompleted={completed}\tskipped={skipped}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
