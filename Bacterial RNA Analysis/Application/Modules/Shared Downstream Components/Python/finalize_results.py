#!/usr/bin/env python3
"""Create one Excel-first result package and compact verified intermediates."""
from __future__ import annotations

import json
import math
import os
import re
import shutil
import sys
from pathlib import Path
from typing import Any, Iterable

import pandas as pd
from openpyxl import Workbook, load_workbook
from openpyxl.cell.cell import ILLEGAL_CHARACTERS_RE
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter


EXCEL_MAX_DATA_ROWS = 1_048_575
HEADER_FILL = PatternFill("solid", fgColor="417A4B")
SUBHEADER_FILL = PatternFill("solid", fgColor="E6F2E8")
HEADER_FONT = Font(name="Calibri", size=11, bold=True, color="FFFFFF")
BODY_FONT = Font(name="Calibri", size=11, color="1E2A22")
TITLE_FONT = Font(name="Calibri", size=16, bold=True, color="2A5534")
FAINT_SIDE = Side(style="thin", color="DCE5DF")
FAINT_BORDER = Border(left=FAINT_SIDE, right=FAINT_SIDE, top=FAINT_SIDE, bottom=FAINT_SIDE)


TABLES: dict[str, list[tuple[str, str]]] = {
    "de": [
        ("Differential expression", "differential_expression.tsv"),
        ("All contrasts", "differential_expression_all_contrasts.tsv"),
        ("All contrast rows", "differential_expression_long.tsv"),
        ("Contrast summary", "contrast_manifest.tsv"),
        ("Advanced analysis status", "advanced_de_analysis_status.tsv"),
        ("P-value diagnostic", "de_pvalue_histogram.tsv"),
        ("Gene ranks", "de_gene_rank.tsv"),
        ("DE overlap intersections", "de_overlap_intersections.tsv"),
        ("DE overlap members", "de_overlap_members.tsv"),
        ("Fold-change comparisons", "fold_change_comparisons.tsv"),
        ("Sample expression summary", "sample_expression_distribution.tsv"),
        ("Sample correlations", "sample_correlation_matrix.tsv"),
        ("Sample clustering", "sample_hierarchical_clustering.tsv"),
        ("PCA coordinates", "sample_pca_coordinates.tsv"),
        ("Source of variation", "source_of_variation.tsv"),
        ("Single-gene expression", "single_gene_expression.tsv"),
        ("Top variable expression", "top_variable_gene_expression.tsv"),
        ("Condition means", "expression_condition_means.tsv"),
        ("Expression trend clusters", "expression_trend_clusters.tsv"),
        ("Expression trend centroids", "expression_trend_centroids.tsv"),
        ("Batch-adjusted plot matrix", "batch_corrected_plot_expression.tsv"),
        ("Normalized counts", "normalized_counts.tsv"),
        ("Filtered raw counts", "filtered_raw_counts.tsv"),
        ("Plot expression", "plot_expression_matrix.tsv"),
        ("Sample metadata", "analysis_metadata.tsv"),
        ("IGV track audit", "differential_expression_igv_track_data.tsv"),
    ],
    "enrichment": [
        ("Enrichment results", "enrichment_results.tsv"),
        ("Selected genes", "selected_genes_used.tsv"),
        ("Gene universe", "gene_universe_used.tsv"),
        ("Annotation mapping", "annotation_mapping_used.tsv"),
        ("Leading edge genes", "leading_edge_genes.tsv"),
        ("GSEA ranked metric", "gsea_ranked_metric.tsv"),
        ("GSEA running scores", "gsea_running_score_profiles.tsv"),
        ("Enrichment rich factor", "enrichment_rich_factor.tsv"),
        ("Enrichment circular summary", "enrichment_circos_summary.tsv"),
        ("GO ontology nodes", "go_ontology_nodes.tsv"),
        ("GO ontology edges", "go_ontology_edges.tsv"),
        ("GO DAG focus nodes", "go_dag_focus_nodes.tsv"),
        ("GO level distribution", "go_level_distribution.tsv"),
        ("GO category summary", "go_category_summary.tsv"),
        ("GO gene length annotations", "go_gene_length_annotations.tsv"),
        ("GO semantic clusters", "go_semantic_similarity_clusters.tsv"),
        ("GO semantic matrix", "go_semantic_similarity_matrix.tsv"),
        ("GO cellular components", "go_cellular_component_summary.tsv"),
    ],
    "network": [
        ("Module assignments", "module_assignments.tsv"),
        ("Network edges", "network_edges.tsv"),
        ("Network nodes", "network_nodes.tsv"),
        ("Module eigengenes", "module_eigengenes.tsv"),
        ("Module trait associations", "module_trait_associations.tsv"),
        ("Expression used", "network_expression_used.tsv"),
        ("Sample metadata", "network_metadata_used.tsv"),
        ("Soft threshold diagnostics", "soft_threshold_diagnostics.tsv"),
        ("CEMiTool beta diagnostics", "CEMiTool_beta_diagnostics.tsv"),
        ("Module GO enrichment", "network_module_go_enrichment.tsv"),
        ("Module expression Z scores", "module_expression_zscores.tsv"),
        ("Module expression trends", "module_expression_trends.tsv"),
    ],
}

# The functional workflow executes enrichment and network inference in one job.
# Keep every user-facing table in one verified workbook while retaining the
# original single-module definitions for backward compatibility.
TABLES["combined"] = [
    *TABLES["enrichment"],
    *TABLES["network"],
    ("Pathway enrichment", "pathway_enrichment_results.tsv"),
    ("Pathway gene mapping", "pathway_gene_mapping.tsv"),
    ("STRING PPI edges", "string_ppi_edges.tsv"),
    ("STRING PPI nodes", "string_ppi_nodes.tsv"),
    ("STRING identifier mapping", "string_identifier_mapping.tsv"),
    ("STRING unmapped IDs", "string_unmapped_identifiers.tsv"),
    ("External database status", "integrated_database_status.tsv"),
    ("KEGG map summary", "kegg_map_summary.tsv"),
    ("KEGG mapped genes", "kegg_map_genes.tsv"),
    ("KEGG mapping audit", "kegg_map_audit.tsv"),
    ("KEGG map nodes", "kegg_map_nodes.tsv"),
]

SUMMARY_FILES = {
    "de": "analysis_summary.json",
    "enrichment": "enrichment_summary.json",
    "network": "network_summary.json",
    "combined": "combined_summary.json",
}

AUTOMATIC_FIGURES = {
    "de": {
        "ma_interactive.html",
        "pca_interactive.html",
        "sample_expression_distributions_interactive.html",
        "sample_correlation_interactive.html",
        "sample_dendrogram_interactive.html",
        "sample_pca_3d_interactive.html",
        "source_of_variation_interactive.html",
        "de_pvalue_histogram_interactive.html",
        "de_gene_rank_interactive.html",
        "top_variable_genes_heatmap_interactive.html",
        "single_gene_expression_interactive.html",
        "de_upset_interactive.html",
        "de_venn_interactive.html",
        "fold_change_comparison_interactive.html",
        "expression_trend_clusters_interactive.html",
    },
    "enrichment": {
        "enrichment_bar_interactive.html",
        "enrichment_dot_interactive.html",
        "enrichment_network_interactive.html",
        "gene_term_network_interactive.html",
        "gsea_term_profiles_interactive.html",
        "gsea_multi_term_running_score_interactive.html",
        "gsea_global_es_interactive.html",
        "gsea_nes_significance_interactive.html",
        "enrichment_rich_factor_interactive.html",
        "enrichment_circos_interactive.html",
        "go_dag_interactive.html",
        "go_annotation_landscape_interactive.html",
        "go_semantic_similarity_interactive.html",
        "go_cellular_component_interactive.html",
    },
    "network": {
        "gene_network_interactive.html",
        "module_trait_interactive.html",
        "module_eigengenes_interactive.html",
        "module_expression_heatmap_interactive.html",
        "module_expression_trends_interactive.html",
    },
}
AUTOMATIC_FIGURES["combined"] = AUTOMATIC_FIGURES["enrichment"] | AUTOMATIC_FIGURES["network"]
AUTOMATIC_FIGURES["combined"].update({
    "pathway_enrichment_bar_interactive.html",
    "pathway_enrichment_dot_interactive.html",
    "pathway_enrichment_network_interactive.html",
    "pathway_gene_term_network_interactive.html",
    "string_ppi_gene_network_interactive.html",
})

# These small machine-readable tables are the only TSV files retained after
# workbook verification because another module may consume them directly.
# Every other recognized table is already preserved as a worksheet.
HANDOFF_TABLES = {
    "de": {"differential_expression.tsv", "normalized_counts.tsv", "analysis_metadata.tsv"},
    "enrichment": {"enrichment_results.tsv"},
    "network": {"network_edges.tsv", "network_nodes.tsv", "module_assignments.tsv"},
}
HANDOFF_TABLES["combined"] = HANDOFF_TABLES["enrichment"] | HANDOFF_TABLES["network"]


DE_HANDOFF_FOLDERS = {
    "go": "GO Enrichment and Pathways Input",
    "network": "Co-expression and Networks Input",
    "pathway": "Pathway Database Analysis Input",
    "string": "STRING Protein Associations Input",
}
DE_HANDOFF_CONTAINER = "Inputs for other modules"


def _de_handoff_relative_path(key: str) -> Path:
    return Path(DE_HANDOFF_CONTAINER) / DE_HANDOFF_FOLDERS[key]


def _copy_handoff_file(source: Path | None, destination: Path) -> bool:
    """Copy a handoff input without moving or mutating the original analysis file."""
    if source is None or not source.is_file():
        return False
    destination.parent.mkdir(parents=True, exist_ok=True)
    try:
        if destination.exists() and source.resolve() == destination.resolve():
            return True
    except OSError:
        pass
    shutil.copy2(source, destination)
    print(f"HANDOFF COPY\t{source} -> {destination}")
    return True


def _write_gene_list(frame: pd.DataFrame, destination: Path, *, padj_cutoff: float, lfc_cutoff: float, significant_only: bool) -> int:
    gene_column = next((c for c in ("gene_id", "gene", "Gene", "id", "ID") if c in frame.columns), frame.columns[0] if len(frame.columns) else None)
    if gene_column is None:
        return 0
    work = frame.copy()
    if significant_only:
        padj_column = next((c for c in ("padj", "FDR", "adj.P.Val", "p.adjust") if c in work.columns), None)
        lfc_column = next((c for c in ("log2FoldChange", "logFC", "log2fc") if c in work.columns), None)
        if padj_column is None or lfc_column is None:
            work = work.iloc[0:0]
        else:
            padj = pd.to_numeric(work[padj_column], errors="coerce")
            lfc = pd.to_numeric(work[lfc_column], errors="coerce")
            work = work.loc[padj.le(padj_cutoff) & lfc.abs().ge(lfc_cutoff)].copy()
    genes = work[[gene_column]].copy()
    genes.columns = ["gene_id"]
    genes["gene_id"] = genes["gene_id"].astype("string").str.strip()
    genes = genes.loc[genes["gene_id"].notna() & genes["gene_id"].ne("")].drop_duplicates()
    destination.parent.mkdir(parents=True, exist_ok=True)
    genes.to_csv(destination, sep="\t", index=False)
    return len(genes)


def _copy_reference_support(config: dict[str, Any], config_path: Path, de_table: Path, targets: list[Path]) -> dict[str, Any]:
    """Collect the RNA-processing reference once and copy it into each DE handoff folder.

    The online GO/network annotation code already knows how to discover the original
    RNA-processing reference behind a downstream project. Reuse that discovery here so
    every future-module handoff is self-contained instead of depending on sibling folders.
    """
    report: dict[str, Any] = {"tables": [], "reference_fasta": "", "analysis_gene_fasta": "", "warnings": []}
    try:
        import online_annotation as oa
    except Exception as exc:
        report["warnings"].append(f"Reference discovery helper could not be loaded: {exc}")
        return report

    discovery_cfg = dict(config)
    discovery_cfg["result_file"] = os.fspath(de_table)
    discovery_cfg["expression_file"] = os.fspath(de_table.parent / "normalized_counts.tsv")
    try:
        tables, fastas, _configs = oa.discover_identifier_context("enrichment", discovery_cfg, config_path)
    except Exception as exc:
        report["warnings"].append(f"Reference discovery failed: {exc}")
        return report

    # Prefer the exact coordinate/annotation file used by DE, then compact RNA-processing
    # metadata/GFF/SAF tables found by the shared discovery code. Avoid copying arbitrary
    # unrelated tables from sibling analyses.
    direct_annotation = Path(str(config.get("annotation_file", "")).strip()) if str(config.get("annotation_file", "")).strip() else None
    ordered_tables: list[Path] = []
    if direct_annotation is not None and direct_annotation.is_file():
        ordered_tables.append(direct_annotation)
    ordered_tables.extend(tables)
    seen: set[str] = set()
    selected_tables: list[Path] = []
    allowed_names = {name.casefold() for name in getattr(oa, "REFERENCE_TABLE_NAMES", ())}
    for path in ordered_tables:
        if not path.is_file():
            continue
        key = os.fspath(path.resolve())
        if key in seen:
            continue
        seen.add(key)
        # The explicitly configured DE annotation is always legitimate. Other sources
        # are limited to known compact reference-support filenames.
        if direct_annotation is not None and path.resolve() == direct_annotation.resolve():
            selected_tables.append(path)
        elif path.name.casefold() in allowed_names:
            selected_tables.append(path)

    # Build an identifier bridge/coordinate map to rank candidate FASTAs by whether they
    # can actually reconstruct the genes in this DE result.
    try:
        de_frame = read_table(de_table)
        gene_col = next((c for c in ("gene_id", "gene", "Gene", "id", "ID") if c in de_frame.columns), de_frame.columns[0])
        gene_ids = [str(v).strip() for v in de_frame[gene_col].dropna().tolist() if str(v).strip()]
        gene_ids = list(dict.fromkeys(gene_ids))
        aliases, coordinates, bridge_sources = oa.build_identifier_bridge(gene_ids, selected_tables)
    except Exception as exc:
        gene_ids, aliases, coordinates, bridge_sources = [], {}, {}, []
        report["warnings"].append(f"Identifier bridge could not be prepared for the handoff: {exc}")

    # Copy reference support tables using stable names. Preserve multiple useful tables
    # without allowing basename collisions to silently overwrite each other.
    canonical = {
        "gene_metadata.tsv": "gene metadata.tsv",
        "gene metadata.tsv": "gene metadata.tsv",
        "gene_coordinates.tsv": "gene coordinates.tsv",
        "gene coordinates.tsv": "gene coordinates.tsv",
        "features.saf": "features.saf",
        "annotation.normalized.gff3": "annotation normalized.gff3",
        "annotation.normalized.gff": "annotation normalized.gff",
        "annotation.original.gff3": "annotation original.gff3",
        "annotation.original.gff": "annotation original.gff",
        "annotation.original.gtf": "annotation original.gtf",
    }
    copied_names: set[str] = set()
    for source in selected_tables:
        name = canonical.get(source.name.casefold(), display_filename(source.name))
        if name.casefold() in copied_names:
            continue
        copied_names.add(name.casefold())
        for target in targets:
            _copy_handoff_file(source, target / "Reference support" / name)
        report["tables"].append({"name": name, "source": os.fspath(source)})

    if gene_ids and aliases:
        bridge_rows = []
        source_text = ";".join(bridge_sources)
        for gene in gene_ids:
            bridge_rows.append({"gene_id": gene, "aliases": ";".join(sorted(aliases.get(gene, {gene}))), "bridge_sources": source_text})
        bridge_frame = pd.DataFrame(bridge_rows)
        for target in targets:
            bridge_path = target / "Reference support" / "identifier bridge.tsv"
            bridge_path.parent.mkdir(parents=True, exist_ok=True)
            bridge_frame.to_csv(bridge_path, sep="\t", index=False)

    # Test candidate FASTAs by real coordinate reconstruction; this prevents a nearby
    # unrelated genome from being copied when several projects live under one parent.
    best_fasta: Path | None = None
    best_count = -1
    best_sequence_tmp: Path | None = None
    scratch = de_table.parent / ".handoff reference test.fasta"
    if gene_ids and coordinates:
        for fasta in fastas:
            if not fasta.is_file():
                continue
            try:
                scratch.unlink(missing_ok=True)
                _records, found = oa.extract_reference_gene_queries(fasta, gene_ids, coordinates, scratch)
                count = len(found)
            except Exception:
                count = 0
            if count > best_count:
                best_count = count
                best_fasta = fasta
                if scratch.is_file():
                    best_sequence_tmp = de_table.parent / ".handoff best gene sequences.fasta"
                    shutil.copy2(scratch, best_sequence_tmp)
            if count == len(gene_ids) and count > 0:
                break
        scratch.unlink(missing_ok=True)
    elif fastas:
        best_fasta = next((p for p in fastas if p.is_file()), None)

    if best_fasta is not None and best_fasta.is_file():
        for target in targets:
            _copy_handoff_file(best_fasta, target / "Reference support" / "reference.fasta")
        report["reference_fasta"] = os.fspath(best_fasta)
    else:
        report["warnings"].append("No retained reference FASTA could be confidently attached to the DE handoff.")

    if best_sequence_tmp is not None and best_sequence_tmp.is_file() and best_count > 0:
        for target in targets:
            _copy_handoff_file(best_sequence_tmp, target / "Reference support" / "analysis gene sequences.fasta")
        report["analysis_gene_fasta"] = f"{best_count} genes reconstructed from retained reference"
        best_sequence_tmp.unlink(missing_ok=True)

    return report


def create_de_downstream_handoffs(config: dict[str, Any], output_dir: Path, config_path: Path) -> None:
    """Create self-contained, module-specific input folders after DE finishes."""
    de_table = output_dir / "differential_expression.tsv"
    normalized = output_dir / "normalized_counts.tsv"
    metadata = output_dir / "analysis_metadata.tsv"
    if not de_table.is_file():
        return

    handoff_root = output_dir / DE_HANDOFF_CONTAINER
    handoff_root.mkdir(parents=True, exist_ok=True)
    folders = {key: output_dir / _de_handoff_relative_path(key) for key in DE_HANDOFF_FOLDERS}
    for folder in folders.values():
        if folder.exists():
            shutil.rmtree(folder)
        folder.mkdir(parents=True, exist_ok=True)

    padj_cutoff = float(config.get("padj_cutoff", 0.05))
    lfc_cutoff = float(config.get("lfc_cutoff", 1.0))
    de_frame = read_table(de_table)

    # GO / enrichment receives the complete DE result and explicit tested-gene universe.
    _copy_handoff_file(de_table, folders["go"] / "differential expression.tsv")
    _write_gene_list(de_frame, folders["go"] / "gene universe.tsv", padj_cutoff=padj_cutoff, lfc_cutoff=lfc_cutoff, significant_only=False)
    sig_count = _write_gene_list(de_frame, folders["go"] / "significant genes.tsv", padj_cutoff=padj_cutoff, lfc_cutoff=lfc_cutoff, significant_only=True)

    # Co-expression uses all appropriately normalized genes, not only DEGs.
    _copy_handoff_file(normalized, folders["network"] / "normalized counts.tsv")
    _copy_handoff_file(metadata, folders["network"] / "sample metadata.tsv")
    _copy_handoff_file(de_table, folders["network"] / "differential expression reference.tsv")

    # Pathway ORA and STRING are gene-list consumers, so prebuild the DE-selected set.
    _write_gene_list(de_frame, folders["pathway"] / "selected genes.tsv", padj_cutoff=padj_cutoff, lfc_cutoff=lfc_cutoff, significant_only=True)
    _write_gene_list(de_frame, folders["pathway"] / "all tested genes.tsv", padj_cutoff=padj_cutoff, lfc_cutoff=lfc_cutoff, significant_only=False)
    _copy_handoff_file(de_table, folders["pathway"] / "differential expression reference.tsv")
    _write_gene_list(de_frame, folders["string"] / "selected genes.tsv", padj_cutoff=padj_cutoff, lfc_cutoff=lfc_cutoff, significant_only=True)
    _copy_handoff_file(de_table, folders["string"] / "differential expression reference.tsv")

    # Preserve every contrast as a ready-to-use DE table/gene list when multi-contrast
    # analysis was requested. The primary files above still correspond to the first
    # reported contrast for backward compatibility.
    contrast_dir = output_dir / "contrasts"
    if contrast_dir.is_dir():
        for contrast_file in sorted(contrast_dir.glob("*.tsv")):
            try:
                contrast_frame = read_table(contrast_file)
            except Exception:
                continue
            safe = display_filename(contrast_file.stem) or "contrast"
            _copy_handoff_file(contrast_file, folders["go"] / "Contrasts" / f"{safe}.tsv")
            for key in ("pathway", "string"):
                _write_gene_list(contrast_frame, folders[key] / "Contrasts" / f"{safe} selected genes.tsv", padj_cutoff=padj_cutoff, lfc_cutoff=lfc_cutoff, significant_only=True)

    # Attach the RNA-processing reference/identifier context to every folder. This is
    # especially important for local bacterial locus tags used by GO and STRING.
    reference_report = _copy_reference_support(config, config_path, de_table, [folders["go"], folders["network"]])

    manifest = {
        "schema_version": 1,
        "source_analysis": os.fspath(output_dir),
        "de_engine": config.get("engine", ""),
        "significance_rule": {"adjusted_p_value_lte": padj_cutoff, "absolute_log2_fold_change_gte": lfc_cutoff},
        "primary_significant_gene_count": sig_count,
        "reference_support": reference_report,
        "modules": {
            "GO Enrichment and Pathways": {"folder": os.fspath(_de_handoff_relative_path("go")), "primary_input": "differential expression.tsv", "universe": "gene universe.tsv"},
            "Co-expression and Networks": {"folder": os.fspath(_de_handoff_relative_path("network")), "expression": "normalized counts.tsv", "metadata": "sample metadata.tsv"},
            "Pathway Database Analysis": {"folder": os.fspath(_de_handoff_relative_path("pathway")), "selected_genes": "selected genes.tsv", "universe": "all tested genes.tsv", "reference_support_required": False},
            "STRING Protein Associations": {"folder": os.fspath(_de_handoff_relative_path("string")), "genes": "selected genes.tsv", "reference_support_required": False},
        },
    }
    for key, folder in folders.items():
        (folder / "handoff manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    readmes = {
        "go": "Use 'differential expression.tsv' as the DE result table and 'gene universe.tsv' as the optional custom universe. Reference support is bundled for online identifier/sequence annotation.\n",
        "network": "Use 'normalized counts.tsv' as the expression matrix and 'sample metadata.tsv' as metadata. Build co-expression from all normalized genes rather than only significant DEGs. Reference support is bundled for online functional annotation.\n",
        "pathway": "Use 'selected genes.tsv' as the selected list and 'all tested genes.tsv' as the required background/universe. Then choose KEGG, TERM2GENE, BioCyc, or MetaCyc inside Pathway Database Analysis. No genome/reference copy is required by this module.\n",
        "string": "Use 'selected genes.tsv' as the STRING gene/protein list. Confirm the organism/taxonomy ID in STRING Protein Associations before retrieval. If a co-expression network is produced later, its edge table can be added as the optional expression-network layer. No genome/reference copy is required by this module.\n",
    }
    for key, text in readmes.items():
        (folders[key] / "README.txt").write_text(text, encoding="utf-8")

    print(f"DE_HANDOFFS\tCreated {DE_HANDOFF_CONTAINER}: " + ", ".join(DE_HANDOFF_FOLDERS.values()))


def load_config(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8-sig") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError("The downstream configuration must be a JSON object.")
    return value


def workbook_name(mode: str, config: dict[str, Any]) -> str:
    if mode == "de":
        labels = {"deseq2": "DESeq2", "edger": "edgeR", "limma": "limma-voom", "limma-voom": "limma-voom", "voom": "limma-voom"}
        engine = labels.get(str(config.get("engine", "")).lower(), "Differential expression")
        return f"{engine} analysis results.xlsx"
    if mode == "enrichment":
        return "GO analysis results.xlsx"
    if mode == "combined":
        return "Functional enrichment and co-expression results.xlsx"
    return "Co-expression analysis results.xlsx"


def display_filename(value: str) -> str:
    """Return the user-facing filename without underscore separators."""
    return re.sub(r"\s+", " ", value.replace("_", " ")).strip()


def clean_cell(value: Any) -> Any:
    if value is None:
        return None
    try:
        if pd.isna(value):
            return None
    except Exception:
        pass
    if hasattr(value, "item"):
        try:
            value = value.item()
        except Exception:
            pass
    if isinstance(value, float) and (math.isnan(value) or math.isinf(value)):
        return None
    if isinstance(value, str):
        value = ILLEGAL_CHARACTERS_RE.sub("", value)
        # Prevent a gene identifier or annotation beginning with '=' from being
        # interpreted as an Excel formula.
        if value.startswith("="):
            value = "'" + value
    return value


def read_table(path: Path) -> pd.DataFrame:
    headers = list(pd.read_csv(path, sep="\t", nrows=0).columns)
    text_names = {
        "gene_id", "sample_id", "term_id", "id", "source", "target", "module",
        "trait", "method", "description", "geneid", "leadingedge", "node_type",
        "edge_type", "seqid", "status", "condition", "batch",
    }
    text_columns = {
        name: "string"
        for name in headers
        if name.lower() in text_names or name.lower().endswith("_id")
    }
    return pd.read_csv(path, sep="\t", dtype=text_columns, low_memory=False)


def safe_sheet_name(value: str) -> str:
    value = re.sub(r"[\\/*?:\[\]]", "-", value).strip() or "Results"
    return value[:31]


def unique_sheet_name(workbook: Workbook, requested: str) -> str:
    base = safe_sheet_name(requested)
    candidate = base
    index = 2
    while candidate in workbook.sheetnames:
        suffix = f" {index}"
        candidate = base[: 31 - len(suffix)] + suffix
        index += 1
    return candidate


def style_data_sheet(sheet, widths: list[int]) -> None:
    sheet.freeze_panes = "A2"
    if sheet.max_column and sheet.max_row:
        sheet.auto_filter.ref = sheet.dimensions
    sheet.sheet_view.showGridLines = False
    for cell in sheet[1]:
        cell.fill = HEADER_FILL
        cell.font = HEADER_FONT
        cell.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)
        cell.border = FAINT_BORDER
    sheet.row_dimensions[1].height = 30
    for index, width in enumerate(widths, start=1):
        sheet.column_dimensions[get_column_letter(index)].width = min(48, max(10, width + 2))
    for row in sheet.iter_rows(min_row=2):
        for cell in row:
            cell.font = BODY_FONT
            cell.alignment = Alignment(vertical="top")
            cell.border = FAINT_BORDER
            if isinstance(cell.value, float):
                cell.number_format = "0.0000E+00" if cell.value and abs(cell.value) < 0.0001 else "0.0000"


def user_facing_frame(mode: str, frame: pd.DataFrame) -> pd.DataFrame:
    """Remove technical-only columns from the user-facing workbook.

    lfcSE is the standard error of log2 fold change. It is useful for advanced
    DESeq2/limma uncertainty inspection but is not required by the interactive
    plots or normal DEG/GO handoff. Keep it in machine-readable technical
    results when produced, but do not clutter the linked Excel workbook.
    """
    if mode != "de":
        return frame
    drop = [
        column for column in frame.columns
        if re.fullmatch(r"lfcSE(?:__.*)?", str(column), flags=re.IGNORECASE)
    ]
    return frame.drop(columns=drop, errors="ignore")


def write_frame(workbook: Workbook, title: str, frame: pd.DataFrame) -> None:
    columns = [str(column) for column in frame.columns]
    chunks = max(1, math.ceil(len(frame) / EXCEL_MAX_DATA_ROWS))
    for chunk_index in range(chunks):
        start = chunk_index * EXCEL_MAX_DATA_ROWS
        stop = min(len(frame), start + EXCEL_MAX_DATA_ROWS)
        suffix = f" {chunk_index + 1}" if chunks > 1 else ""
        sheet = workbook.create_sheet(unique_sheet_name(workbook, title + suffix))
        sheet.append(columns)
        widths = [len(column) for column in columns]
        for values in frame.iloc[start:stop].itertuples(index=False, name=None):
            cleaned = [clean_cell(value) for value in values]
            sheet.append(cleaned)
            for index, value in enumerate(cleaned):
                if value is not None:
                    widths[index] = max(widths[index], min(46, len(str(value))))
        style_data_sheet(sheet, widths)


def flatten(prefix: str, value: Any) -> Iterable[tuple[str, Any]]:
    if isinstance(value, dict):
        for key, child in value.items():
            name = f"{prefix}.{key}" if prefix else str(key)
            yield from flatten(name, child)
    elif isinstance(value, list):
        yield prefix, ", ".join(str(item) for item in value)
    else:
        yield prefix, value


def add_summary_sheet(workbook: Workbook, mode: str, config: dict[str, Any], summary: dict[str, Any]) -> None:
    sheet = workbook.active
    sheet.title = "Run summary"
    sheet.sheet_view.showGridLines = False
    title = {
        "de": "Differential expression analysis results",
        "enrichment": "GO, enrichment and pathway analysis results",
        "network": "Co-expression and network analysis results",
        "combined": "Integrated functional, pathway and biological-network results",
    }[mode]
    sheet.merge_cells("A1:B1")
    sheet["A1"] = title
    sheet["A1"].font = TITLE_FONT
    sheet["A1"].alignment = Alignment(vertical="center")
    sheet.row_dimensions[1].height = 30
    sheet["A3"] = "Setting"
    sheet["B3"] = "Value"
    for cell in sheet[3]:
        cell.fill = HEADER_FILL
        cell.font = HEADER_FONT
        cell.alignment = Alignment(horizontal="center")
        cell.border = FAINT_BORDER
    rows = list(flatten("result", summary)) + list(flatten("configuration", config))
    for key, value in rows:
        sheet.append([clean_cell(key), clean_cell(value)])
    for row in sheet.iter_rows(min_row=4):
        row[0].font = Font(name="Calibri", size=11, bold=True, color="2A5534")
        row[0].fill = SUBHEADER_FILL
        row[1].font = BODY_FONT
        for cell in row:
            cell.alignment = Alignment(vertical="top", wrap_text=True)
            cell.border = FAINT_BORDER
    sheet.column_dimensions["A"].width = 42
    sheet.column_dimensions["B"].width = 90
    sheet.freeze_panes = "A4"


def move_replace(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        if destination.is_dir():
            shutil.rmtree(destination)
        else:
            destination.unlink()
    print(f"CLEANUP CODE\tshutil.move({os.fspath(source)!r}, {os.fspath(destination)!r})")
    shutil.move(os.fspath(source), os.fspath(destination))


def create_workbook(mode: str, config: dict[str, Any], output_dir: Path) -> Path:
    primary_names = {
        "de": "differential_expression.tsv",
        "enrichment": "enrichment_results.tsv",
        "network": "network_edges.tsv",
        "combined": ("enrichment_results.tsv", "network_edges.tsv"),
    }[mode]
    if isinstance(primary_names, str):
        primary_names = (primary_names,)
    missing_primary = [name for name in primary_names if not (output_dir / name).is_file()]
    if missing_primary:
        raise FileNotFoundError(
            "Primary analysis result(s) missing: "
            + ", ".join(os.fspath(output_dir / name) for name in missing_primary)
        )
    summary: dict[str, Any] = {}
    if mode == "combined":
        for label, filename in (
            ("enrichment", "enrichment_summary.json"),
            ("network", "network_summary.json"),
            ("pathway_and_string", "integrated_external_summary.json"),
        ):
            path = output_dir / filename
            if not path.is_file():
                continue
            try:
                summary[label] = json.loads(path.read_text(encoding="utf-8-sig"))
            except Exception:
                summary[label] = {}
    else:
        summary_path = output_dir / SUMMARY_FILES[mode]
        if summary_path.is_file():
            try:
                summary = json.loads(summary_path.read_text(encoding="utf-8-sig"))
            except Exception:
                summary = {}

    workbook = Workbook()
    workbook.properties.creator = "Bacterial RNA Analysis"
    workbook.properties.title = workbook_name(mode, config).removesuffix(".xlsx").replace("_", " ")
    add_summary_sheet(workbook, mode, config, summary)

    loaded: dict[str, pd.DataFrame] = {}
    for title, filename in TABLES[mode]:
        path = output_dir / filename
        if not path.is_file():
            continue
        frame = user_facing_frame(mode, read_table(path))
        loaded[filename] = frame
        write_frame(workbook, title, frame)

    if mode == "de":
        manifest_path = output_dir / "contrast_manifest.tsv"
        contrasts_dir = output_dir / "contrasts"
        if manifest_path.is_file() and contrasts_dir.is_dir():
            try:
                manifest = read_table(manifest_path)
            except Exception:
                manifest = pd.DataFrame()
            if not manifest.empty and {"contrast", "file"}.issubset(manifest.columns):
                for _, row in manifest.iterrows():
                    relative = str(row.get("file", "")).strip()
                    contrast = str(row.get("contrast", "Contrast")).strip() or "Contrast"
                    if not relative:
                        continue
                    contrast_path = output_dir / relative
                    if not contrast_path.is_file():
                        continue
                    frame = user_facing_frame(mode, read_table(contrast_path))
                    write_frame(workbook, f"DE {contrast}", frame)

    functional_annotation_dir = output_dir / ("Gene-to-term mapping (online)" if mode == "enrichment" else "Functional annotation")
    for title, path in (
        ("Gene annotations", functional_annotation_dir / "gene_annotations.tsv"),
        ("Online GO mapping", functional_annotation_dir / "gene_to_go.tsv"),
        ("Identifier bridge", functional_annotation_dir / "identifier_bridge.tsv"),
        ("Unmatched genes", functional_annotation_dir / "unmatched_genes.tsv"),
    ):
        if path.is_file():
            write_frame(workbook, title, read_table(path))

    if mode == "de" and "differential_expression.tsv" in loaded:
        result = loaded["differential_expression.tsv"].copy()
        padj_column = next((name for name in ("padj", "FDR", "adj.P.Val", "p.adjust") if name in result.columns), None)
        lfc_column = next((name for name in ("log2FoldChange", "logFC", "log2fc") if name in result.columns), None)
        if padj_column and lfc_column:
            padj = pd.to_numeric(result[padj_column], errors="coerce")
            lfc = pd.to_numeric(result[lfc_column], errors="coerce")
            cutoff = float(config.get("padj_cutoff", 0.05))
            lfc_cutoff = float(config.get("lfc_cutoff", 1.0))
            significant = result.loc[padj.le(cutoff) & lfc.abs().ge(lfc_cutoff)].copy()
            write_frame(workbook, "Significant genes", significant)

    target = output_dir / workbook_name(mode, config)
    temporary = target.with_suffix(".xlsx.tmp")
    workbook.save(temporary)
    try:
        os.replace(temporary, target)
    except PermissionError as exc:
        temporary.unlink(missing_ok=True)
        raise RuntimeError(
            f"Close the existing Excel workbook before rerunning this analysis: {target}"
        ) from exc
    verification = load_workbook(target, read_only=True, data_only=False)
    try:
        required_sheets = {"Run summary"}
        required_sheets.update(
            safe_sheet_name(title)
            for title, filename in TABLES[mode]
            if filename in loaded
        )
        missing = sorted(required_sheets.difference(verification.sheetnames))
        if missing:
            raise RuntimeError(
                f"Excel verification failed for {target}; missing worksheet(s): {', '.join(missing)}"
            )
    finally:
        verification.close()
    return target


def organize_files(mode: str, output_dir: Path, config_path: Path) -> None:
    if mode == "de":
        config = load_config(config_path)
        create_de_downstream_handoffs(config, output_dir, config_path)

    figures = output_dir / "Figures"
    bedgraph_dir = output_dir / "BedGraph"
    technical = output_dir / "Intermediate files"
    technical.mkdir(exist_ok=True)

    # Purpose-built figures are retained together because the unified report
    # embeds them in its analysis selector. Publication exports are still
    # downloaded directly by the browser.
    figures.mkdir(exist_ok=True)
    for name in sorted(AUTOMATIC_FIGURES[mode]):
        path = output_dir / name
        if not path.is_file():
            continue
        move_replace(path, figures / display_filename(path.name))
    plotly_bundle = output_dir / "plotly.min.js"
    if plotly_bundle.is_file():
        move_replace(plotly_bundle, figures / display_filename(plotly_bundle.name))

    if mode == "de":
        bedgraphs = sorted(output_dir.glob("differential_expression*.bedgraph"))
        if bedgraphs:
            bedgraph_dir.mkdir(exist_ok=True)
        for path in bedgraphs:
            move_replace(path, bedgraph_dir / display_filename(path.name))

        # Migrate the old Interactive subfolder layout.  The self-contained
        # DE HTML report now lives beside the Excel workbook at the analysis root.
        legacy_interactive = output_dir / "Interactive"
        legacy_report = legacy_interactive / "Differential expression interactive.html"
        root_report = output_dir / "Differential expression interactive.html"
        if legacy_report.is_file() and not root_report.exists():
            move_replace(legacy_report, root_report)
        if legacy_interactive.is_dir() and not any(legacy_interactive.iterdir()):
            legacy_interactive.rmdir()

        # New DE runs keep only scientifically generated figures; legacy empty
        # IGV and User exports folders remain unnecessary.
        for legacy_name in ("IGV", "User exports"):
            legacy = output_dir / legacy_name
            if legacy.is_dir() and not any(legacy.iterdir()):
                legacy.rmdir()

        contrasts_dir = output_dir / "contrasts"
        if contrasts_dir.is_dir():
            move_replace(contrasts_dir, technical / "Contrasts")

    for _, filename in TABLES[mode]:
        path = output_dir / filename
        if path.is_file():
            if filename in HANDOFF_TABLES[mode]:
                destination = technical / display_filename(path.name)
                move_replace(path, destination)
            else:
                print(f"CLEANUP CODE\tPath.unlink({os.fspath(path)!r})")
                path.unlink()

    technical_names = {
        SUMMARY_FILES[mode],
        "R_session_info.txt",
        "model_diagnostics.txt",
        "CEMiTool_no_modules.txt",
    }
    if mode == "combined":
        technical_names.update({"enrichment_summary.json", "network_summary.json", "integrated_external_summary.json"})
    for name in technical_names:
        path = output_dir / name
        if path.is_file():
            move_replace(path, technical / display_filename(path.name))

    # Configurations are created in Intermediate files for new runs. Migrate a
    # legacy root-level or Technical details configuration when encountered.
    legacy_technical = output_dir / "Technical details"
    if config_path.is_file() and config_path.parent in {output_dir, legacy_technical, technical}:
        destination = technical / display_filename(config_path.name)
        if config_path != destination:
            move_replace(config_path, destination)
    if legacy_technical.is_dir() and not any(legacy_technical.iterdir()):
        legacy_technical.rmdir()


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: finalize_results.py MODE CONFIG.json", file=sys.stderr)
        return 2
    mode = sys.argv[1].lower()
    if mode not in TABLES:
        raise ValueError(f"Unknown downstream mode: {mode}")
    config_path = Path(sys.argv[2]).resolve()
    config = load_config(config_path)
    output_dir = Path(str(config["output_dir"])).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    workbook = create_workbook(mode, config, output_dir)
    organize_files(mode, output_dir, config_path)
    print(f"WORKBOOK\t{workbook}")
    print(f"EXCEL_VERIFIED\t{workbook.name}\tprimary user-facing result")
    if mode == "de":
        print(f"OUTPUT_LAYOUT\tExcel workbook and unified offline interactive HTML report at the analysis root; purpose-built exploratory plots under Figures; DE bedGraph tracks under BedGraph; module-specific handoff folders grouped under {DE_HANDOFF_CONTAINER}; provenance files under Intermediate files.")
    elif mode == "combined":
        print("OUTPUT_LAYOUT\tOne combined Excel workbook and one combined offline interactive HTML report at the analysis root; GO, co-expression, pathway, and STRING figures grouped together; only essential handoff and provenance files retained in Intermediate files.")
    else:
        print("OUTPUT_LAYOUT\tExcel workbook at the analysis root; figures grouped separately; only essential handoff and provenance files retained in Intermediate files.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
