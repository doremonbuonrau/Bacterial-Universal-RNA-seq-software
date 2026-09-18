#!/usr/bin/env python3
"""Interactive visualization for bacterial RNA-seq result tables.

Normal downstream runs build one self-contained offline HTML report with embedded
result data and Plotly.js, so users can double-click the report without starting
a local server. The legacy localhost server remains available for compatibility.
"""
from __future__ import annotations

import argparse
import base64
import csv
import html
import io
import json
import math
import mimetypes
import os
import re
import signal
import socket
import sys
import tempfile
import threading
import time
import traceback
import urllib.parse
from dataclasses import dataclass
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

import pandas as pd
import plotly.offline as py_offline
import plotly.io as pio
try:
    from PIL import Image
except Exception as exc:  # pragma: no cover - checked during environment validation
    Image = None
    PIL_IMPORT_ERROR = str(exc)
else:
    PIL_IMPORT_ERROR = ""

try:
    import cairosvg
except Exception as exc:  # pragma: no cover - checked during environment validation
    cairosvg = None
    CAIROSVG_IMPORT_ERROR = str(exc)
else:
    CAIROSVG_IMPORT_ERROR = ""

APP_VERSION = "1.9.77"
MAX_JSON_BYTES = 120 * 1024 * 1024
MAX_ROWS_DEFAULT = 50_000
MAX_ROWS_HARD = 200_000
MAX_EXPORT_PIXELS = 160_000_000
MAX_EXPORT_DIMENSION = 32_000
MAX_DPI = 2400

PAPER_MM: dict[str, tuple[float, float]] = {
    "A0": (841.0, 1189.0),
    "A1": (594.0, 841.0),
    "A2": (420.0, 594.0),
    "A3": (297.0, 420.0),
    "A4": (210.0, 297.0),
    "A5": (148.0, 210.0),
    "Letter": (215.9, 279.4),
    "Legal": (215.9, 355.6),
    "Square": (210.0, 210.0),
}

MODULE_TITLES = {
    "de": "Differential Expression Visualization Studio",
    "enrichment": "GO, Enrichment and Pathways Visualization Studio",
    "network": "Co-expression and Network Visualization Studio",
    "combined": "Functional Enrichment and Co-expression Network Studio",
}

PREFERRED_FILES = {
    "de": [
        "differential_expression.tsv",
        "normalized_counts.tsv",
        "filtered_raw_counts.tsv",
        "plot_expression_matrix.tsv",
        "analysis_metadata.tsv",
        "filtered_counts.tsv",
        "sample_metadata.tsv",
        "metadata.tsv",
        "gene_coordinates.tsv",
    ],
    "enrichment": [
        "enrichment_results.tsv",
        "leading_edge_genes.tsv",
        "gsea_ranked_metric.tsv",
        "gsea_running_score_profiles.tsv",
        "term_gene_membership.tsv",
        "differential_expression.tsv",
    ],
    "network": [
        "network_edges.tsv",
        "network_nodes.tsv",
        "module_trait_associations.tsv",
        "module_eigengenes.tsv",
        "module_expression_zscores.tsv",
        "module_expression_trends.tsv",
        "module_membership.tsv",
        "normalized_expression.tsv",
    ],
    "combined": [
        "enrichment_results.tsv",
        "network_edges.tsv",
        "module_trait_associations.tsv",
        "module_expression_zscores.tsv",
        "module_expression_trends.tsv",
        "pathway_enrichment_results.tsv",
        "pathway_gene_mapping.tsv",
        "string_ppi_edges.tsv",
        "string_ppi_nodes.tsv",
        "integrated_database_status.tsv",
    ],
}

CONFIG_INPUT_KEYS = {
    "de": ["count_file", "metadata_file", "coordinate_file"],
    "enrichment": ["result_file", "mapping_file", "universe_file"],
    "network": ["expression_file", "metadata_file", "regulator_file"],
    "combined": ["result_file", "mapping_file", "universe_file", "expression_file", "metadata_file", "regulator_file"],
}

PREFERRED_WORKBOOK_SHEETS = {
    "de": ["Differential expression", "All contrasts", "All contrast rows", "Contrast summary", "Significant genes", "Advanced analysis status", "P-value diagnostic", "Gene ranks", "DE overlap intersections", "DE overlap members", "Fold-change comparisons", "Sample expression summary", "Sample correlations", "Sample clustering", "PCA coordinates", "Source of variation", "Single-gene expression", "Top variable expression", "Condition means", "Expression trend clusters", "Expression trend centroids", "Normalized counts", "Sample metadata", "Run summary"],
    "enrichment": ["Enrichment results", "Enrichment rich factor", "Enrichment circular summary", "GO DAG focus nodes", "GO level distribution", "GO category summary", "GO gene length annotations", "GO semantic clusters", "GO semantic matrix", "GO cellular components", "Selected genes", "Leading edge genes", "GSEA ranked metric", "GSEA running scores", "Gene universe", "Run summary"],
    "network": ["Network edges", "Network nodes", "Module assignments", "Module trait associations", "Module expression Z scores", "Module expression trends", "Run summary"],
    "combined": ["Enrichment results", "Network edges", "Module trait associations", "Module expression Z scores", "Module expression trends", "Pathway enrichment", "Pathway gene mapping", "STRING PPI edges", "STRING PPI nodes", "STRING identifier mapping", "STRING unmapped IDs", "External database status"],
}

# Native KEGG maps share the Functional/GO spreadsheet and figure selector.
for _module in ("enrichment", "combined"):
    PREFERRED_FILES[_module].extend(["kegg_map_summary.tsv", "kegg_map_genes.tsv", "kegg_map_audit.tsv", "kegg_map_nodes.tsv"])
    PREFERRED_WORKBOOK_SHEETS[_module].extend(["KEGG map summary", "KEGG mapped genes", "KEGG mapping audit", "KEGG map nodes"])


def natural_key(value: str) -> list[Any]:
    return [int(part) if part.isdigit() else part.casefold() for part in re.split(r"(\d+)", value)]


def _first_named_column(frame: pd.DataFrame, names: tuple[str, ...]) -> str | None:
    lookup = {re.sub(r"[^a-z0-9]+", "", str(column).casefold()): str(column) for column in frame.columns}
    for name in names:
        hit = lookup.get(re.sub(r"[^a-z0-9]+", "", name.casefold()))
        if hit is not None:
            return hit
    return None


def _normalize_strand_series(values: pd.Series) -> pd.Series:
    """Normalize common strand encodings without inventing a direction."""

    def normalize(value: object) -> str:
        text = str(value or "").strip().casefold().replace("−", "-").replace("–", "-")
        if text in {"+", "plus", "forward", "fwd", "1", "1.0"}:
            return "+"
        if text in {"-", "minus", "reverse", "rev", "-1", "-1.0"}:
            return "-"
        return "."

    return values.map(normalize)


def _coordinate_frame_from_table(frame: pd.DataFrame) -> pd.DataFrame | None:
    if frame.empty:
        return None
    gene = _first_named_column(frame, ("gene_id", "GeneID", "Geneid", "locus_tag", "gene", "ID", "name"))
    seq = _first_named_column(frame, ("seqid", "contig", "Chr", "chrom", "chromosome", "replicon"))
    start = _first_named_column(frame, ("start", "Start", "start_1based", "gene_start"))
    end = _first_named_column(frame, ("end", "End", "end_1based", "gene_end"))
    chrom_start = _first_named_column(frame, ("chromStart", "chrom_start", "bed_start"))
    chrom_end = _first_named_column(frame, ("chromEnd", "chrom_end", "bed_end"))
    strand = _first_named_column(frame, ("strand", "Strand", "orientation"))
    if gene is None or seq is None or (start is None and chrom_start is None) or (end is None and chrom_end is None):
        return None
    out = pd.DataFrame({"__gene_key": frame[gene].astype(str).str.strip(), "seqid": frame[seq].astype(str).str.strip()})
    if start is not None:
        out["start"] = pd.to_numeric(frame[start], errors="coerce")
    else:
        out["start"] = pd.to_numeric(frame[chrom_start], errors="coerce") + 1
    if end is not None:
        out["end"] = pd.to_numeric(frame[end], errors="coerce")
    else:
        out["end"] = pd.to_numeric(frame[chrom_end], errors="coerce")
    out["strand"] = _normalize_strand_series(frame[strand]) if strand is not None else "."
    out = out.dropna(subset=["start", "end"])
    out = out[(out["__gene_key"] != "") & (out["seqid"] != "") & (out["end"] >= out["start"])]
    if out.empty:
        return None
    out["start"] = out["start"].astype(int)
    out["end"] = out["end"].astype(int)
    out = out.sort_values(["seqid", "start", "end", "__gene_key"], kind="stable").drop_duplicates("__gene_key", keep="first")
    out["chromStart"] = out["start"] - 1
    out["chromEnd"] = out["end"]
    return out


_COORDINATE_SOURCE_CACHE: dict[str, list[tuple[int, pd.DataFrame]]] = {}


def _coordinate_candidates_for_source(source_path: Path) -> list[tuple[int, pd.DataFrame]]:
    """Load plausible coordinate tables once without recursively scanning a drive.

    Earlier builds searched several ancestors with ``rglob`` every time a worksheet
    was read.  A DE workbook with many sheets could therefore rescan an entire
    Windows drive dozens of times while the GUI appeared stuck at
    "Building offline interactive HTML report...".  Coordinate discovery is now
    bounded to the workbook, its DE configuration, and explicit/sibling reference
    files, and the result is cached for the lifetime of the builder process.
    """
    try:
        resolved_source = source_path.resolve()
    except OSError:
        resolved_source = source_path
    cache_key = str(resolved_source)
    cached = _COORDINATE_SOURCE_CACHE.get(cache_key)
    if cached is not None:
        return cached

    loaded: list[tuple[int, pd.DataFrame]] = []
    seen_paths: set[Path] = set()

    def add_frame(frame: pd.DataFrame | None, priority: int) -> None:
        coords = _coordinate_frame_from_table(frame) if frame is not None else None
        if coords is not None and not coords.empty:
            loaded.append((priority, coords))

    def add_path(path: Path, priority: int) -> None:
        try:
            resolved = path.expanduser().resolve()
        except OSError:
            return
        if resolved == resolved_source or resolved in seen_paths or not resolved.is_file():
            return
        seen_paths.add(resolved)
        try:
            suffix = resolved.suffix.lower()
            if suffix in {'.xlsx', '.xlsm'}:
                book = pd.ExcelFile(resolved, engine='openpyxl')
                for sheet in book.sheet_names:
                    if not re.search(r'igv|coordinate|annotation', str(sheet), re.I):
                        continue
                    try:
                        add_frame(book.parse(sheet_name=sheet), priority)
                    except Exception:
                        continue
            else:
                sep = ',' if suffix == '.csv' else '\t'
                try:
                    frame = pd.read_csv(resolved, sep=sep, low_memory=False)
                except Exception:
                    frame = pd.read_csv(resolved, sep=None, engine='python', low_memory=False)
                add_frame(frame, priority)
        except Exception:
            return

    # The user-facing workbook may contain an IGV/coordinate/annotation worksheet.
    # Read only those biologically relevant sheets, never every worksheet.
    if resolved_source.suffix.lower() in {'.xlsx', '.xlsm'}:
        try:
            book = pd.ExcelFile(resolved_source, engine='openpyxl')
            for sheet in book.sheet_names:
                name = str(sheet)
                if not re.search(r'igv|coordinate|annotation', name, re.I):
                    continue
                try:
                    frame = book.parse(sheet_name=sheet)
                except Exception:
                    continue
                priority = 75 if re.search(r'coordinate|annotation', name, re.I) else 70
                add_frame(frame, priority)
        except Exception:
            pass

    # Search only the result directory itself and its own Intermediate/Reference
    # locations.  This is intentionally non-recursive.
    known_names = (
        ('gene_coordinates.tsv', 100), ('gene coordinates.tsv', 100),
        ('features.saf', 95),
        ('gene_metadata.tsv', 85), ('gene metadata.tsv', 85),
        ('differential_expression_igv_track_data.tsv', 70),
        ('differential expression igv track data.tsv', 70),
    )
    base_dirs = [resolved_source.parent]
    if resolved_source.parent.name.casefold() == 'intermediate files':
        base_dirs.append(resolved_source.parent.parent)
    else:
        base_dirs.append(resolved_source.parent / 'Intermediate files')
    for base in list(base_dirs):
        base_dirs.extend([
            base / 'Browser files' / 'Reference',
            base / 'Reference',
        ])
    unique_dirs = list(dict.fromkeys(base_dirs))
    for base in unique_dirs:
        if not base.is_dir():
            continue
        for name, priority in known_names:
            add_path(base / name, priority)

    # The DE configuration already records the exact RNA-processing annotation.
    # Follow that explicit path and its siblings instead of walking parent drives.
    result_dir = resolved_source.parent
    if result_dir.name.casefold() == 'intermediate files':
        result_dir = result_dir.parent
    config_candidates = [
        result_dir / 'Intermediate files' / 'de configuration.json',
        result_dir / 'Intermediate files' / 'de_config.json',
        result_dir / 'de configuration.json',
        result_dir / 'de_config.json',
    ]
    for config_path in config_candidates:
        try:
            config = json.loads(config_path.read_text(encoding='utf-8-sig'))
        except Exception:
            continue
        for key in ('coordinate_file', 'annotation_file'):
            raw = str(config.get(key, '') or '').strip()
            if not raw:
                continue
            candidate = resolve_config_path(raw, result_dir)
            if candidate is None:
                continue
            priority = 110 if key == 'coordinate_file' else 90
            add_path(candidate, priority)
            sibling = candidate.parent
            for name, sibling_priority in known_names:
                add_path(sibling / name, max(priority, sibling_priority))
        break

    _COORDINATE_SOURCE_CACHE[cache_key] = loaded
    return loaded


def _find_coordinate_frame(source_path: Path, gene_keys: set[str] | None = None) -> pd.DataFrame | None:
    target_keys = {str(value).strip() for value in (gene_keys or set()) if str(value).strip()}
    scored: list[tuple[tuple[float, float, float, int, int], pd.DataFrame]] = []
    for source_priority, coords in _coordinate_candidates_for_source(source_path):
        strand = coords.get('strand')
        strand_fraction = float(strand.astype(str).isin(['+', '-']).mean()) if strand is not None and len(coords) else 0.0
        has_real_strand = 1.0 if strand_fraction > 0 else 0.0
        if target_keys and '__gene_key' in coords.columns:
            candidate_keys = set(coords['__gene_key'].astype(str).str.strip())
            overlap_fraction = len(target_keys & candidate_keys) / max(1, len(target_keys))
        else:
            overlap_fraction = 0.0
        scored.append(((overlap_fraction, has_real_strand, strand_fraction, source_priority, len(coords)), coords))

    if not scored:
        return None
    scored.sort(key=lambda item: item[0], reverse=True)
    base = scored[0][1].copy()

    # Coordinates and strand can legitimately come from different sources (for
    # example, an IGV audit plus features.saf).  Fill missing strand from the
    # highest-overlap source carrying real +/- annotations.
    strand_candidates = [item for item in scored if item[0][1] > 0 and item[0][2] > 0]
    if strand_candidates and '__gene_key' in base.columns:
        strand_candidates.sort(key=lambda item: (item[0][0], item[0][2], item[0][3], item[0][4]), reverse=True)
        strand_source = strand_candidates[0][1][['__gene_key', 'strand']].copy()
        strand_source = strand_source.drop_duplicates('__gene_key', keep='first').rename(columns={'strand': '__recovered_strand'})
        base = base.merge(strand_source, on='__gene_key', how='left', validate='many_to_one')
        current = _normalize_strand_series(base['strand']) if 'strand' in base.columns else pd.Series('.', index=base.index)
        recovered = _normalize_strand_series(base['__recovered_strand'])
        base['strand'] = current.where(current.isin(['+', '-']), recovered)
        base = base.drop(columns=['__recovered_strand'])
    return base


def _merge_genome_coordinates(frame: pd.DataFrame, source_path: Path) -> pd.DataFrame:
    # Keep an existing valid coordinate table untouched. Otherwise recover coordinates
    # from the IGV audit, canonical RNA-processing coordinate table, SAF, or another
    # worksheet in the same Excel workbook. This prevents table-row-order Circos fallbacks.
    if frame.empty:
        return frame
    existing = _coordinate_frame_from_table(frame)
    has_explicit_coordinates = existing is not None and {"start", "end"}.issubset({str(c) for c in frame.columns})
    existing_strand_fraction = 0.0
    if existing is not None and "strand" in existing.columns and len(existing):
        existing_strand_fraction = float(existing["strand"].astype(str).isin(["+", "-"]).mean())
    # A DE/IGV worksheet may already contain start/end but carry no strand at all.
    # In that case do not freeze the incomplete coordinates: prefer the canonical
    # RNA-processing coordinate/SAF/GFF-derived source so genes are not all drawn
    # on the forward lane.
    if has_explicit_coordinates and existing_strand_fraction >= 0.50:
        return frame
    gene = _first_named_column(frame, ("gene_id", "GeneID", "Geneid", "locus_tag", "gene", "ID", "name"))
    if gene is None:
        return frame
    gene_keys = {str(value).strip() for value in frame[gene].tolist() if str(value).strip()}
    coords = _find_coordinate_frame(source_path, gene_keys)
    if coords is None or coords.empty:
        return frame
    working = frame.copy()
    working["__gene_key"] = working[gene].astype(str).str.strip()
    # Drop coordinate aliases before merge so one canonical set of columns is exposed to Plotly.
    for column in ("seqid", "start", "end", "strand", "chromStart", "chromEnd"):
        if column in working.columns:
            working = working.drop(columns=[column])
    working = working.merge(coords, on="__gene_key", how="left", validate="many_to_one")
    return working.drop(columns=["__gene_key"])


def read_delimited(path: Path, limit: int, sheet_name: str | None = None, *, merge_coordinates: bool = True) -> pd.DataFrame:
    suffix = path.suffix.lower()
    if suffix in {".xlsx", ".xlsm"}:
        frame = pd.read_excel(path, sheet_name=sheet_name or 0, nrows=limit, engine="openpyxl")
    else:
        sep = "," if suffix == ".csv" else "\t"
        try:
            frame = pd.read_csv(path, sep=sep, nrows=limit, low_memory=False)
        except Exception:
            frame = pd.read_csv(path, sep=None, engine="python", nrows=limit, low_memory=False)
    return _merge_genome_coordinates(frame, path) if merge_coordinates else frame


def clean_json_value(value: Any) -> Any:
    if value is None:
        return None
    try:
        if pd.isna(value):
            return None
    except Exception:
        pass
    if isinstance(value, (int, float, str, bool)):
        if isinstance(value, float) and (math.isnan(value) or math.isinf(value)):
            return None
        return value
    return str(value)


def safe_name(value: str, fallback: str = "plot") -> str:
    value = re.sub(r"[^A-Za-z0-9. -]+", " ", value.replace("_", " ").strip())
    value = re.sub(r"\s+", " ", value).strip(" .-")
    return value or fallback


def resolve_config_path(raw: str, output_dir: Path) -> Path | None:
    if not raw:
        return None
    candidate = Path(raw)
    if candidate.exists():
        return candidate.resolve()
    # Configuration produced in WSL is normally already a Linux path. If an old
    # Windows path appears, translate common drive-letter paths locally.
    match = re.match(r"^([A-Za-z]):[\\/](.*)$", raw)
    if match:
        drive = match.group(1).lower()
        tail = match.group(2).replace("\\", "/")
        candidate = Path(f"/mnt/{drive}/{tail}")
        if candidate.exists():
            return candidate.resolve()
    candidate = output_dir / raw
    if candidate.exists():
        return candidate.resolve()
    return None



def _member_annotation_lookup(output_dir: Path) -> dict[str, dict[str, str]]:
    """Return aliases -> concise protein/function annotations for GO member rows.

    The generic plotting table remains Enrichment results only.  This lookup is
    loaded independently from finalized annotation/reference files so clicking a
    GO/pathway/component can still show the biological function for each member.
    """
    frames: list[pd.DataFrame] = []
    candidates: list[tuple[Path, str | None]] = []
    direct_names = (
        "gene_annotations.tsv", "gene annotation.tsv", "gene_metadata.tsv",
        "gene metadata.tsv", "identifier_bridge.tsv", "identifier bridge.tsv",
    )
    search_roots = [
        output_dir,
        output_dir / "Gene-to-term mapping (online)",
        output_dir / "Gene-to-term mapping (offline)",
        output_dir / "Functional annotation",
        output_dir / "Intermediate files",
        output_dir / "Technical details" / "Data tables",
        output_dir.parent,
        output_dir.parent / "analysis_ready" / "reference",
        output_dir.parent / "reference",
    ]
    seen: set[tuple[str, str | None]] = set()
    for root in search_roots:
        if not root.exists():
            continue
        for name in direct_names:
            candidate = root / name
            key = (str(candidate.resolve()) if candidate.exists() else str(candidate), None)
            if candidate.is_file() and key not in seen:
                candidates.append((candidate, None)); seen.add(key)
    # Finalized Excel often carries a richer Gene annotations sheet than the
    # generic Enrichment results sheet.  Read it only for the linked member view.
    for workbook in sorted(output_dir.glob("*.xlsx"), key=lambda x: natural_key(x.name)):
        try:
            sheets = pd.ExcelFile(workbook, engine="openpyxl").sheet_names
        except Exception:
            continue
        for sheet in sheets:
            if str(sheet).casefold() in {"gene annotations", "gene annotation", "gene metadata", "protein annotations"}:
                key=(str(workbook.resolve()),str(sheet))
                if key not in seen:
                    candidates.append((workbook, str(sheet))); seen.add(key)
    for path, sheet in candidates:
        try:
            frame = read_delimited(path, MAX_ROWS_HARD, sheet, merge_coordinates=False)
        except Exception:
            continue
        if not frame.empty:
            frames.append(frame)
    if not frames:
        return {}

    alias_names = (
        "gene_id", "GeneID", "Geneid", "locus_tag", "gene", "ID", "name",
        "original_id", "query_id", "input_id", "matched_accession", "accession",
        "uniprot_accession", "entry_name", "protein_id", "refseq_protein",
    )
    function_names = (
        "product", "protein_name", "protein names", "function", "description",
        "annotation", "name", "gene_name",
    )
    accession_names = (
        "matched_accession", "uniprot_accession", "accession", "protein_id",
        "refseq_protein", "entry_name",
    )
    lookup: dict[str, dict[str, str]] = {}
    for frame in frames:
        alias_cols=[c for c in (_first_named_column(frame,(n,)) for n in alias_names) if c]
        function_cols=[c for c in (_first_named_column(frame,(n,)) for n in function_names) if c]
        accession_cols=[c for c in (_first_named_column(frame,(n,)) for n in accession_names) if c]
        # Preserve order but remove duplicate column aliases discovered by synonyms.
        alias_cols=list(dict.fromkeys(alias_cols)); function_cols=list(dict.fromkeys(function_cols)); accession_cols=list(dict.fromkeys(accession_cols))
        if not alias_cols:
            continue
        for _, row in frame.iterrows():
            aliases=[]
            for col in alias_cols:
                raw=row.get(col, "")
                if pd.isna(raw):
                    continue
                for value in re.split(r"[;,|]", str(raw)):
                    value=value.strip()
                    if value and value.casefold() not in {"nan","none","na"}:
                        aliases.append(value)
            if not aliases:
                continue
            function=""
            for col in function_cols:
                raw=row.get(col, "")
                if pd.isna(raw):
                    continue
                value=str(raw).strip()
                if value and value.casefold() not in {"nan","none","na"}:
                    function=value; break
            accession=""
            for col in accession_cols:
                raw=row.get(col, "")
                if pd.isna(raw):
                    continue
                value=str(raw).strip()
                if value and value.casefold() not in {"nan","none","na"}:
                    accession=value; break
            record={"function":function,"protein":accession}
            for alias in aliases:
                # Keep the first informative record; enrich blanks when a later
                # source has additional product/accession detail.
                previous=lookup.get(alias,{})
                lookup[alias]={
                    "function": previous.get("function") or record["function"],
                    "protein": previous.get("protein") or record["protein"],
                }
    return lookup


@dataclass(frozen=True)
class TableSource:
    key: str
    label: str
    path: Path
    origin: str
    sheet_name: str | None = None


class StudioState:
    def __init__(self, module: str, output_dir: Path, idle_seconds: int) -> None:
        self.module = module
        self.output_dir = output_dir.resolve()
        # Differential-expression publication exports are browser downloads, not
        # persistent analysis-result folders.  The localhost compatibility server
        # therefore stages DE exports in a temporary directory and serves them to
        # the browser.  This keeps the DE result layout limited to Intermediate
        # files, BedGraph, the root-level interactive HTML report, and the Excel workbook.
        self._export_temp = tempfile.TemporaryDirectory(prefix="bra_de_export_") if self.module == "de" else None
        self.export_dir = Path(self._export_temp.name) if self._export_temp is not None else (self.output_dir / "Figures" / "User exports")
        self.export_dir.mkdir(parents=True, exist_ok=True)
        self.idle_seconds = max(300, idle_seconds)
        self.started_at = time.time()
        self.last_activity = time.time()
        self.tables = self._discover_tables()
        self.member_annotations = _member_annotation_lookup(self.output_dir) if self.module in {"enrichment", "combined"} else {}
        self.exports: dict[str, Path] = {}
        self.server: ThreadingHTTPServer | None = None

    def touch(self) -> None:
        self.last_activity = time.time()

    def _discover_tables(self) -> list[TableSource]:
        discovered: dict[tuple[Path, str | None], TableSource] = {}

        def add(path: Path, origin: str, label: str | None = None) -> None:
            try:
                resolved = path.resolve()
            except Exception:
                return
            if not resolved.is_file() or resolved.suffix.lower() not in {".tsv", ".txt", ".csv", ".xlsx", ".xlsm"}:
                return
            sheets: list[str | None] = [None]
            if resolved.suffix.lower() in {".xlsx", ".xlsm"}:
                try:
                    workbook_sheets = [str(name) for name in pd.ExcelFile(resolved, engine="openpyxl").sheet_names]
                    preferred_sheets = {name.casefold(): index for index, name in enumerate(PREFERRED_WORKBOOK_SHEETS.get(self.module, []))}
                    original_order = {name: index for index, name in enumerate(workbook_sheets)}
                    sheets = sorted(workbook_sheets, key=lambda name: (preferred_sheets.get(name.casefold(), len(preferred_sheets) + original_order[name]), original_order[name]))
                except Exception:
                    return
            for sheet_name in sheets:
                identity = (resolved, sheet_name)
                if identity in discovered:
                    continue
                display = label or resolved.name
                if sheet_name is not None:
                    display = f"{resolved.stem} · {sheet_name} · Excel"
                key = f"table_{len(discovered) + 1}"
                discovered[identity] = TableSource(key=key, label=display, path=resolved, origin=origin, sheet_name=sheet_name)

        # Prefer the user-facing Excel workbook when it exists, while retaining
        # technical TSV/CSV inputs as selectable fallbacks for older runs.
        for path in sorted(self.output_dir.glob("*.xlsx"), key=lambda p: natural_key(p.name)):
            add(path, "result")
        for path in sorted(self.output_dir.glob("*.xlsm"), key=lambda p: natural_key(p.name)):
            add(path, "result")

        preferred = PREFERRED_FILES.get(self.module, [])
        for filename in preferred:
            for candidate_name in {filename, filename.replace("_", " ")}:
                add(self.output_dir / candidate_name, "result")
                add(self.output_dir / "Intermediate files" / candidate_name, "result")
                add(self.output_dir / "Technical details" / "Data tables" / candidate_name, "result")

        for path in sorted(self.output_dir.glob("*"), key=lambda p: natural_key(p.name)):
            add(path, "result")
        technical_tables = self.output_dir / "Technical details" / "Data tables"
        if technical_tables.is_dir():
            for path in sorted(technical_tables.glob("*"), key=lambda p: natural_key(p.name)):
                add(path, "result")
        intermediate_tables = self.output_dir / "Intermediate files"
        if intermediate_tables.is_dir():
            for path in sorted(intermediate_tables.glob("*"), key=lambda p: natural_key(p.name)):
                add(path, "result")

        config_names = {f"{self.module}_config.json", f"{self.module} configuration.json"}
        config_candidates = [self.output_dir / name for name in config_names]
        config_candidates += [self.output_dir / "Intermediate files" / name for name in config_names]
        config_candidates += [self.output_dir / "Technical details" / name for name in config_names]
        if self.module == "enrichment":
            config_candidates += [self.output_dir / "enrichment configuration.json"]
            config_candidates += [self.output_dir / "Intermediate files" / "enrichment configuration.json"]
            config_candidates += [self.output_dir / "Technical details" / "enrichment configuration.json"]
        elif self.module == "combined":
            for config_name in ("combined configuration.json", "enrichment configuration.json", "network configuration.json"):
                config_candidates += [self.output_dir / config_name]
                config_candidates += [self.output_dir / "Intermediate files" / config_name]
                config_candidates += [self.output_dir / "Technical details" / config_name]
        for config_path in config_candidates:
            try:
                config = json.loads(config_path.read_text(encoding="utf-8-sig"))
            except Exception:
                continue
            for key in CONFIG_INPUT_KEYS.get(self.module, []):
                resolved = resolve_config_path(str(config.get(key, "")), self.output_dir)
                if resolved:
                    add(resolved, "analysis input", f"{resolved.name} · input")

        # For GO/Enrichment, the generic plot builder intentionally uses only the
        # user-facing Enrichment results worksheet. Other workbook sheets support
        # specialized analyses but are not valid generic X/Y plot tables.
        values = list(discovered.values())
        if self.module == "enrichment":
            preferred = [s for s in values if str(s.sheet_name or "").casefold() == "enrichment results"]
            if not preferred:
                preferred = [s for s in values if s.path.name.casefold().replace(" ", "_") == "enrichment_results.tsv"]
            if preferred:
                values = preferred[:1]
        # Stable keys after all files are discovered.
        tables = []
        for index, source in enumerate(values, start=1):
            tables.append(TableSource(key=f"table_{index}", label=source.label, path=source.path, origin=source.origin, sheet_name=source.sheet_name))
        return tables

    def source(self, key: str) -> TableSource | None:
        return next((item for item in self.tables if item.key == key), None)

    def table_metadata(self, source: TableSource) -> dict[str, Any]:
        frame = read_delimited(source.path, 200, source.sheet_name)
        columns = []
        for column in frame.columns:
            series = frame[column]
            numeric = pd.to_numeric(series, errors="coerce")
            numeric_fraction = float(numeric.notna().mean()) if len(series) else 0.0
            columns.append(
                {
                    "name": str(column),
                    "kind": "numeric" if numeric_fraction >= 0.75 else "categorical",
                    "unique": int(series.nunique(dropna=True)),
                }
            )
        return {
            "key": source.key,
            "label": source.label,
            "origin": source.origin,
            "filename": source.path.name,
            "sheet_name": source.sheet_name,
            "columns": columns,
        }


HTML_TEMPLATE = r'''<div id="studio-app" data-module="__MODULE__">
  <div class="topbar compact-topbar">
    <p class="topbar-hint">Choose a visualization and refine its appearance. Plot titles are optional.</p>
    <div class="status-pill" id="serverStatus">Local and private</div>
  </div>

  __COMPANION_ANALYSES_TOP__

  <div class="workspace">
    <aside class="sidebar">
      <details class="control-section" open>
        <summary>__SECTION_ONE_TITLE__</summary>
        <div class="control-section-body">
        __SECTION_ONE_EXTRA__
        <div id="genericDataControls" hidden>
          <select id="tableSelect" hidden aria-hidden="true" tabindex="-1"></select>
          <select id="rowLimit" hidden aria-hidden="true" tabindex="-1"><option value="200000" selected>200,000</option></select>
          <input id="variableSearch" type="search" placeholder="Search variables" aria-label="Search variables">
          <div id="variableList" class="variable-list" aria-label="Available variables"></div>
          <p class="hint">Drag a variable to a role below. You can also click a variable, then click a role.</p>
          <div id="genericPlotSection">
            <div id="contrastControls" class="contrast-controls" hidden>
              <label for="contrastSelect">Contrast / comparison</label>
              <select id="contrastSelect"></select>
              <label id="histogramAllContrastsRow" class="check" hidden><input id="compareAllContrasts" type="checkbox"> Compare all treatment-vs-control contrasts in Histogram</label>
              <p id="circosContrastNote" class="hint" hidden>Circos uses the combined multi-contrast table and displays all selected treatment-vs-control comparisons as separate rings.</p>
              <p id="genomeRegionContrastNote" class="hint" hidden>Genome region uses the combined multi-contrast table when available, so several treatment-vs-control effects can be compared over the same local gene neighborhood.</p>
            </div>
            <select id="plotType" hidden aria-hidden="true" tabindex="-1"></select>
            <div class="roles" id="roles">
              <button type="button" class="role" data-role="x"><span>X</span><strong>Drop variable</strong></button>
              <button type="button" class="role" data-role="y"><span>Y</span><strong>Drop variable</strong></button>
              <button type="button" class="role" data-role="value"><span>Value / weight</span><strong>Optional</strong></button>
              <button type="button" class="role" data-role="color"><span>Color / group</span><strong>Optional</strong></button>
              <button type="button" class="role" data-role="size"><span>Size</span><strong>Optional</strong></button>
              <button type="button" class="role" data-role="label"><span>Label</span><strong>Optional</strong></button>
            </div>
            <div class="button-row">
              <button type="button" id="autoAssign">Auto-assign</button>
              <button type="button" id="clearRoles">Clear</button>
            </div>
          </div>
        </div>
        </div>
      </details>

      <details class="control-section" id="specializedViewSection" hidden open>
        <summary>2. View</summary>
        <div class="control-section-body">
          <label id="specializedViewChecklistLabel">Available views</label>
          <select id="specializedViewSelect" hidden aria-hidden="true" tabindex="-1"></select>
          <div id="specializedViewChecklist" class="analysis-check-list compact-analysis-check-list" role="group" aria-labelledby="specializedViewChecklistLabel"></div>
          <p class="hint" id="specializedViewHint"></p>
        </div>
      </details>

      <details class="control-section" id="appearanceSection" open>
        <summary id="appearanceSectionSummary">3. Appearance</summary>
        <div class="control-section-body">
        <label for="plotTitle">Plot title (optional)</label>
        <input id="plotTitle" type="text" value="" placeholder="Leave blank for no plot title">
        <div id="moduleRenameControls" class="module-rename-controls" hidden>
          <h3>Detected module names</h3>
          <p class="hint">Modules are detected automatically. Rename them here; plots and the linked spreadsheet update without changing the original result files.</p>
          <div id="moduleRenameList" class="module-rename-list"></div>
        </div>
        <div class="two-col" id="axisTitleInputs">
          <label id="xTitleControl">X-axis title<input id="xTitle" type="text"></label>
          <label id="yTitleControl">Y-axis title<input id="yTitle" type="text"></label>
        </div>
        <label id="axisTitleToggle" class="check appearance-check"><input id="showAxisTitles" type="checkbox" checked> Show axis titles</label>
        <div class="axis-spacing-controls">
          <h3>Plot margins</h3>
          <label for="yAxisSpace">Left (Y axis)</label>
          <div class="margin-input-row"><input id="yAxisSpace" type="range" min="0" max="1200" step="1" value="0" aria-label="Left (Y axis) slider">
          <input id="yAxisSpaceNumber" type="number" min="0" max="1200" step="1" value="0" aria-label="Left (Y axis) pixels"><span>px</span></div>
          <label for="rightAxisSpace">Right (Y axis)</label>
          <div class="margin-input-row"><input id="rightAxisSpace" type="range" min="0" max="1200" step="1" value="0" aria-label="Right (Y axis) slider">
          <input id="rightAxisSpaceNumber" type="number" min="0" max="1200" step="1" value="0" aria-label="Right (Y axis) pixels"><span>px</span></div>
          <label for="xAxisSpace">Bottom (X axis)</label>
          <div class="margin-input-row"><input id="xAxisSpace" type="range" min="0" max="1200" step="1" value="0" aria-label="Bottom (X axis) slider">
          <input id="xAxisSpaceNumber" type="number" min="0" max="1200" step="1" value="0" aria-label="Bottom (X axis) pixels"><span>px</span></div>
          <label for="topAxisSpace">Top (X axis)</label>
          <div class="margin-input-row"><input id="topAxisSpace" type="range" min="0" max="1200" step="1" value="0" aria-label="Top (X axis) slider">
          <input id="topAxisSpaceNumber" type="number" min="0" max="1200" step="1" value="0" aria-label="Top (X axis) pixels"><span>px</span></div>
          <p class="hint">Adjust any edge or enter an exact pixel value. 0 uses automatic spacing. Move the color bar before reducing its margin.</p>
        </div>
        <div class="appearance-basics">
          <label><span>Theme</span><select id="theme"><option value="white">White</option><option value="simple">Simple</option><option value="dark">Dark</option></select></label>
          <label><span>Plot background</span><input id="plotBackgroundColor" type="color" value="#ffffff" aria-label="Plot background color"></label>
        </div>
        <div id="selectionInfoControls">
          <label class="check"><input id="autoSelectionInfo" type="checkbox" checked> Automatically show the information panel after selecting a gene, term, or plot element</label>
        </div>
        <div class="two-col">
          <label id="barOrientationControl">Orientation<select id="barOrientation"><option value="v">Vertical</option><option value="h">Horizontal</option></select></label>
          <label id="showGridControl" class="check appearance-check"><input id="showGrid" type="checkbox"> Show gridlines</label>
        </div>
        <div id="foldChangeScaleControl">
          <label>Fold-change display scale
            <select id="foldChangeScale">
              <option value="log2" selected>log₂ fold change</option>
              <option value="raw">Raw fold change (ratio)</option>
              <option value="log10">log₁₀ fold change</option>
              <option value="ln">Natural log fold change (ln)</option>
            </select>
          </label>
          <p class="hint">Changes how fold-change values are displayed across DE plots. Statistical testing and the volcano cutoff remain based on the original analysis-native log₂ fold change.</p>
        </div>
        <div id="dataColorControls" class="data-color-controls">
          <h3>Plot data colors</h3>
          <div class="two-col data-color-grid">
            <label id="generalDataColorControl"><span id="generalDataColorLabel">General point / bar color</span><input id="generalDataColor" type="color" value="#377497" aria-label="General plot data color"></label>
            <label id="selectedDataColorControl"><span id="selectedDataColorLabel">Selected data color</span><input id="selectedDataColor" type="color" value="#7b2cbf" aria-label="Selected point or bar highlight color"></label>
          </div>
          <div id="deSemanticColorControls" class="data-color-de">
            <div class="three-col data-color-grid data-color-status-grid">
              <label><span>Upregulated</span><input id="upDataColor" type="color" value="#ef5350" aria-label="Upregulated data color"></label>
              <label><span>Downregulated</span><input id="downDataColor" type="color" value="#43a047" aria-label="Downregulated data color"></label>
              <label><span>Not significant</span><input id="nsDataColor" type="color" value="#c9d0cc" aria-label="Not significant data color"></label>
            </div>
            <p class="hint">These colors are used consistently for DE status in Volcano, Circos and Genome region.</p>
          </div>
          <div id="genericNetworkColorControls" class="data-color-de" hidden>
            <div class="two-col data-color-grid">
              <label><span>Network dots / nodes</span><input id="networkNodeColor" type="color" value="#377497" aria-label="Network node color"></label>
              <label><span>Connecting lines / edges</span><input id="networkEdgeColor" type="color" value="#7b8d83" aria-label="Network edge color"></label>
            </div>
          </div>
        </div>
        <div class="two-col">
          <label id="aggregationControl">Aggregation<select id="aggregation"><option value="mean" selected>Mean</option><option value="sum">Sum</option><option value="median">Median</option><option value="count">Count</option><option value="none">No aggregation</option></select></label>
          <label id="colorScaleControl">Color scale<select id="colorScale"><option>Viridis</option><option>Plasma</option><option>Cividis</option><option>Blues</option><option>Greens</option><option>RdBu</option></select></label>
        </div>
        <div class="two-col">
          <label id="networkLayoutControl">Network layout<select id="networkLayout"><option value="force" selected>Force-directed</option><option value="circular">Circular</option><option value="concentric">Concentric</option><option value="grid">Grid</option></select></label>
          <label id="networkEdgesControl">Maximum network edges<input id="networkEdges" type="number" min="10" max="5000" step="10" value="500"></label>
        </div>
        <div class="two-col">
          <label id="pointSizeControl">Point size<input id="pointSize" type="number" min="2" max="30" step="1" value="7"></label>
          <label id="opacityControl">Opacity<input id="opacity" type="number" min="0.05" max="1" step="0.05" value="0.8"></label>
        </div>
        <div id="volcanoOptions" class="special-options">
          <h3>Volcano plot options</h3>
          <div class="two-col">
            <label>Absolute log₂ FC cutoff<input id="volcanoLfcCutoff" type="number" min="0" max="50" step="0.1" value="1"></label>
            <label>P-value cutoff<input id="volcanoPCutoff" type="number" min="0.000000000001" max="1" step="0.01" value="0.05"></label>
          </div>
          <div class="two-col">
            <label>Minimum point size<input id="volcanoMinSize" type="number" min="2" max="30" step="1" value="5"></label>
            <label>Maximum point size<input id="volcanoMaxSize" type="number" min="4" max="60" step="1" value="20"></label>
          </div>
          <label>Labels per direction<input id="volcanoLabelCount" type="number" min="0" max="30" step="1" value="8"></label>
          <label class="check"><input id="volcanoCounts" type="checkbox" checked> Show up/down counts and arrows</label>
          <label class="check"><input id="volcanoConnectors" type="checkbox" checked> Show most regulated genes with connector lines</label>
          <p class="hint">Volcano point color uses one continuous downregulated → not-significant → upregulated gradient built from your editable DE colors. Farther from the gray center means larger −log₁₀ of the selected p-value; point size also increases with significance. The matching vertical scale is placed at the far right. Hover always shows the gene and statistics.</p>
        </div>
        <div id="histogramOptions" class="special-options">
          <h3>Histogram options</h3>
          <label>Number of bins<input id="histogramBins" type="number" min="5" max="200" step="1" value="40"></label>
          <div id="histogramContigPicker" class="contig-picker">
            <div class="contig-picker-head"><strong>Contigs / replicons to include</strong><span><button type="button" id="histogramContigAll">All</button><button type="button" id="histogramContigNone">None</button></span></div>
            <div id="histogramContigList" class="contig-check-list"></div>
            <p id="histogramContigSummary" class="hint"></p>
          </div>
          <p class="hint">Choose which contigs contribute genes to the distribution. When several contigs are selected, each contig is drawn as a separate histogram using the editable color swatch beside its name. The bin count controls histogram resolution without changing the underlying values.</p>
        </div>
        <div id="circosOptions" class="special-options">
          <h3>Circos differential-expression options</h3>
          <label>Adjusted-p cutoff<input id="circosPCutoff" type="number" min="0.000000000001" max="1" step="0.01" value="0.05"></label>
          <label class="check"><input id="circosSigOnly" type="checkbox"> Hide non-significant genes</label>
          <label class="check"><input id="circosFreeCamera" type="checkbox" checked> Interactive pan / zoom Circos</label>
          <div id="circosContigPicker" class="contig-picker">
            <div class="contig-picker-head"><strong>Contigs / replicons to display</strong><span><button type="button" id="circosContigAll">All</button><button type="button" id="circosContigNone">None</button></span></div>
            <div id="circosContigList" class="contig-check-list"></div>
            <p id="circosContigSummary" class="hint"></p>
          </div>
          <p class="hint">Genes are ordered by real genomic coordinates. Differential expression is drawn only as radial bars with no endpoint bubbles. With interactive pan / zoom enabled, choose Pan and drag the full circle or a box-zoomed partial arc using real plot coordinates. Mouse-wheel and +/− zoom preserve full resolution, hover and gene clicking. Box zoom changes the genomic interval itself; the resulting partial arc is fitted and enlarged without being stretched into a full circle. Reset restores the complete genome.</p>
        </div>
        <div id="genomeRegionOptions" class="special-options">
          <h3>Genome-region gene track options</h3>
          <label>Genes in initial detailed window<input id="genomeRegionGeneCount" type="number" min="15" max="200" step="5" value="55"></label>
          <label class="check"><input id="genomeRegionWheelZoom" type="checkbox" checked> Mouse wheel zooms genomic position</label>
          <label class="check"><input id="genomeRegionAutoScale" type="checkbox" checked> Auto-scale expression Y axis while moving between regions</label>
          <label class="check"><input id="genomeRegionGuideLines" type="checkbox"> Show dashed bar-to-gene guide lines</label>
          <div id="genomeRegionContigPicker" class="contig-picker">
            <div class="contig-picker-head"><strong>Contigs / replicons to display</strong><span><button type="button" id="genomeRegionContigAll">All</button><button type="button" id="genomeRegionContigNone">None</button></span></div>
            <div id="genomeRegionContigList" class="contig-check-list"></div>
            <p id="genomeRegionContigSummary" class="hint"></p>
          </div>
          <p class="hint">The initial-window value controls how many genes are used to define the first detailed genomic view; changing it resets that initial view immediately. A gggenomes-style gene track uses each gene's true start, end, and strand. Dragging pans the region. When Mouse wheel zoom is enabled, scroll over the plot to zoom only the genomic X range. Auto-scale expression Y axis is enabled by default; turn it off when you want the same expression scale to remain fixed while panning to another genomic region. Turn on dashed bar-to-gene guide lines to draw light vertical guides from visible expression bars toward their corresponding gene arrows; very wide views automatically thin the guides to keep panning responsive. When several contigs are checked, each selected contig is shown as its own detailed genomic window in the same view. Hover always reports the original contig and native genomic coordinates.</p>
        </div>
        <label class="check"><input id="showLegend" type="checkbox" checked> Show legend</label>
        <label id="showLabelsControl" class="check"><input id="showLabels" type="checkbox"> Show plot labels</label>
        <label id="specializedLabelControl" class="check" hidden><input id="showSpecializedLabels" type="checkbox" checked> Show data labels</label>
        <label id="specializedGridControl" class="check" hidden><input id="showSpecializedGrid" type="checkbox"> Show gridlines</label>
        <div id="specializedPlotColorControls" class="data-color-controls" hidden>
          <h3>Specialized plot colors</h3>
          <p class="setting-summary">Custom colors are always active for specialized plots.</p>
          <div class="two-col data-color-grid">
            <label><span>Primary data color</span><input id="specializedPrimaryColor" type="color" value="#2f8f83" aria-label="Primary specialized plot color"></label>
            <label><span>Secondary data color</span><input id="specializedSecondaryColor" type="color" value="#d1775b" aria-label="Secondary specialized plot color"></label>
          </div>
          <label id="specializedColorScaleControl">Gradient palette<select id="specializedColorScale"><option value="Viridis" selected>Viridis</option><option value="Plasma">Plasma</option><option value="Cividis">Cividis</option><option value="Blues">Blues</option><option value="Greens">Greens</option><option value="RdBu">Red–blue</option></select></label>
          <p class="hint">Applies to GO and co-expression marks, lines and numeric gradients. Network node groups and connections can still be changed independently below.</p>
        </div>
        <div id="specializedNetworkColorControls" class="data-color-controls specialized-network-colors" hidden>
          <h3>Network colors</h3>
          <div id="specializedNodeColorList" class="specialized-node-color-list"></div>
          <label class="specialized-edge-color"><span>Connection lines</span><input id="specializedEdgeColor" type="color" value="#52665b" aria-label="Network connection line color"></label>
          <p class="hint">Each node group and every connection line can be recolored independently. The legend updates with the node colors.</p>
        </div>
        <div class="button-row">
          <button type="button" id="resetAppearance">Reset appearance to defaults</button>
        </div>
        <div class="button-row typography-launch">
          <button type="button" id="openTypography">Typography…</button>
          <span id="typographySummary" class="setting-summary">Segoe UI · 13 px · theme color · Regular</span>
        </div>
        </div>
      </details>
    </aside>
    <div id="sidebarSplitter" class="pane-splitter sidebar-splitter" title="Drag to resize controls" aria-label="Resize controls panel"></div>

    <main class="main-panel">
      <div class="preview-head" id="genericPreviewHead">
        <div class="preview-copy">
          <div id="plotGuide" class="plot-guide">Choose a plot type to see what it reveals about your RNA-seq results.</div>
          <div class="plot-toolbar-row">
            <span id="plotMessage" class="visually-hidden" aria-live="polite">Preparing visualization.</span>
            <div class="plot-toolbar" aria-label="Plot controls">
              <label class="toolbar-drag-control" for="dragMode"><span>Mouse drag</span><select id="dragMode"><option value="pan" selected>Pan / move plot</option><option value="zoom">Box zoom</option><option value="select">Box select</option><option value="lasso">Lasso select</option></select></label>
              <button type="button" id="toolbarZoomIn" title="Zoom in">＋</button>
              <button type="button" id="toolbarZoomOut" title="Zoom out">−</button>
              <button type="button" id="resetView" title="Reset plot view">Reset</button>
              <button type="button" id="toolbarDownload" title="Open publication-quality export options">Export</button>
              <button type="button" id="viewPlotCode" title="View plotting code">Code</button>
            </div>
          </div>
          <p id="dataSummary" class="visually-hidden" aria-live="polite">Loading data…</p>
        </div>
      </div>
      <div id="plot" class="plot" aria-label="Interactive plot preview"></div>
      <div id="plotEmptyState" class="plot-empty-state">
        <strong>No plot is shown yet.</strong>
        <span>Click 1. Analysis / visualization and choose the plot or analysis you want to inspect.</span>
      </div>
      <div id="specializedPlotStack" class="specialized-plot-stack" aria-label="Selected specialized GO analyses" hidden></div>
      <div id="plotSheetSplitter" class="pane-splitter plot-sheet-splitter" title="Drag to resize plot and spreadsheet" aria-label="Resize plot and spreadsheet"></div>

      <section class="linked-sheet" aria-labelledby="linkedSheetTitle">
        <div class="sheet-head">
          <div>
            <h2 id="linkedSheetTitle">Linked Excel spreadsheet</h2>
            <p id="sheetSource">The selected result table is shown below.</p>
            <button type="button" id="sheetBackToResults" hidden>Back to result table</button>
          </div>
        </div>
        <div class="sheet-controls">
          <label>Search all columns<input id="sheetSearch" type="search" placeholder="Gene, term, module, value…"></label>
          <label>Rows per page<select id="sheetPageSize"><option value="50">50</option><option value="100" selected>100</option><option value="250">250</option><option value="500">500</option><option value="custom">Custom…</option><option value="all">All genes</option></select></label>
          <label id="sheetCustomPageSizeLabel" hidden>Custom rows<input id="sheetCustomPageSize" type="number" min="1" max="100000" step="1" value="1000"></label>
        </div>
        <p class="hint sheet-hint" title="Click any spreadsheet row to highlight its corresponding graph element. Click a graph point, bar, term, or network node to reveal its source row. Rows per page accepts presets, a Custom value, or All genes. Drag headers to rearrange columns; click a header to cycle ascending, descending, and original order.">Click a row or plot element to link them. Hover cells for full values; drag headers to reorder and click headers to sort.</p>
        <div class="linked-table-wrap" id="linkedTableWrap"><table id="linkedTable"></table></div>
        <div class="sheet-footer">
          <span id="sheetPageSummary">No rows loaded</span>
          <div class="sheet-navigation">
            <div class="sheet-jump">
              <div class="jump-card">
                <span class="jump-title">Jump to row</span>
                <div class="jump-input-row"><input id="sheetJumpRow" type="number" min="1" step="1" placeholder="Row"><button type="button" id="sheetJumpRowGo">Go</button></div>
              </div>
              <div class="jump-card">
                <span class="jump-title">Jump to page</span>
                <div class="jump-input-row"><input id="sheetJumpPage" type="number" min="1" step="1" placeholder="Page"><button type="button" id="sheetJumpPageGo">Go</button></div>
              </div>
            </div>
            <div class="sheet-page-actions">
              <button type="button" id="sheetExportExcel" title="Export all currently filtered linked rows as an Excel-compatible workbook">Export Excel</button>
              <div class="button-row sheet-pages">
                <button type="button" id="sheetPrevious">Previous</button>
                <button type="button" id="sheetNext">Next</button>
              </div>
            </div>
          </div>
        </div>
      </section>

      <section class="export-panel export-hidden" id="publicationExportPanel">
        <div class="export-title">
          <div>
            <h2>Publication-quality export</h2>
            <p>SVG and PDF are vector formats for unlimited enlargement. Raster formats are exported at the highest selected resolution; maximum mode uses the largest safe pixel dimensions.</p>
          </div>
          <div class="export-dialog-actions"><span id="pixelEstimate" class="status-pill">Calculating size…</span><button type="button" id="closePublicationExport" title="Close export options">×</button></div>
        </div>
        <div class="export-grid">
          <label>Format
            <select id="exportFormat">
              <option value="svg">SVG · vector / unlimited zoom</option>
              <option value="pdf">PDF · publication page</option>
              <option value="tiff" selected>TIFF · lossless</option>
              <option value="png">PNG · lossless</option>
              <option value="jpeg">JPEG · quality 100</option>
              <option value="webp">WebP · quality 100</option>
              <option value="html">Interactive HTML</option>
            </select>
          </label>
          <label>Paper size
            <select id="paperSize">
              <option>A0</option><option>A1</option><option>A2</option><option>A3</option><option selected>A4</option><option>A5</option>
              <option>Letter</option><option>Legal</option><option>Square</option><option>Custom</option>
            </select>
          </label>
          <label>Orientation
            <select id="paperOrientation"><option value="landscape" selected>Landscape</option><option value="portrait">Portrait</option></select>
          </label>
          <label>Resolution
            <select id="dpiMode">
              <option value="maximum" selected>Maximum safe resolution</option>
              <option value="2400">2400 DPI</option><option value="1200">1200 DPI</option><option value="600">600 DPI</option><option value="300">300 DPI</option><option value="150">150 DPI</option><option value="custom">Custom DPI</option>
            </select>
          </label>
          <label>Custom DPI<input id="customDpi" type="number" min="72" max="2400" step="1" value="1200" disabled></label>
          <label>Width (mm)<input id="widthMm" type="number" min="20" max="2000" step="1" value="297" disabled></label>
          <label>Height (mm)<input id="heightMm" type="number" min="20" max="2000" step="1" value="210" disabled></label>
          <label>File name<input id="exportName" type="text" value="Publication plot"></label>
        </div>
        <div class="button-row export-actions">
          <button type="button" id="exportButton" class="primary">Export current plot</button>
          <button type="button" id="stopServer">Close visualization studio server</button>
        </div>
        <div id="exportStatus" class="message" aria-live="polite"></div>
      </section>
    </main>
  </div>

  <dialog id="plotCodeDialog" class="code-dialog">
    <div class="dialog-head"><h2>Plot and analysis code</h2><button type="button" id="closePlotCode">Close</button></div>
    <p class="dialog-copy">For scientific transparency, the first view shows the actual Plotly.js logic used by this interactive report. A reproducible Python equivalent is also provided. The statistical-analysis tab shows the R source used to generate the DE/GO/Network result tables.</p>
    <div class="code-toolbar">
      <label>Code view<select id="plotCodeMode"><option value="actual" selected>Actual Plotly.js code</option><option value="python">Reproducible Python equivalent</option><option value="analysis">Statistical analysis R source</option></select></label>
      <button type="button" id="copyPlotCode">Copy code</button>
    </div>
    <pre id="plotCodeText" class="code-view"></pre>
    <div id="plotCodeStatus" class="message"></div>
  </dialog>

  <dialog id="dataDialog">
    <div class="dialog-head"><h2>Data sample</h2><button type="button" id="closeData">Close</button></div>
    <div class="table-wrap"><table id="dataTable"></table></div>
  </dialog>

  <dialog id="typographyDialog" class="typography-dialog">
    <div class="dialog-head"><h2>Graph typography</h2><button type="button" id="closeTypography">Close</button></div>
    <p class="dialog-copy">Choose the font used for graph titles, axes, tick labels, legends, annotations, and data labels.</p>
    <div class="typography-grid">
      <label>Font
        <select id="fontFamily">
          <option>Arial</option>
          <option>Times New Roman</option>
          <option>Calibri</option>
          <option selected>Segoe UI</option>
          <option>Helvetica</option>
          <option>Georgia</option>
          <option>Verdana</option>
          <option>Tahoma</option>
          <option>Courier New</option>
          <option>Garamond</option>
        </select>
      </label>
      <label>Text size (px)<input id="fontSize" type="number" min="6" max="72" step="1" value="13"></label>
    </div>
    <label>Text color</label>
    <div class="color-row">
      <input id="fontColor" type="color" value="#1e2a22" aria-label="Graph text color" title="Choose any graph text color">
      <input id="fontColorHex" type="text" value="#1e2a22" maxlength="7" aria-label="Graph text color hexadecimal value" placeholder="#1e2a22">
    </div>
    <label class="check"><input id="useThemeFontColor" type="checkbox" checked> Automatically use a readable color for the selected graph theme</label>
    <p class="hint">You can choose any text color above. Picking or typing a color automatically turns off the theme-controlled text color.</p>
    <fieldset class="style-options">
      <legend>Text style</legend>
      <label class="check"><input id="fontBold" type="checkbox"> Bold</label>
      <label class="check"><input id="fontItalic" type="checkbox"> Italic</label>
      <label class="check"><input id="fontUnderline" type="checkbox"> Underline</label>
    </fieldset>
    <div class="typography-sample-wrap">
      <span>Preview</span>
      <div id="typographySample">Gene expression · log₂ fold change</div>
    </div>
    <div id="typographyMessage" class="message" aria-live="polite"></div>
    <div class="button-row dialog-actions">
      <button type="button" id="resetTypography">Reset defaults</button>
      <button type="button" id="cancelTypography">Cancel</button>
      <button type="button" id="applyTypography" class="primary">Apply to graph</button>
    </div>
  </dialog>
</div>

<style>
  :root { color-scheme: light; --green:#417a4b; --green-dark:#2a5534; --green-soft:#e6f2e8; --border:#ccd9cf; --ink:#1e2a22; --muted:#58655d; --bg:#f5f8f6; --surface:#fff; --blue:#377497; }
  * { box-sizing:border-box; }
  html, body { width:100%; height:100%; overflow:hidden; }
  body { margin:0; font-family:"Segoe UI",Arial,sans-serif; color:var(--ink); background:var(--bg); }
  #studio-app { width:100%; height:100vh; min-height:0; display:flex; flex-direction:column; overflow:hidden; }
  .topbar { display:flex; justify-content:space-between; gap:14px; align-items:center; padding:5px 14px; min-height:34px; background:var(--surface); border-bottom:1px solid var(--border); }
  .compact-topbar { position:sticky; top:0; z-index:10; }
  .topbar-hint { color:var(--muted); font-size:12px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
  h1 { display:none; }
  h2 { margin:0 0 10px; font-size:17px; color:var(--green-dark); }
  h3 { margin:0 0 7px; font-size:14px; color:var(--green-dark); }
  p { margin:0; line-height:1.45; }
  .status-pill { display:inline-flex; align-items:center; border:1px solid var(--border); background:var(--green-soft); color:var(--green-dark); border-radius:999px; padding:7px 11px; font-size:13px; white-space:nowrap; }
  .companion-analyses{margin:8px 12px 0;padding:10px 12px;border:1px solid #d5e1d8;border-radius:10px;background:#fbfdfb;font:13px/1.35 "Segoe UI",Arial,sans-serif}

  .sidebar .companion-analyses{margin:0 0 12px;padding:9px 9px;background:#f8fbf8}.sidebar .companion-note{display:block;margin:4px 0 0}.sidebar .companion-links{gap:6px}.sidebar .companion-links a{padding:6px 8px;font-size:12px}
  #sheetBackToResults{align-self:flex-start;margin-top:3px;border:1px solid #b9cdbf;border-radius:7px;background:#fff;color:#245a39;padding:5px 8px;cursor:pointer}
  .companion-analyses strong{color:#2a5534}.companion-links{display:flex;flex-wrap:wrap;gap:7px;margin-top:7px}.companion-links a{display:inline-block;padding:6px 9px;border:1px solid #b9cdbf;border-radius:8px;background:white;color:#245a39;text-decoration:none}.companion-links a:hover{background:#eef7f0}.companion-note{color:#5a6a5e;margin-left:8px}
  .workspace { --sidebar-width:330px; flex:1 1 auto; min-height:0; display:grid; grid-template-columns:minmax(260px,var(--sidebar-width)) 8px minmax(0,1fr); grid-template-rows:minmax(0,1fr); gap:6px; padding:10px 12px 12px; overflow:hidden; }
  /* Use normal block flow for the collapsible controls. A flex column can shrink
     opened <details> elements to fit the sticky viewport, which makes the next
     section visually slide over the previous one and clips the last input row. */
  .sidebar { display:block; align-self:stretch; position:static; top:auto; height:100%; max-height:none; min-height:0; overflow-y:auto; overflow-x:hidden; padding-bottom:8px; scrollbar-gutter:stable; }
  #studio-app[data-module="enrichment"] > .topbar,
  #studio-app[data-module="combined"] > .topbar,
  #studio-app[data-module="de"] > .topbar { display:none; }
  #studio-app[data-module="enrichment"] > .workspace,
  #studio-app[data-module="network"] > .workspace,
  #studio-app[data-module="combined"] > .workspace,
  #studio-app[data-module="de"] > .workspace { padding-top:4px; }
  #studio-app[data-module="enrichment"] .sidebar,
  #studio-app[data-module="combined"] .sidebar,
  #studio-app[data-module="de"] .sidebar { top:auto; max-height:none; }
  section, .control-section { background:var(--surface); border:1px solid var(--border); border-radius:10px; padding:12px; }
  .control-section { padding:0; overflow:hidden; margin:0 0 8px; height:auto; min-height:0; }
  .control-section:last-child { margin-bottom:0; }
  .control-section[open] { overflow:visible; }
  .control-section summary { list-style:none; cursor:pointer; padding:10px 12px; font-size:15px; font-weight:700; color:var(--green-dark); background:#fbfdfb; user-select:none; }
  .control-section summary::-webkit-details-marker { display:none; }
  .control-section summary::after { content:'▾'; float:right; color:var(--green); font-size:13px; margin-top:2px; }
  .control-section:not([open]) summary::after { content:'▸'; }
  .control-section-body { padding:0 12px 12px; border-top:1px solid #edf2ee; }
  label { display:block; font-size:13px; font-weight:600; margin:8px 0 4px; }
  input, select, button { font:inherit; }
  input[type=text], input[type=number], input[type=search], select { width:100%; border:1px solid #aebbb1; border-radius:6px; padding:8px 9px; background:#fff; color:var(--ink); }
  input[type=color] { width:54px; min-height:38px; border:1px solid #aebbb1; border-radius:6px; padding:3px; background:#fff; cursor:pointer; }
  button { border:1px solid var(--border); border-radius:6px; padding:8px 11px; background:#fff; color:var(--ink); cursor:pointer; }
  button:hover { border-color:var(--green); }
  button.primary { background:var(--green); color:#fff; border-color:var(--green); font-weight:600; }
  button:disabled { opacity:.55; cursor:not-allowed; }
  .row.compact { display:grid; grid-template-columns:1fr 120px; gap:10px; align-items:end; }
  .variable-list { max-height:240px; overflow:auto; border:1px solid var(--border); border-radius:7px; padding:7px; margin-top:8px; background:#fbfdfb; }
  .variable { display:flex; justify-content:space-between; gap:8px; align-items:center; padding:7px 8px; margin:4px 0; border:1px solid transparent; border-radius:6px; background:#fff; cursor:grab; }
  .variable:hover, .variable.selected { border-color:var(--green); background:var(--green-soft); }
  .variable small { color:var(--muted); }
  .hint { margin-top:8px; color:var(--muted); font-size:12px; }
  .roles { display:grid; grid-template-columns:1fr 1fr; gap:12px; }
  .role { min-height:58px; text-align:left; background:#fbfdfb; border:1px dashed #93a798; }
  .role span { display:block; color:var(--green-dark); font-size:12px; font-weight:700; text-transform:uppercase; }
  .role strong { display:block; margin-top:4px; font-size:13px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .role.assigned { border-style:solid; background:var(--green-soft); }
  .two-col { display:grid; grid-template-columns:1fr 1fr; gap:12px; }
  .three-col { display:grid; grid-template-columns:repeat(3,1fr); gap:10px; }
  .appearance-basics { display:grid; grid-template-columns:1fr; gap:7px; margin-top:8px; }
  .appearance-basics > label { display:grid; grid-template-columns:126px minmax(0,1fr); gap:10px; align-items:center; margin:0; }
  .appearance-basics > label > span { white-space:nowrap; }
  .appearance-basics select { min-width:0; }
  .appearance-basics input[type="color"] { justify-self:start; }
  .data-color-controls { margin-top:12px; padding:10px 11px; border:1px solid var(--border); border-radius:8px; background:#fbfdfb; }
  .data-color-controls h3 { margin-bottom:8px; }
  .data-color-controls input[type="color"] { width:72px; max-width:100%; min-height:38px; padding:3px; cursor:pointer; }
  .data-color-grid { grid-template-columns:repeat(auto-fit,minmax(138px,1fr)); align-items:start; }
  .data-color-status-grid { grid-template-columns:repeat(auto-fit,minmax(104px,1fr)); }
  .data-color-controls .data-color-grid > label { display:flex; flex-direction:column; align-items:flex-start; gap:6px; min-width:0; line-height:1.25; overflow-wrap:anywhere; }
  .data-color-controls .data-color-grid > label > span { display:block; min-width:0; }
  .axis-spacing-controls { margin-top:10px; padding:10px 11px; border:1px solid var(--border); border-radius:8px; background:#fbfdfb; }
  .margin-input-row { display:grid; grid-template-columns:minmax(60px,1fr) 76px 18px; gap:6px; align-items:center; }
  .margin-input-row input[type=number] { padding:5px; }
  .axis-spacing-controls h3 { margin-bottom:4px; }
  .axis-spacing-controls label { position:relative; }
  .axis-spacing-controls input[type="range"] { width:100%; margin-top:5px; accent-color:var(--green); }
  #plotBackgroundColor { min-height:38px; padding:3px; cursor:pointer; }
  .data-color-de { margin-top:10px; padding-top:9px; border-top:1px solid #e0e8e2; }
  .specialized-network-colors { display:grid; gap:9px; }
  .specialized-node-color-list { display:grid; grid-template-columns:repeat(auto-fit,minmax(138px,1fr)); gap:9px; }
  .specialized-node-color-list label, .specialized-edge-color { display:flex; flex-direction:column; align-items:flex-start; gap:5px; min-width:0; line-height:1.25; }
  .specialized-node-color-list span, .specialized-edge-color span { overflow-wrap:anywhere; }
  .specialized-network-colors input[type="color"] { width:72px; min-height:38px; padding:3px; cursor:pointer; }
  .check { display:flex; gap:8px; align-items:center; font-weight:500; }
  .check input { width:auto; }
  .appearance-check { margin-top:26px; align-self:start; }
  .button-row { display:flex; gap:8px; flex-wrap:wrap; margin-top:10px; }
  .typography-launch { align-items:center; }
  .setting-summary { color:var(--muted); font-size:12px; line-height:1.35; }
  .special-options { display:none; margin-top:12px; padding:11px; border:1px solid var(--border); border-radius:8px; background:#f8faf8; }
  .module-rename-controls { margin-top:12px; padding:10px; border:1px solid var(--border); border-radius:8px; background:#f8faf8; }
  .module-rename-list { display:grid; gap:7px; max-height:220px; overflow:auto; margin-top:8px; }
  .module-rename-row { display:grid; grid-template-columns:minmax(90px,.8fr) minmax(130px,1.2fr); gap:8px; align-items:center; }
  .module-rename-row span { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; font-size:12px; font-weight:700; }
  .module-rename-row input { margin:0; padding:6px 8px; }

  /* Publication export is a toolbar-open dialog, not permanent layout content. */
  .export-panel.export-hidden { display:none !important; }
  .export-panel.export-modal-open { position:fixed; z-index:9999; left:50%; top:50%; transform:translate(-50%,-50%); width:min(980px,92vw); max-height:90vh; overflow:auto; background:#fff; box-shadow:0 20px 60px rgba(0,0,0,.25); border:1px solid var(--border); border-radius:14px; padding:18px; } .export-dialog-actions { display:flex; align-items:center; gap:10px; position:absolute; top:14px; right:14px; } .export-dialog-actions button { font-size:22px; line-height:1; padding:2px 9px; border-radius:8px; } .export-panel h2 { margin-right:80px; }
  .main-panel { --plot-width:760px; --panel-height:100%; min-width:0; display:grid; grid-template-columns:minmax(620px,var(--plot-width)) 8px minmax(340px,1fr); grid-template-rows:auto minmax(0,1fr); gap:8px 6px; height:var(--panel-height); min-height:0; align-items:stretch; overflow:auto hidden; padding-bottom:0; }
  .preview-head, .export-title { display:flex; justify-content:space-between; gap:16px; align-items:center; margin-bottom:0; }
  .preview-head { grid-column:1; grid-row:1; min-width:0; }
  .preview-copy { min-width:0; width:100%; }
  .plot-toolbar-row { display:flex; justify-content:flex-end; align-items:center; margin-top:8px; }
  .plot-toolbar { display:flex; align-items:center; gap:5px; flex-wrap:nowrap; }
  .plot-toolbar button { padding:5px 8px; min-width:34px; font-size:12px; line-height:1.15; white-space:nowrap; }
  .toolbar-drag-control { display:flex; flex-direction:row; align-items:center; gap:7px; margin:0; font-size:12px; font-weight:700; white-space:nowrap; }
  .toolbar-drag-control select { width:154px; min-width:154px; margin:0; padding:5px 24px 5px 8px; font-size:12px; line-height:1.15; }
  .plot-guide { margin:0; color:var(--muted); font-size:12px; line-height:1.30; }
  .plot-guide p { display:grid; grid-template-columns:104px minmax(0,1fr); gap:5px; align-items:start; margin:0 0 2px; }
  .plot-guide p:last-child { margin-bottom:0; }
  .plot-guide strong { color:var(--green-dark); font-size:13px; font-weight:700; }
  .plot-guide p > strong, .plot-guide p > span { display:block; min-width:0; }
  .visually-hidden { display:none !important; }
  [hidden] { display:none !important; }
  .message { color:var(--muted); min-height:22px; padding:4px 0; }
  .plot { grid-column:1; grid-row:2; width:100%; height:100%; min-height:0; background:#fff; border:1px solid var(--border); border-radius:10px; overflow:hidden; position:relative; }
  #plot .bra-selection-info-annotation text { font-size:12px !important; }
  .plot-empty-state { grid-column:1; grid-row:2; width:100%; height:100%; min-height:260px; display:flex; flex-direction:column; justify-content:center; align-items:center; gap:8px; padding:30px; text-align:center; color:var(--muted); background:#fff; border:1px dashed #9db1a2; border-radius:10px; }
  .plot-empty-state strong { color:var(--green-dark); font-size:18px; }
  .specialized-plot-stack { grid-column:1; grid-row:2; width:100%; height:100%; min-height:0; display:grid; gap:8px; overflow:hidden; background:transparent; }
  .specialized-frame-card { min-width:0; min-height:0; display:flex; flex-direction:column; border:1px solid var(--border); border-radius:10px; overflow:hidden; background:#fff; }
  .specialized-frame-title { flex:0 0 auto; padding:7px 11px; border-bottom:1px solid var(--border); background:#f5f8f5; color:var(--green-dark); font-size:12px; font-weight:700; }
  .specialized-plot-frame { flex:1 1 auto; width:100%; min-height:0; border:0; background:#fff; }
  #analysisSelect { display:block; width:100%; }
  .analysis-check-list { display:grid; gap:6px; max-height:310px; overflow:auto; margin:4px 0 9px; padding:7px; border:1px solid var(--border); border-radius:9px; background:#fbfdfb; }
  .analysis-check-item { display:grid; grid-template-columns:18px minmax(0,1fr); gap:8px; align-items:start; padding:7px 8px; margin:0; border-radius:7px; font-weight:600; line-height:1.3; cursor:pointer; }
  .analysis-check-item:hover { background:#eaf4ec; }
  .analysis-check-item input { width:auto; margin-top:2px; }
  .compact-analysis-check-list { max-height:230px; }
  .compact-analysis-check-list .analysis-check-item { font-size:12px; font-weight:500; }
  #genericDataControls[hidden], #genericPlotSection[hidden], #genericPreviewHead[hidden], #plot[hidden], #plotEmptyState[hidden], #specializedPlotStack[hidden] { display:none!important; }
  #plot > .plot-container { transform-origin:50% 50%; will-change:transform; }
  #plot g.colorbar { cursor:grab; }
  #plot.bra-colorbar-dragging g.colorbar { cursor:grabbing; }
  #plot.circos-free-camera { cursor:grab; touch-action:none; }
  #plot.circos-free-camera.circos-camera-dragging { cursor:grabbing; }
  #sheetCustomPageSizeLabel { min-width:118px; }
  #sheetCustomPageSizeLabel input { width:112px; }
  .main-panel.plot-large, .main-panel.plot-circos, .main-panel.plot-volcano, .main-panel.plot-genome { min-width:0; grid-template-columns:minmax(620px,var(--plot-width)) 8px minmax(340px,1fr); grid-template-rows:auto minmax(0,1fr); height:var(--panel-height); min-height:0; align-items:stretch; overflow-x:auto; }
  .main-panel .plot, .main-panel.plot-large .plot, .main-panel.plot-circos .plot, .main-panel.plot-volcano .plot, .main-panel.plot-genome .plot { width:100%; height:100%; min-height:0; }
  .roles { margin-top:2px; }
  .pane-splitter { position:relative; min-width:8px; cursor:col-resize; user-select:none; touch-action:none; border-radius:999px; }
  .pane-splitter::after { content:''; position:absolute; top:7%; bottom:7%; left:3px; width:2px; border-radius:999px; background:#c1cec4; transition:background .15s; }
  .pane-splitter:hover::after, .pane-splitter.dragging::after { background:var(--green); }
  .sidebar-splitter { grid-column:2; grid-row:1; align-self:stretch; }
  .plot-sheet-splitter { display:block; grid-column:2; grid-row:1 / 3; align-self:stretch; }
  .linked-sheet { grid-column:3; grid-row:1 / 3; margin-top:0; padding:13px 10px 7px; display:flex; flex-direction:column; min-height:0; height:100%; max-height:100%; overflow:hidden; align-self:start; position:sticky; top:0; }
  .sheet-head, .sheet-footer { display:flex; justify-content:space-between; gap:14px; align-items:center; }
  .sheet-head { flex:0 0 auto; min-height:0; overflow:visible; align-items:flex-start; }
  .sheet-head > div { display:flex; flex-direction:column; gap:1px; min-width:0; width:100%; }
  .sheet-head h2 { margin:0; line-height:1.3; }
  .sheet-head p { margin:0; color:var(--muted); font-size:12px; line-height:1.25; }
  #sheetSource { display:none; }
  .sheet-controls { flex:0 0 auto; display:grid; grid-template-columns:minmax(190px,1fr) minmax(135px,175px); column-gap:18px; align-items:end; margin-top:3px; }
  .sheet-controls label { margin:3px 0 2px; }
  .sheet-controls label:nth-child(2) { justify-self:end; width:175px; }
  .linked-sheet > .hint { margin:1px 0 2px; line-height:1.25; }
  .sheet-hint { white-space:normal; }
  .linked-table-wrap { flex:1 1 auto; height:auto; min-height:150px; max-height:none; overflow:auto; border:1px solid var(--border); border-radius:8px; margin-top:2px; background:#fff; }
  #linkedTable { min-width:100%; width:max-content; }
  #linkedTable tbody tr { cursor:pointer; }
  #linkedTable tbody tr:nth-child(even) { background:#f7faf8; }
  #linkedTable tbody tr:hover { background:#eaf4ec; }
  #linkedTable tbody tr.selected-row { background:#bfe2c6; box-shadow:inset 5px 0 #2f7d43, inset 0 0 0 2px #7b2cbf; }
  .contrast-controls { display:grid; gap:8px; margin-bottom:12px; padding:10px; border:1px solid var(--border); border-radius:9px; background:#f8fbf8; }
  .contrast-controls[hidden] { display:none !important; }
  .preview-actions { justify-content:flex-end; margin-left:auto; }
  .code-dialog { width:min(1120px,92vw); height:min(760px,88vh); }
  .code-toolbar { display:flex; gap:12px; align-items:end; margin:8px 0 12px; }
  .code-toolbar label { flex:1; }
  .code-view { height:calc(100% - 160px); min-height:420px; overflow:auto; white-space:pre; background:#17201a; color:#eaf4ec; border-radius:9px; padding:14px; font:12.5px/1.5 Consolas,"Courier New",monospace; tab-size:2; }
  #linkedTable tbody tr.related-row { background:#e8f2ff; }
  #linkedTable th { cursor:pointer; user-select:none; z-index:2; }
  #linkedTable th[draggable="true"] { cursor:grab; }
  #linkedTable th.dragging { opacity:.45; background:#dfece2; }
  #linkedTable th.drag-over { box-shadow:inset 3px 0 var(--green); }
  #linkedTable th.sorted { background:#cfe8d4; }
  #linkedTable td.identity-cell { color:var(--green-dark); font-weight:700; }
  .sheet-footer { flex:0 0 auto; margin-top:7px; color:var(--muted); font-size:12px; align-items:flex-end; flex-wrap:wrap; }
  .sheet-navigation { display:flex; align-items:flex-end; justify-content:flex-end; gap:7px; flex-wrap:nowrap; }
  .sheet-jump { display:flex; align-items:stretch; gap:8px; flex-wrap:nowrap; margin-right:4px; }
  .jump-card { min-width:132px; padding:6px 8px; border:1px solid var(--border); border-radius:8px; background:#f8faf8; }
  .jump-title { display:block; color:var(--green-dark); font-size:11px; font-weight:700; margin-bottom:4px; }
  .jump-input-row { display:flex; align-items:center; gap:8px; }
  .jump-input-row input { width:72px; padding:5px 6px; margin:0; }
  .jump-input-row button, .sheet-pages button { padding:6px 9px; }
  .sheet-pages { margin-left:6px; }
  .sheet-pages { margin-top:0; }
  .sheet-page-actions { display:flex; flex-direction:column; align-items:stretch; gap:5px; }
  #sheetExportExcel { padding:6px 9px; color:var(--green-dark); font-weight:700; background:#eef7f0; }
  .contig-picker { margin:10px 0 8px; padding:9px 10px; border:1px solid var(--border); border-radius:8px; background:#fbfdfb; }
  .contig-picker-head { display:flex; align-items:center; justify-content:space-between; gap:8px; margin-bottom:7px; color:var(--green-dark); font-size:12px; }
  .contig-picker-head span { display:flex; gap:5px; }
  .contig-picker-head button { padding:3px 8px; min-height:27px; font-size:11px; }
  .contig-check-list { display:grid; grid-template-columns:repeat(auto-fit,minmax(145px,1fr)); gap:5px 8px; max-height:132px; overflow:auto; padding:2px 1px; }
  .contig-check-item { display:flex; align-items:center; gap:6px; min-width:0; font-size:12px; color:var(--ink); }
  .contig-check-item input { margin:0; flex:none; }
  .contig-check-item span { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .contig-check-item .contig-color-input { width:30px; height:24px; min-width:30px; padding:1px; border:1px solid var(--border); border-radius:5px; background:#fff; cursor:pointer; }
  .export-panel { width:100%; margin-top:14px; scroll-margin-top:16px; align-self:start; }
  .export-grid { display:grid; grid-template-columns:repeat(3, minmax(140px, 1fr)); gap:8px 12px; }
  .export-actions { justify-content:flex-start; }
  .export-panel.export-focus { box-shadow:0 0 0 3px rgba(63,133,79,.20); transition:box-shadow .2s; }
  dialog { width:min(1200px, 92vw); max-height:85vh; border:1px solid var(--border); border-radius:10px; padding:14px; }
  dialog::backdrop { background:rgba(0,0,0,.28); }
  .dialog-head { display:flex; justify-content:space-between; align-items:center; }
  .typography-dialog { width:min(620px, 92vw); }
  .dialog-copy { color:var(--muted); margin:4px 0 12px; }
  .typography-grid { display:grid; grid-template-columns:2fr 1fr; gap:12px; }
  .color-row { display:grid; grid-template-columns:54px minmax(120px, 180px); gap:8px; align-items:center; }
  .style-options { display:flex; gap:18px; flex-wrap:wrap; margin:14px 0 10px; padding:10px 12px; border:1px solid var(--border); border-radius:7px; }
  .style-options legend { color:var(--green-dark); font-size:13px; font-weight:700; padding:0 5px; }
  .style-options label { margin:0; }
  .typography-sample-wrap { border:1px solid var(--border); border-radius:8px; background:#f8faf8; padding:10px 12px; }
  .typography-sample-wrap > span { display:block; color:var(--muted); font-size:11px; font-weight:700; text-transform:uppercase; margin-bottom:7px; }
  #typographySample { min-height:34px; overflow-wrap:anywhere; }
  .dialog-actions { justify-content:flex-end; }
  .table-wrap { max-height:70vh; overflow:auto; }
  table { border-collapse:collapse; width:100%; font-size:12px; }
  th, td { border:1px solid #dbe4dd; padding:5px 7px; white-space:nowrap; }
  th { position:sticky; top:0; background:var(--green-soft); color:var(--green-dark); }
  @media (max-width:1250px) { .main-panel,.main-panel.plot-large,.main-panel.plot-circos,.main-panel.plot-volcano,.main-panel.plot-genome { min-width:0; } .preview-status-actions { flex-wrap:wrap; } }
  @media (max-width:1000px) { html,body,#studio-app { overflow:auto; height:auto; } .workspace { grid-template-columns:1fr; overflow:visible; } .sidebar-splitter { display:none; } .sidebar { position:static; max-height:none; height:auto; overflow:visible; } .variable-list { max-height:180px; } .export-grid { grid-template-columns:repeat(2,1fr); } }
  @media (max-width:600px) { .topbar { align-items:flex-start; flex-direction:column; } .roles,.two-col,.three-col,.export-grid,.typography-grid { grid-template-columns:1fr; } .sheet-head { align-items:flex-start; flex-direction:column; } .sheet-navigation { justify-content:flex-start; } }
#sheetSource { display: none !important; }
  .function-cell { white-space:normal; min-width:210px; max-width:360px; line-height:1.25; overflow-wrap:anywhere; }
  .member-protein-cell { white-space:normal; max-width:180px; overflow-wrap:anywhere; }
</style>
<script src="/plotly.min.js"></script>
<script>
(() => {
  const moduleName = document.getElementById('studio-app').dataset.module;
  const fontFamilies = {
    'Arial': 'Arial, Helvetica, sans-serif',
    'Times New Roman': '"Times New Roman", Times, serif',
    'Calibri': 'Calibri, Candara, "Segoe UI", sans-serif',
    'Segoe UI': '"Segoe UI", Arial, sans-serif',
    'Helvetica': 'Helvetica, Arial, sans-serif',
    'Georgia': 'Georgia, "Times New Roman", serif',
    'Verdana': 'Verdana, Geneva, sans-serif',
    'Tahoma': 'Tahoma, Verdana, sans-serif',
    'Courier New': '"Courier New", Courier, monospace',
    'Garamond': 'Garamond, Georgia, serif'
  };
  const defaultTypography = () => ({font:'Segoe UI',size:13,color:'#1e2a22',useThemeColor:true,bold:false,italic:false,underline:false});
  const repliconPalette=['#2f86d3','#5e9b68','#b58c3c','#8b69a4','#4c9a94','#b76a67','#6f7fb8','#8a9b45','#ba7fa3','#4f8e7b','#a8784e','#657b83'];
  const state = { tables: [], table: null, rows: [], columns: [], sheetColumnOrder:[], sheetDraggingColumn:null, roles: {x:null,y:null,value:null,color:null,size:null,label:null}, selectedVariable: null, figure: null, typography: defaultTypography(), moduleNames:new Map(), rowIndex:new WeakMap(), tracePointRows:[], rowPointMap:new Map(), selectedRows:new Set(), activeRow:null, memberSelection:null, memberReturnTerm:'', rowSubset:null, memberAnnotations:{}, sheetPage:0, sheetSort:null, sheetSortDirection:1, plotEventsBound:false,plotBlankWindowBound:false,plotBlankPress:null,lastPlotDataClickAt:0,plotDeselectSuppressedUntil:0,plotSelectionTransaction:0,plotHoverTimer:null,plotSelectionInfo:null,circosHoverRow:null, contrastTables:[], contrastTableKey:null, allContrastsKey:null, allContrastRowsKey:null, analysisSource:'', volcanoCountPositions:{down:{x:.12,y:1.055},up:{x:.88,y:1.055}}, contigSelections:{Histogram:new Set(),Circos:new Set(),'Genome region':new Set()}, contigSelectionInitialized:{Histogram:false,Circos:false,'Genome region':false}, histogramContigColors:new Map(), genomeRegionViewRange:null, genomeRegionRenderedRange:null, genomeRegionViewKey:'', genomeRegionPanTimer:null, genomeRegionGuideTimer:null, genomeRegionGuidePendingRange:null, genomeRegionApplyingRange:false, genomeRegionLockedSpan:null, genomeRegionYRange:null, pendingBakedSelectionView:null, circosAngularView:null, circosCamera:{x:0,y:0,scale:1}, circosCameraDrag:null };
  const $ = id => document.getElementById(id);
  function studioPlotIsDisplayed(graph=$('plot')){return Boolean(graph&&graph.isConnected&&!graph.hidden&&graph?._fullLayout&&graph.getClientRects?.().length&&getComputedStyle(graph).display!=='none');}
  function safeStudioResize(graph=$('plot')){if(!studioPlotIsDisplayed(graph))return Promise.resolve();try{return Promise.resolve(Plotly.Plots.resize(graph)).catch(()=>{});}catch(_err){return Promise.resolve();}}
  function webglAvailable(){
    try{const canvas=document.createElement('canvas');return Boolean(window.WebGL2RenderingContext&&canvas.getContext('webgl2'))||Boolean(window.WebGLRenderingContext&&(canvas.getContext('webgl')||canvas.getContext('experimental-webgl')));}catch(_err){return false;}
  }
  const PERFORMANCE_RENDERING=webglAvailable();
  // One shared studio shell is used for DE, GO/enrichment, and network reports.
  // Module identity changes only the biologically relevant plot-type catalogue and data auto-assignment.
  const plotTypesByModule = {
    // MA is supplied by the finalized DE analysis below. Keeping a second
    // generic MA implementation made the two views disagree about linked rows.
    de: ['Volcano','Circos','Genome region','Scatter','Violin + box','Histogram'],
    enrichment: ['Dot plot','Bar','Scatter','Heatmap','Network','Histogram'],
    network: ['Network','Scatter','Bar','Violin + box','Heatmap','Line','Histogram'],
    combined: ['Network','Dot plot','Bar','Scatter','Heatmap','Line','Histogram']
  };
  const paper = {A0:[841,1189],A1:[594,841],A2:[420,594],A3:[297,420],A4:[210,297],A5:[148,210],Letter:[215.9,279.4],Legal:[215.9,355.6],Square:[210,210]};

  function esc(value) { return String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])); }
  function numeric(value) { const n = Number(value); return Number.isFinite(n) ? n : null; }
  function compactPlotNumber(value,digits=6) { const number=numeric(value);if(number===null)return 'NA';const absolute=Math.abs(number);if(absolute!==0&&(absolute<.001||absolute>=100000))return number.toExponential(Math.max(1,digits-2)).replace(/\.0+(?=e)/,'');return Number(number.toPrecision(digits)).toString(); }
  function wrapPlotHtml(value,width=38,maxLines=5) { const text=String(value??'').replace(/\s+/g,' ').trim();if(!text)return '';const words=[];for(const token of text.split(' ')){if(token.length<=width)words.push(token);else for(let offset=0;offset<token.length;offset+=width)words.push(token.slice(offset,offset+width));}const lines=[];let line='';for(const word of words){const next=line?line+' '+word:word;if(!line||next.length<=width)line=next;else{lines.push(line);line=word;if(lines.length>=maxLines-1)break;}}if(line&&lines.length<maxLines)lines.push(line);const used=lines.join(' ');if(used.length<text.length&&lines.length)lines[lines.length-1]=lines[lines.length-1].replace(/[.…]*$/,'')+'…';return lines.map(esc).join('<br>'); }
  function isEffectColumn(name) { return /log2.*fold/i.test(String(name||'')) || /logfc/i.test(String(name||'')) || /^effect([ _.-]|$)/i.test(String(name||'')); }
  function foldScale() { return moduleName==='de' && $('foldChangeScale') ? $('foldChangeScale').value : 'log2'; }
  function foldScaleLabel() { const scale=foldScale(); return scale==='raw'?'Fold change (ratio)':scale==='log10'?'log₁₀ fold change':scale==='ln'?'ln fold change':'log₂ fold change'; }
  function foldNeutral() { return foldScale()==='raw'?1:0; }
  function transformLog2Effect(value) {
    const v=numeric(value);if(v===null)return null;const scale=foldScale();
    if(scale==='raw'){const out=Math.pow(2,Math.max(-1022,Math.min(1023,v)));return Number.isFinite(out)?out:null;}
    if(scale==='log10')return v*Math.log10(2);
    if(scale==='ln')return v*Math.LN2;
    return v;
  }
  function displayedNumeric(row,name) { const v=numeric(row?.[name]);if(v===null)return null;return moduleName==='de'&&isEffectColumn(name)?transformLog2Effect(v):v; }
  function isModuleColumnName(name){return /^module([ _]?id|[ _]?name)?$/i.test(String(name||''));}
  function moduleColumnName(){return (state.columns||[]).find(c=>isModuleColumnName(c.name))?.name||null;}
  function renamedModule(value){const raw=String(value??'');return state.moduleNames?.get(raw)||raw;}
  function displayedValue(row,name) { if(!name)return null;if(['network','combined'].includes(moduleName)&&isModuleColumnName(name))return renamedModule(row?.[name]);const v=displayedNumeric(row,name);return v===null?row?.[name]:v; }
  function column(name) { return state.rows.map(row => row[name]); }
  function numericColumn(name) { return column(name).map(numeric); }
  function columnKind(name) { const col=state.columns.find(c=>c.name===name); return col ? col.kind : null; }
  function unique(values) { return [...new Set(values.filter(v => v !== null && v !== undefined && v !== ''))]; }
  function studioRowIndex(row) { const value=state.rowIndex.get(row); return Number.isInteger(value)?value:null; }
  function pointLink(rows) { return {rows:unique((rows||[]).filter(Number.isInteger))}; }
  function linkedTrace(trace, links) { trace.__studioRowLinks=links; return trace; }
  function walkPointLinks(node, path, visit) {
    if(node&&Array.isArray(node.rows)){visit(node,path);return;}
    if(Array.isArray(node))node.forEach((child,index)=>walkPointLinks(child,path.concat(index),visit));
  }
  function collectPlotLinks(data) {
    state.tracePointRows=data.map(trace=>{const links=trace.__studioRowLinks||[];delete trace.__studioRowLinks;return links;});
    state.rowPointMap=new Map();
    state.tracePointRows.forEach((links,curve)=>walkPointLinks(links,[],(link,path)=>link.rows.forEach(rowIndex=>{if(!state.rowPointMap.has(rowIndex))state.rowPointMap.set(rowIndex,[]);const pointNumber=path.length===1?path[0]:(data[curve]?.type==='heatmap'?[path[1],path[0]]:path);state.rowPointMap.get(rowIndex).push({curve,pointNumber});})));
  }
  function pointLinks(curve, pointNumber) {
    let node=state.tracePointRows[curve];
    const path=Array.isArray(pointNumber)?pointNumber:[pointNumber];
    for(const index of path){if(!Array.isArray(node))break;node=node[index];}
    if(node&&Array.isArray(node.rows))return node.rows;
    if(path.length===2){node=state.tracePointRows[curve];for(const index of [path[1],path[0]]){if(!Array.isArray(node))break;node=node[index];}if(node&&Array.isArray(node.rows))return node.rows;}
    return [];
  }
  function embeddedStudioRows(customdata) {
    if(!Array.isArray(customdata)||customdata[0]!=='__studio_rows__')return [];
    const tail=customdata.slice(1);
    if(tail.length&&tail.every(Number.isInteger))return unique(tail);
    return Number.isInteger(tail[0])?[tail[0]]:[];
  }
  function identityColumn() { return (state.columns.find(c=>/^(gene([ _]?id)?|symbol|locus([ _]?tag)?|term([ _]?(id|name))?|description|module|node)$/i.test(c.name))||state.columns[0]||{}).name||null; }
  function rowMatchesSearch(row, query) { if(!query)return true;return state.columns.some(c=>String(row[c.name]??'').toLowerCase().includes(query)); }
  function sheetColumns() {
    const names=state.columns.map(c=>c.name),known=new Set(names);
    const ordered=(state.sheetColumnOrder||[]).filter(name=>known.has(name));
    names.forEach(name=>{if(!ordered.includes(name))ordered.push(name);});
    state.sheetColumnOrder=ordered;
    return ordered.map(name=>state.columns.find(c=>c.name===name)).filter(Boolean);
  }
  function moveSheetColumn(source,target) {
    if(!source||!target||source===target)return;
    const order=sheetColumns().map(c=>c.name),from=order.indexOf(source),to=order.indexOf(target);
    if(from<0||to<0)return;
    order.splice(from,1);order.splice(to,0,source);state.sheetColumnOrder=order;renderLinkedSpreadsheet();
  }

  function orderedSheetIndices() {
    const query=$('sheetSearch').value.trim().toLowerCase();
    const base=state.rowSubset?.indices?.length?state.rowSubset.indices:state.rows.map((_,index)=>index);
    const indices=base.filter(index=>Number.isInteger(index)&&state.rows[index]&&rowMatchesSearch(state.rows[index],query));
    if(state.sheetSort){const name=state.sheetSort,direction=state.sheetSortDirection;indices.sort((a,b)=>{const av=state.rows[a][name],bv=state.rows[b][name],an=numeric(av),bn=numeric(bv);if(an!==null&&bn!==null)return direction*(an-bn);return direction*String(av??'').localeCompare(String(bv??''),undefined,{numeric:true,sensitivity:'base'});});}
    return indices;
  }
  function updateSelectionChip() {
    // Selection is communicated by the highlighted spreadsheet row and plot marker.
    // The former status badge was removed to give the table more vertical room.
  }
  function fitLinkedSheetToViewport() {
    const sheet=document.querySelector('.linked-sheet'),panel=document.querySelector('.main-panel'),workspace=panel?.closest('.workspace');if(!sheet||!panel)return;
    const rect=panel.getBoundingClientRect(),top=Math.max(0,rect.top),workspaceRect=workspace?.getBoundingClientRect?.(),available=Math.max(360,Math.floor(workspaceRect?workspaceRect.bottom-rect.top-12:window.innerHeight-top-8));
    panel.style.setProperty('--panel-height',available+'px');
    // --panel-height is the shared bottom boundary for both columns. The plot
    // occupies the grid space left below its guide/toolbar, while the linked
    // spreadsheet spans both rows, so their lower borders stay exactly level.
    sheet.style.height='';sheet.style.maxHeight='';
    const frame=currentSpecializedFrame();if(frame)frame.style.height='';
    requestAnimationFrame(()=>{if(state.figure)safeStudioResize();});
  }
  function sheetPageSizeFor(totalRows) {
    const mode=$('sheetPageSize')?.value||'100';
    if(mode==='all')return Math.max(1,totalRows||1);
    if(mode==='custom')return Math.max(1,Math.min(100000,Math.trunc(Number($('sheetCustomPageSize')?.value)||1000)));
    return Math.max(1,Math.trunc(Number(mode)||100));
  }
  function updateSheetPageSizeControls() {
    const custom=$('sheetPageSize')?.value==='custom',label=$('sheetCustomPageSizeLabel');if(label)label.hidden=!custom;
  }
  function memberAnnotation(gene){
    const raw=state.memberAnnotations?.[String(gene||'')]||{};
    return {function:String(raw.function||''),protein:String(raw.protein||'')};
  }
  function rowGeneAnnotations(rowIndices){
    const identity=identityColumn(),names=(state.columns||[]).map(column=>String(column.name||''));if(!identity)return {};
    // The workbook's literal `product` field is authoritative. Only use the
    // broader aliases when that exact column is absent from the selected sheet.
    const productColumn=names.find(name=>name==='product')||names.find(name=>name.toLowerCase()==='product')||names.find(name=>/^(protein[ _]?name|function|description|annotation)$/i.test(name));
    const proteinColumn=names.find(name=>/^(protein[ _]?(accession|id)|accession)$/i.test(name));
    const annotations={};
    unique(rowIndices||[]).forEach(index=>{const row=state.rows[index],gene=String(row?.[identity]??'').trim();if(!gene)return;const product=productColumn?String(row?.[productColumn]??'').trim():'',protein=proteinColumn?String(row?.[proteinColumn]??'').trim():'';annotations[gene]={product,function:product,protein};});
    return annotations;
  }
  function renderMemberSpreadsheet() {
    const sel=state.memberSelection;if(!sel)return false;
    const query=$('sheetSearch').value.trim().toLowerCase(),all=(sel.genes||[]).map((gene,index)=>({gene,index,...memberAnnotation(gene)})),filtered=all.filter(d=>!query||d.gene.toLowerCase().includes(query)||d.function.toLowerCase().includes(query)||d.protein.toLowerCase().includes(query)||String(sel.label||'').toLowerCase().includes(query)||String(sel.term_id||'').toLowerCase().includes(query));
    const pageSize=sheetPageSizeFor(filtered.length),pages=Math.max(1,Math.ceil(filtered.length/pageSize));state.sheetPage=Math.max(0,Math.min(state.sheetPage,pages-1));const start=state.sheetPage*pageSize,page=filtered.slice(start,start+pageSize);
    $('linkedSheetTitle').textContent=`Member genes / proteins · ${sel.label||sel.term_id||'selection'}`;$('sheetBackToResults').hidden=false;
    $('linkedTable').innerHTML=`<thead><tr><th>#</th><th>Gene / protein ID</th><th>Function / product</th><th>Protein accession</th><th>Selected term / component</th><th>Term / component ID</th></tr></thead><tbody>${page.map((d,i)=>`<tr data-member-gene="${esc(d.gene)}"><td>${start+i+1}</td><td class="identity-cell" title="${esc(d.gene)}">${esc(d.gene)}</td><td class="function-cell" title="${esc(d.function||'Function not available in the finalized annotation')} ">${esc(d.function||'')}</td><td class="member-protein-cell" title="${esc(d.protein)}">${esc(d.protein)}</td><td>${esc(sel.label||'')}</td><td>${esc(sel.term_id||'')}</td></tr>`).join('')}</tbody>`;
    $('linkedTable').querySelectorAll('tbody tr[data-member-gene]').forEach(row=>row.addEventListener('click',()=>{const gene=row.dataset.memberGene||'',alreadySelected=row.classList.contains('selected-row');$('linkedTable').querySelectorAll('tbody tr').forEach(x=>x.classList.remove('selected-row'));if(alreadySelected){sendSpecializedCommand('clearSelection');$('plotMessage').textContent='Cleared the selected gene; the member list remains open.';return;}row.classList.add('selected-row');const frame=currentSpecializedFrame();if(frame&&!frame.hidden&&frame.contentWindow)frame.contentWindow.postMessage({type:'bra-highlight-gene',gene},'*');}));
    $('sheetPageSummary').textContent=filtered.length?`Genes/proteins ${start+1}–${Math.min(start+pageSize,filtered.length)} of ${filtered.length.toLocaleString()} · Page ${state.sheetPage+1} of ${pages}`:'No member genes/proteins were available for this item.';
    $('sheetJumpRow').max=Math.max(1,filtered.length);$('sheetJumpPage').max=Math.max(1,pages);$('sheetPrevious').disabled=state.sheetPage<=0;$('sheetNext').disabled=state.sheetPage>=pages-1;requestAnimationFrame(fitLinkedSheetToViewport);return true;
  }
  function postDEGenesToSpecialized(rowIndices) {
    if(!specializedActive()||(moduleName!=='de'&&!/kegg[_ ]pathway[_ ]maps/i.test(currentSpecializedFrame()?.src||'')))return false;
    const identity=identityColumn(),genes=identity?unique((rowIndices||[]).map(index=>String(state.rows[index]?.[identity]??'').trim()).filter(Boolean)):[];
    const frame=currentSpecializedFrame();if(!genes.length||!frame||frame.hidden||!frame.contentWindow)return false;
    frame.contentWindow.postMessage({type:'bra-highlight-genes',genes,annotations:rowGeneAnnotations(rowIndices)},'*');
    return true;
  }
  function showSpecializedMembers(payload,sourceWindow=null){
    if(payload?.annotations&&typeof payload.annotations==='object'){state.memberAnnotations=state.memberAnnotations||{};for(const[gene,annotation]of Object.entries(payload.annotations)){if(!annotation||typeof annotation!=='object')continue;state.memberAnnotations[gene]={...state.memberAnnotations[gene],...Object.fromEntries(Object.entries(annotation).filter(([,value])=>typeof value==='string'&&value.trim()))};}}
    const termId=String(payload?.term_id||''),splitGenes=value=>String(value??'').split(/[\/;,|]+/).map(x=>x.trim()).filter(Boolean);let genes=unique((Array.isArray(payload?.genes)?payload.genes:[]).map(x=>String(x||'').trim()).filter(Boolean));
    // DE figures and the spreadsheet are two views of the same annotated gene
    // table. Never replace that table with the enrichment-style member sheet,
    // because doing so drops product/function columns.
    if(moduleName==='de'){
      const identity=identityColumn(),wanted=new Set((genes.length?genes:[termId]).map(value=>String(value||'').trim()).filter(Boolean));
      const hits=identity?state.rows.map((row,index)=>wanted.has(String(row?.[identity]??'').trim())?index:null).filter(Number.isInteger):[];
      if(hits.length>1){showRowSubset(hits,String(payload?.label||termId||'Selected plot group'));$('plotMessage').textContent=`Showing only the ${hits.length} annotated DE genes selected by this plot element.`;}
      else if(hits.length){selectSpreadsheetRows(hits,{reveal:true,focusPlot:false,syncSpecialized:false});$('plotMessage').textContent='Selected the annotated DE gene row from the analysis plot.';}
      else{$('sheetPageSummary').textContent='The selected gene is not present in the currently chosen DE result sheet. Choose its contrast table and try again.';}
      if(hits.length&&sourceWindow){const annotations=rowGeneAnnotations(hits);try{sourceWindow.postMessage({type:'bra-gene-annotations',annotations},'*');}catch(_err){}}
      return;
    }
    /* Older/sparse result tables may omit point customdata. Recover members from
       the linked enrichment row so clicking a biological mark still opens its
       genes instead of silently doing nothing. */
    if(!genes.length&&termId){const idColumn=(state.columns.find(c=>/^(id|term[_ ]?id|go[_ ]?id|pathway)$/i.test(c.name))||{}).name,geneColumn=(state.columns.find(c=>/^(geneid|gene[_ ]?id|genes|leadingedge|leading[_ ]edge|core[_ ]enrichment)$/i.test(String(c.name).replace(/[ .-]+/g,'')))||state.columns.find(c=>/gene|leading|core/i.test(c.name)))?.name;if(idColumn&&geneColumn){const row=state.rows.find(item=>String(item?.[idColumn]??'')===termId);if(row)genes=unique(splitGenes(row[geneColumn]));}}
    state.memberSelection={label:String(payload?.label||termId||'Selected item'),term_id:termId,genes};state.memberReturnTerm=state.memberSelection.term_id;state.sheetPage=0;$('sheetSearch').value='';renderLinkedSpreadsheet();
  }
  function showRowSubset(rowIndices,label='Selected plot group'){
    const indices=unique((rowIndices||[]).filter(index=>Number.isInteger(index)&&index>=0&&index<state.rows.length));if(!indices.length)return;
    state.memberSelection=null;state.memberReturnTerm='';state.rowSubset={indices,label:String(label||'Selected plot group')};state.selectedRows=new Set(indices);state.activeRow=indices[0];state.sheetPage=0;$('sheetSearch').value='';renderLinkedSpreadsheet();
  }
  function rerenderClearedBakedSelection(type){
    if(specializedActive()||!['Genome region','Circos'].includes(type))return false;
    const graph=$('plot'),updates={};for(const axis of ['xaxis','yaxis']){const range=graph?._fullLayout?.[axis]?.range;if(Array.isArray(range)&&range.length===2&&range.every(value=>numeric(value)!==null))updates[axis+'.range']=range.map(Number);}
    if(type==='Genome region'&&Array.isArray(updates['xaxis.range'])){state.genomeRegionViewRange=[...updates['xaxis.range']];state.genomeRegionLockedSpan=Math.max(Number.EPSILON,Math.abs(updates['xaxis.range'][1]-updates['xaxis.range'][0]));}
    state.pendingBakedSelectionView={type,updates};renderPlot();return true;
  }
  function restorePendingBakedSelectionView(type){
    const pending=state.pendingBakedSelectionView;if(!pending)return;state.pendingBakedSelectionView=null;if(pending.type!==type)return;if(Object.keys(pending.updates||{}).length)try{Plotly.relayout('plot',pending.updates);}catch(_err){}
  }
  function restoreOverallResults(){
    const type=$('plotType')?.value||'',hadSelection=Boolean(state.memberSelection||state.rowSubset||state.selectedRows.size);state.memberSelection=null;state.memberReturnTerm='';state.rowSubset=null;state.selectedRows=new Set();state.activeRow=null;state.sheetPage=0;$('sheetSearch').value='';$('linkedSheetTitle').textContent='Linked Excel spreadsheet';$('sheetBackToResults').hidden=true;renderLinkedSpreadsheet();if(!hadSelection||!rerenderClearedBakedSelection(type))clearPlotSelection();sendSpecializedCommand('clearSelection');
  }
  function restoreEnrichmentResults(){
    restoreOverallResults();
  }
  function renderLinkedSpreadsheet(revealIndex=null) {
    if(state.memberSelection)return renderMemberSpreadsheet();
    $('linkedSheetTitle').textContent=state.rowSubset?`Selected rows · ${state.rowSubset.label}`:'Linked Excel spreadsheet';$('sheetBackToResults').hidden=!state.rowSubset;
    const indices=orderedSheetIndices(),pageSize=sheetPageSizeFor(indices.length);
    if(Number.isInteger(revealIndex)&&!indices.includes(revealIndex)){$('sheetSearch').value='';return renderLinkedSpreadsheet(revealIndex);}
    if(Number.isInteger(revealIndex)){const position=indices.indexOf(revealIndex);if(position>=0)state.sheetPage=Math.floor(position/pageSize);}
    const pages=Math.max(1,Math.ceil(indices.length/pageSize));state.sheetPage=Math.max(0,Math.min(state.sheetPage,pages-1));
    const start=state.sheetPage*pageSize,page=indices.slice(start,start+pageSize),identity=identityColumn(),displayColumns=sheetColumns();
    $('linkedTable').innerHTML=`<thead><tr><th>#</th>${displayColumns.map(c=>`<th draggable="true" data-column="${esc(c.name)}" class="${state.sheetSort===c.name?'sorted':''}" title="Click: ascending → descending → original order. Drag to rearrange columns.">${esc(c.name)}${state.sheetSort===c.name?(state.sheetSortDirection>0?' ▲':' ▼'):''}</th>`).join('')}</tr></thead><tbody>${page.map(index=>{const row=state.rows[index],classes=index===state.activeRow?'selected-row':state.selectedRows.has(index)?'related-row':'';return `<tr data-row-index="${index}" class="${classes}"><td>${index+1}</td>${displayColumns.map(c=>{const value=displayedValue(row,c.name);return `<td class="${c.name===identity?'identity-cell':''}" title="${esc(value)}">${esc(value)}</td>`;}).join('')}</tr>`;}).join('')}</tbody>`;
    $('linkedTable').querySelectorAll('tbody tr').forEach(row=>row.addEventListener('click',event=>{
      const index=Number(row.dataset.rowIndex);let selected=[index];
      if(event.shiftKey&&Number.isInteger(state.activeRow)){const start=Math.min(state.activeRow,index),end=Math.max(state.activeRow,index);selected=[];for(let value=start;value<=end;value++)selected.push(value);}
      else if(event.ctrlKey||event.metaKey){selected=[...state.selectedRows];const position=selected.indexOf(index);if(position>=0)selected.splice(position,1);else selected.push(index);}
      else if(state.selectedRows.size===1&&state.selectedRows.has(index))selected=[];
      selectSpreadsheetRows(selected,{reveal:true,focusPlot:true});
    }));
    $('linkedTable').querySelectorAll('th[data-column]').forEach(th=>{
      th.addEventListener('dragstart',event=>{state.sheetDraggingColumn=th.dataset.column;th.classList.add('dragging');event.dataTransfer.effectAllowed='move';event.dataTransfer.setData('text/plain',th.dataset.column);});
      th.addEventListener('dragover',event=>{event.preventDefault();event.dataTransfer.dropEffect='move';th.classList.add('drag-over');});
      th.addEventListener('dragleave',()=>th.classList.remove('drag-over'));
      th.addEventListener('drop',event=>{event.preventDefault();const source=event.dataTransfer.getData('text/plain')||state.sheetDraggingColumn;th.classList.remove('drag-over');moveSheetColumn(source,th.dataset.column);});
      th.addEventListener('dragend',()=>{state.sheetDraggingColumn=null;document.querySelectorAll('#linkedTable th').forEach(x=>x.classList.remove('dragging','drag-over'));});
      th.addEventListener('click',()=>{if(state.sheetDraggingColumn)return;const name=th.dataset.column;if(state.sheetSort!==name){state.sheetSort=name;state.sheetSortDirection=1;}else if(state.sheetSortDirection===1){state.sheetSortDirection=-1;}else{state.sheetSort=null;state.sheetSortDirection=1;}state.sheetPage=0;renderLinkedSpreadsheet();});
    });
    const pageMode=$('sheetPageSize')?.value;$('sheetPageSummary').textContent=indices.length?(pageMode==='all'?`All ${indices.length.toLocaleString()} filtered row${indices.length===1?'':'s'}`:`Rows ${start+1}–${Math.min(start+pageSize,indices.length)} of ${indices.length.toLocaleString()} · Page ${state.sheetPage+1} of ${pages}`):'No matching rows';
    $('sheetJumpRow').max=Math.max(1,indices.length);$('sheetJumpPage').max=Math.max(1,pages);
    $('sheetPrevious').disabled=state.sheetPage<=0;$('sheetNext').disabled=state.sheetPage>=pages-1;updateSelectionChip();
    requestAnimationFrame(fitLinkedSheetToViewport);
    if(Number.isInteger(revealIndex)){const selected=$(`linkedTable`).querySelector(`tr[data-row-index="${revealIndex}"]`),wrap=$('linkedTableWrap');if(selected&&wrap){requestAnimationFrame(()=>{const target=Math.max(0,selected.offsetTop-(wrap.clientHeight/2)+(selected.offsetHeight/2));wrap.scrollTo({top:target,behavior:'smooth'});});}}
  }
  function xmlEscape(value){return String(value??'').replace(/[&<>"']/g,char=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&apos;'}[char]));}
  function excelXmlCell(value){const number=typeof value==='number'?value:Number.NaN,type=Number.isFinite(number)?'Number':'String',content=type==='Number'?String(number):xmlEscape(value);return `<Cell><Data ss:Type="${type}">${content}</Data></Cell>`;}
  function excelSafeName(value){return String(value||'Linked results').replace(/[\\/:*?\[\]]+/g,' ').replace(/\s+/g,' ').trim().slice(0,31)||'Linked results';}
  function exportLinkedSheetExcel(){
    let columns=[],rows=[],sheetName='Linked results';
    if(state.memberSelection){
      const sel=state.memberSelection,query=$('sheetSearch').value.trim().toLowerCase();columns=['Gene / protein ID','Function / product','Protein accession','Selected term / component','Term / component ID'];
      rows=(sel.genes||[]).map(gene=>{const annotation=memberAnnotation(gene);return [gene,annotation.function,annotation.protein,sel.label||'',sel.term_id||''];}).filter(row=>!query||row.some(value=>String(value??'').toLowerCase().includes(query)));sheetName=sel.label||sel.term_id||'Member genes';
    }else{
      const displayColumns=sheetColumns();columns=displayColumns.map(column=>column.name);rows=orderedSheetIndices().map(index=>displayColumns.map(column=>displayedValue(state.rows[index],column.name)));sheetName=state.table?.label||$('tableSelect')?.selectedOptions?.[0]?.textContent||'Linked results';
    }
    const header=`<Row>${columns.map(excelXmlCell).join('')}</Row>`,body=rows.map(row=>`<Row>${row.map(excelXmlCell).join('')}</Row>`).join(''),name=excelSafeName(sheetName),xml=`<?xml version="1.0" encoding="UTF-8"?><?mso-application progid="Excel.Sheet"?><Workbook xmlns="urn:schemas-microsoft-com:office:spreadsheet" xmlns:o="urn:schemas-microsoft-com:office:office" xmlns:x="urn:schemas-microsoft-com:office:excel" xmlns:ss="urn:schemas-microsoft-com:office:spreadsheet"><Worksheet ss:Name="${xmlEscape(name)}"><Table>${header}${body}</Table></Worksheet></Workbook>`;
    downloadBlob(new Blob([xml],{type:'application/vnd.ms-excel;charset=utf-8'}),name.replace(/\s+/g,'_')+'.xls');
  }
  function removeSelectionOverlay() {
    const graph=$('plot');if(!graph||!Array.isArray(graph.data))return Promise.resolve();
    const indices=[];graph.data.forEach((trace,index)=>{if(trace&&trace.meta==='__studio_selection_overlay__')indices.push(index);});
    if(indices.length)try{return Promise.resolve(Plotly.deleteTraces('plot',indices)).catch(()=>{});}catch(_err){}
    return Promise.resolve();
  }
  function markStudioSelectionInfo() {
    const graph=$('plot'),groups=[...(graph?.querySelectorAll?.('.infolayer .annotation')||[])],annotations=Array.isArray(graph?.layout?.annotations)?graph.layout.annotations:[];
    groups.forEach((group,index)=>group.classList.toggle('bra-selection-info-annotation',String(annotations[index]?.name||'')==='BRA_STUDIO_SELECTION_INFO'));
  }
  function removeStudioSelectionInfo() {
    const graph=$('plot');if(!graph?.layout)return Promise.resolve();const annotations=(Array.isArray(graph.layout.annotations)?graph.layout.annotations:[]).filter(annotation=>String(annotation?.name||'')!=='BRA_STUDIO_SELECTION_INFO');
    try{return Promise.resolve(Plotly.relayout('plot',{annotations})).then(()=>markStudioSelectionInfo()).catch(()=>{});}catch(_err){return Promise.resolve();}
  }
  function deStatusForRow(row) {
    const statusColumn=(state.columns||[]).find(column=>/^(status|direction|regulation)$/i.test(String(column.name||'')))?.name;if(statusColumn&&String(row?.[statusColumn]??'').trim())return String(row[statusColumn]);
    const foldColumn=(state.columns||[]).find(column=>isEffectColumn(column.name))?.name,pColumn=(state.columns||[]).find(column=>/^(padj|fdr|adj[._ ]?p([._ ]?val(ue)?)?|p\.adjust)$/i.test(String(column.name||'')))?.name,fold=numeric(row?.[foldColumn]),p=numeric(row?.[pColumn]),foldCutoff=Math.max(0,Number($('volcanoLfcCutoff')?.value)||1),pCutoff=Math.max(Number.MIN_VALUE,Number($('volcanoPCutoff')?.value)||.05);if(fold===null||p===null||p>pCutoff||Math.abs(fold)<foldCutoff)return 'Not significant';return fold>0?'Upregulated':'Downregulated';
  }
  function studioSelectionInfoAnnotation(reference,rowIndex) {
    const type=$('plotType')?.value;if(!['Volcano','Scatter'].includes(type)||!Number.isInteger(rowIndex)||!$('autoSelectionInfo')?.checked)return null;const graph=$('plot'),trace=graph?.data?.[reference?.curve],point=reference?.pointNumber;if(!trace||!Number.isInteger(point))return null;const x=trace.x?.[point],y=trace.y?.[point];if(x===undefined||y===undefined)return null;const row=state.rows[rowIndex],identity=identityColumn(),gene=String(row?.[identity]??`Row ${rowIndex+1}`),custom=Array.isArray(trace.customdata?.[point])?trace.customdata[point]:[],lines=[`<b>${wrapPlotHtml(gene,34,2)}</b>`];
    if(type==='Volcano'){
      const effectColumn=state.roles.x,pColumn=state.roles.y,analysisEffect=numeric(row?.[effectColumn]),rawP=numeric(row?.[pColumn]),status=String(custom[2]||deStatusForRow(row));
      lines.push(`${esc(foldScaleLabel())}: ${compactPlotNumber(x,5)}`,`analysis log₂ FC: ${compactPlotNumber(analysisEffect,5)}`,`−log₁₀(${esc(prettyAxisName(pColumn))}): ${compactPlotNumber(y,5)}`,`${esc(prettyAxisName(pColumn))}: ${compactPlotNumber(rawP,5)}`,`status: ${esc(status)}`);
    }else{
      const xColumn=state.roles.x,yColumn=state.roles.y,pColumn=(state.columns||[]).find(column=>/^(padj|fdr|adj[._ ]?p([._ ]?val(ue)?)?|p\.adjust)$/i.test(String(column.name||'')))?.name;
      lines.push(`${esc(prettyAxisName(xColumn))}: ${compactPlotNumber(x,5)}`,`${esc(prettyAxisName(yColumn))}: ${compactPlotNumber(y,5)}`);if(pColumn&&!([xColumn,yColumn].includes(pColumn)))lines.push(`${esc(prettyAxisName(pColumn))}: ${compactPlotNumber(row?.[pColumn],5)}`);lines.push(`Status: ${esc(deStatusForRow(row))}`,`<b>Click to select this gene<br>in the linked spreadsheet</b>`);
    }
    const xAxis=graph?._fullLayout?.xaxis,yAxis=graph?._fullLayout?.yaxis,toPixel=(axis,value)=>{try{const converted=typeof axis?.d2p==='function'?axis.d2p(value):(typeof axis?.l2p==='function'?axis.l2p(value):NaN);return Number(converted);}catch(_err){return NaN;}},xPixel=toPixel(xAxis,x),yPixel=toPixel(yAxis,y),xLength=Math.max(1,Number(xAxis?._length)||1),yLength=Math.max(1,Number(yAxis?._length)||1),onRight=Number.isFinite(xPixel)&&xPixel>xLength*.58,nearTop=Number.isFinite(yPixel)&&yPixel<yLength*.32;
    return {name:'BRA_STUDIO_SELECTION_INFO',x,y,xref:trace.xaxis||'x',yref:trace.yaxis||'y',text:lines.join('<br>'),showarrow:true,arrowhead:0,arrowwidth:1.25,arrowcolor:'#6a8f7d',ax:onRight?-42:42,ay:nearTop?58:-58,xanchor:onRight?'right':'left',yanchor:nearTop?'top':'bottom',align:'left',bgcolor:'rgba(255,255,255,.97)',bordercolor:'#6a8f7d',borderwidth:1.1,borderpad:6,font:{color:graphFont().color,size:12},captureevents:false};
  }
  function refreshStudioSelectionInfo() {
    const graph=$('plot'),selection=state.plotSelectionInfo;if(!graph?.layout)return Promise.resolve();const annotations=(Array.isArray(graph.layout.annotations)?graph.layout.annotations:[]).filter(annotation=>String(annotation?.name||'')!=='BRA_STUDIO_SELECTION_INFO'),annotation=selection?studioSelectionInfoAnnotation(selection.reference,selection.rowIndex):null;if(annotation)annotations.push(annotation);try{return Promise.resolve(Plotly.relayout('plot',{annotations})).then(()=>markStudioSelectionInfo()).catch(()=>{});}catch(_err){return Promise.resolve();}
  }
  function suppressPlotDeselect(delay=1200){state.plotDeselectSuppressedUntil=Math.max(Number(state.plotDeselectSuppressedUntil||0),Date.now()+delay);}
  function clearPlotSelection({preserveTransaction=false}={}) {
    if(!preserveTransaction)state.plotSelectionTransaction+=1;
    clearTimeout(state.plotHoverTimer);state.plotHoverTimer=null;
    suppressPlotDeselect();state.plotSelectionInfo=null;const graph=$('plot'),jobs=[removeSelectionOverlay(),removeStudioSelectionInfo()],fastCircos=$('plotType')?.value==='Circos';
    // Circos can contain many SVG/WebGL traces. Its visible selection is the
    // final overlay ring, so clearing every trace's selectedpoints is wasted work.
    if(!fastCircos)(graph?.data||[]).forEach((trace,curve)=>{if(trace?.meta==='__studio_selection_overlay__'||!['scatter','scattergl','scatterpolar','bar','barpolar','violin'].includes(trace?.type))return;try{jobs.push(Promise.resolve(Plotly.restyle('plot',{selectedpoints:null},[curve])));}catch(_err){}});
    if($('plotType')?.value==='Bar')applyBarTickHighlight([]);
    try{Plotly.Fx.unhover('plot');}catch(_err){}
    return Promise.allSettled(jobs);
  }
  function applyBarTickHighlight(rowIndices){
    if(!state.figure||$('plotType')?.value!=='Bar')return;const orientation=$('barOrientation')?.value||'v',axis=orientation==='h'?'yaxis':'xaxis',values=[],selectedValues=new Set(),wanted=new Set(rowIndices||[]);
    (state.figure.data||[]).forEach((trace,curve)=>{if(trace?.type!=='bar')return;const categories=orientation==='h'?trace.y:trace.x;(categories||[]).forEach((value,point)=>{const text=String(value??'');if(!values.includes(text))values.push(text);const rows=pointLinks(curve,point);if(rows.some(row=>wanted.has(row)))selectedValues.add(text);});});
    if(!values.length)return;try{Plotly.relayout('plot',{[axis+'.tickmode']:'array',[axis+'.tickvals']:values,[axis+'.ticktext']:values.map(value=>selectedValues.has(value)?'<b>'+esc(value)+'</b>':value)});}catch(_err){}
  }
  function addSelectionOverlay(references,rowIndices=[]) {
    const graph=$('plot');if(!graph||!Array.isArray(graph.data)||!references.length)return Promise.resolve();
    const identity=identityColumn(),cartesian=[],polar=[];
    references.slice(0,25).forEach((ref,index)=>{const trace=graph.data[ref.curve];if(!trace)return;const pn=ref.pointNumber;if(!Number.isInteger(pn))return;const rowIndex=rowIndices[Math.min(index,rowIndices.length-1)],label=(Number.isInteger(rowIndex)&&identity)?String(state.rows[rowIndex]?.[identity]??''):'';
      if(trace.type==='scatterpolar'){const theta=trace.theta?.[pn],r=trace.r?.[pn];if(theta!==undefined&&r!==undefined)polar.push({kind:'point',theta,r,label});}
      else if(trace.type==='barpolar'){const theta=trace.theta?.[pn],rv=numeric(trace.r?.[pn]),base=Array.isArray(trace.base)?numeric(trace.base[pn]):numeric(trace.base),width=Array.isArray(trace.width)?numeric(trace.width[pn]):numeric(trace.width),log2=numeric(trace.customdata?.[pn]?.[4]);if(theta!==undefined&&rv!==null&&base!==null)polar.push({kind:'bar',theta,r:rv,base,width:width||1,label,direction:log2!==null&&log2<0?-1:1});}
      else if(['scatter','scattergl','bar','violin'].includes(trace.type)){const x=trace.x?.[pn]??trace.name,y=trace.y?.[pn],valueAt=value=>(Array.isArray(value)||ArrayBuffer.isView(value))?value[pn]:value,rawColor=valueAt(trace.marker?.color),rawSize=Number(valueAt(trace.marker?.size)),rawSymbol=valueAt(trace.marker?.symbol),pointColor=validHexColor(rawColor)||(/^rgba?\(/i.test(String(rawColor||''))?String(rawColor):selectedDataColor());if(x!==undefined&&y!==undefined)cartesian.push({x,y,label,color:pointColor,size:Math.max(7,Math.min(14,Number.isFinite(rawSize)?rawSize:9)),symbol:typeof rawSymbol==='string'&&rawSymbol?rawSymbol:'circle'});}
    });
    const overlays=[];
    if(cartesian.length){
      if($('plotType')?.value==='Circos'){
        /* Circos uses one clean open ring at the free radial tip. Avoid the generic halo + inner-ring pair, which looks like multiple rings on a narrow radial bar. */
        overlays.push({type:'scatter',mode:'markers',x:cartesian.map(d=>d.x),y:cartesian.map(d=>d.y),meta:'__studio_selection_overlay__',showlegend:false,hoverinfo:'skip',marker:{size:16,symbol:'circle-open',color:selectedDataColor(),line:{width:2.6,color:selectedDataColor()}}});
      }else{
        overlays.push({type:'scatter',mode:'markers',x:cartesian.map(d=>d.x),y:cartesian.map(d=>d.y),meta:'__studio_selection_overlay__',showlegend:false,hoverinfo:'skip',marker:{size:36,symbol:'circle-open',color:'#f0a202',line:{width:4,color:'#f0a202'}}});
        overlays.push({type:'scatter',mode:'markers'+(cartesian.length===1&&cartesian[0].label?'+text':''),x:cartesian.map(d=>d.x),y:cartesian.map(d=>d.y),text:cartesian.map(d=>d.label),textposition:'top center',textfont:{size:14,color:selectedDataColor()},meta:'__studio_selection_overlay__',showlegend:false,hoverinfo:'skip',marker:{size:24,symbol:'circle-open',color:selectedDataColor(),line:{width:5,color:selectedDataColor()}}});
        // Redraw the actual selected datum last so coincident points and later
        // base traces cannot bury it inside the two open selection rings.
        overlays.push({type:'scatter',mode:'markers',x:cartesian.map(d=>d.x),y:cartesian.map(d=>d.y),meta:'__studio_selection_overlay__',showlegend:false,hoverinfo:'skip',marker:{size:cartesian.map(d=>d.size),symbol:cartesian.map(d=>d.symbol),color:cartesian.map(d=>d.color),opacity:1,line:{width:1.4,color:'#ffffff'}}});
      }
    }
    if(polar.length){
      const bars=polar.filter(d=>d.kind==='bar'),points=polar.filter(d=>d.kind!=='bar');
      if(bars.length){
        overlays.push({type:'barpolar',theta:bars.map(d=>d.theta),r:bars.map(d=>d.r),base:bars.map(d=>d.base),width:bars.map(d=>d.width),meta:'__studio_selection_overlay__',showlegend:false,hoverinfo:'skip',marker:{color:colorWithAlpha(selectedDataColor(),.10),line:{width:3,color:selectedDataColor()}},opacity:1});
        const selectedTips=bars.map(d=>Number(d.direction)<0?Number(d.base):Number(d.base)+Number(d.r));
        overlays.push({type:'scatterpolar',mode:'markers',theta:bars.map(d=>d.theta),r:selectedTips,meta:'__studio_selection_overlay__',showlegend:false,hoverinfo:'skip',marker:{size:24,symbol:'circle-open',color:selectedDataColor(),line:{width:4,color:selectedDataColor()}}});
      }
      if(points.length){overlays.push({type:'scatterpolar',mode:'markers',theta:points.map(d=>d.theta),r:points.map(d=>d.r),meta:'__studio_selection_overlay__',showlegend:false,hoverinfo:'skip',marker:{size:26,symbol:'circle-open',color:selectedDataColor(),line:{width:4,color:selectedDataColor()}}});}
    }
    if(overlays.length)try{return Promise.resolve(Plotly.addTraces('plot',overlays)).catch(()=>{});}catch(_err){}
    return Promise.resolve();
  }
  function ensurePointVisible(reference) {
    const graph=$('plot'),trace=state.figure?.data?.[reference.curve];if(!trace)return;
    const xPoint=Array.isArray(reference.pointNumber)?reference.pointNumber[0]:reference.pointNumber,yPoint=Array.isArray(reference.pointNumber)?reference.pointNumber[1]:reference.pointNumber,x=Array.isArray(trace.x)?numeric(trace.x[xPoint]):null,y=Array.isArray(trace.y)?numeric(trace.y[yPoint]):null,update={};
    const full=graph._fullLayout||{};
    if(x!==null&&Array.isArray(full.xaxis?.range)){const range=full.xaxis.range.map(numeric);if(range.every(v=>v!==null)&&(x<Math.min(...range)||x>Math.max(...range))){const span=Math.abs(range[1]-range[0])||2;update['xaxis.range']=[x-span/2,x+span/2];}}
    if(y!==null&&Array.isArray(full.yaxis?.range)){const range=full.yaxis.range.map(numeric);if(range.every(v=>v!==null)&&(y<Math.min(...range)||y>Math.max(...range))){const span=Math.abs(range[1]-range[0])||2;update['yaxis.range']=[Math.max(0,y-span/2),y+span/2];}}
    if(Object.keys(update).length)Plotly.relayout('plot',update);
  }
  function focusPlotRows(rowIndices,{scroll=true,hover=true}={}) {
    if(!state.figure)return;const type=$('plotType')?.value,fastCircos=type==='Circos',transaction=++state.plotSelectionTransaction,cleanup=clearPlotSelection({preserveTransaction:true});
    const references=[];rowIndices.forEach(index=>(state.rowPointMap.get(index)||[]).forEach(ref=>references.push(ref)));
    Promise.resolve(cleanup).then(async()=>{
      if(transaction!==state.plotSelectionTransaction)return;
      suppressPlotDeselect();
      const byCurve=new Map();references.forEach(ref=>{if(!byCurve.has(ref.curve))byCurve.set(ref.curve,[]);if(Number.isInteger(ref.pointNumber))byCurve.get(ref.curve).push(ref.pointNumber);});
      const selectionJobs=[];if(!fastCircos)(state.figure?.data||[]).forEach((trace,curve)=>{if(!['scatter','scattergl','scatterpolar','bar','barpolar','violin'].includes(trace?.type)||trace?.meta==='__studio_selection_overlay__')return;const points=unique(byCurve.get(curve)||[]);try{selectionJobs.push(Promise.resolve(Plotly.restyle('plot',{selectedpoints:[points]},[curve])));}catch(_err){}});await Promise.allSettled(selectionJobs);
      if(references.length){const primary=references[0],aggregate=['Bar','Histogram'].includes(type);if(type==='Bar')applyBarTickHighlight(rowIndices);if(!aggregate)await addSelectionOverlay(references,rowIndices);if(['Volcano','Scatter'].includes(type)){state.plotSelectionInfo={reference:primary,rowIndex:rowIndices[0]};await refreshStudioSelectionInfo();}if(!['MA plot','Circos'].includes(type))ensurePointVisible(primary);if(scroll)$('plot').scrollIntoView({behavior:'smooth',block:'center'});if(hover&&!['Bar','Circos','Volcano','Scatter','Histogram'].includes(type)){state.plotHoverTimer=setTimeout(()=>{if(transaction!==state.plotSelectionTransaction)return;try{Plotly.Fx.hover('plot',[{curveNumber:primary.curve,pointNumber:primary.pointNumber}]);}catch(_err){}},80);}$('plotMessage').textContent=`Focused graph element linked to spreadsheet row ${rowIndices[0]+1}.`;}
      else $('plotMessage').textContent='This spreadsheet row is not represented by the current graph roles or filters.';
    });
  }
  function focusDirectAggregateMark(point,rowIndices){
    if(!state.figure)return;const curve=Number(point?.curveNumber),pointNumber=Number(point?.pointNumber??point?.pointIndex);if(!Number.isInteger(curve)||!Number.isInteger(pointNumber))return;
    const transaction=++state.plotSelectionTransaction,cleanup=clearPlotSelection({preserveTransaction:true});Promise.resolve(cleanup).then(()=>{if(transaction!==state.plotSelectionTransaction)return;suppressPlotDeselect();try{Plotly.restyle('plot',{selectedpoints:[[pointNumber]]},[curve]);}catch(_err){}if($('plotType')?.value==='Bar')applyBarTickHighlight(rowIndices);});
  }
  function selectSpreadsheetRows(rowIndices,{reveal=false,focusPlot=false,syncSpecialized=true}={}) {
    const valid=unique(rowIndices.filter(index=>Number.isInteger(index)&&index>=0&&index<state.rows.length));state.selectedRows=new Set(valid);state.activeRow=valid.length?valid[0]:null;renderLinkedSpreadsheet(reveal?state.activeRow:null);if($('plotType').value==='Genome region'&&valid.length&&!specializedActive()){state.genomeRegionViewRange=null;state.genomeRegionRenderedRange=null;state.genomeRegionLockedSpan=null;renderPlot();return;}if(syncSpecialized&&valid.length&&postDEGenesToSpecialized(valid)){$('plotMessage').textContent=valid.length===1?'Focused the selected spreadsheet gene in the active analysis plot.':`Focused ${valid.length} selected spreadsheet genes in the active analysis plot.`;return;}if(focusPlot&&valid.length)focusPlotRows(valid);else if(!valid.length){clearPlotSelection();sendSpecializedCommand('clearSelection');$('plotMessage').textContent='Selection cleared.';}
  }
  function eventHitsStudioPlotDatum(event){
    const target=event?.target;if(!target||typeof target.closest!=='function')return false;
    return Boolean(target.closest('.point,.slice,.choroplethlocation,.box,.violin,.hm,.heatmap'));
  }
  function bindPlotSelectionEvents() {
    if(state.plotEventsBound||!$('plot').on)return;state.plotEventsBound=true;
    $('plot').on('plotly_afterplot',()=>markStudioSelectionInfo());
    $('plot').on('plotly_hover',event=>{if($('plotType').value!=='Circos')return;const point=event.points&&event.points[0],embedded=point?embeddedStudioRows(point.customdata):[];state.circosHoverRow=embedded.length?embedded[0]:null;$('plot').style.cursor=Number.isInteger(state.circosHoverRow)?'pointer':'';});
    $('plot').on('plotly_unhover',()=>{if($('plotType').value==='Circos'){$('plot').style.cursor='';setTimeout(()=>{state.circosHoverRow=null;},120);}});
    $('plot').on('plotly_click',event=>{state.lastPlotDataClickAt=Date.now();const point=event.points&&event.points[0];if(!point)return;const embedded=embeddedStudioRows(point.customdata);const rows=unique(embedded.length?embedded:(Array.isArray(point.pointNumbers)?point.pointNumbers:[point.pointNumber??point.pointIndex]).flatMap(number=>pointLinks(point.curveNumber,number)));if(rows.length){const type=$('plotType').value,directAggregate=['Histogram','Bar'].includes(type);if(type==='Histogram')showRowSubset(rows,String(point.customdata||'Histogram bin'));else selectSpreadsheetRows(rows,{reveal:true,focusPlot:false});if(directAggregate)focusDirectAggregateMark(point,rows);else if(type!=='Genome region')focusPlotRows(rows,{scroll:false,hover:true});$('plotMessage').textContent=type==='Histogram'?`Showing the ${rows.length} genes / rows in this histogram bin.`:`Selected ${rows.length} linked spreadsheet row${rows.length===1?'':'s'} from the graph.`;}});
    $('plot').on('plotly_selected',event=>{if(!event||!Array.isArray(event.points))return;const rows=unique(event.points.flatMap(point=>{const embedded=embeddedStudioRows(point.customdata);return embedded.length?embedded:pointLinks(point.curveNumber,point.pointNumber??point.pointIndex);}));if(rows.length)selectSpreadsheetRows(rows,{reveal:true,focusPlot:false});});
    $('plot').on('plotly_deselect',()=>{const now=Date.now();if(now<Number(state.plotDeselectSuppressedUntil||0)||now-Number(state.lastPlotDataClickAt||0)<550)return;if(state.rowSubset||state.memberSelection||state.selectedRows.size)restoreOverallResults();});
    $('plot').on('plotly_relayout',event=>{
      if(!event)return;const type=$('plotType').value;
      if(type==='Volcano'){[['down',0],['up',1]].forEach(([key,index])=>{const x=event[`annotations[${index}].x`],y=event[`annotations[${index}].y`];if(Number.isFinite(Number(x)))state.volcanoCountPositions[key].x=Number(x);if(Number.isFinite(Number(y)))state.volcanoCountPositions[key].y=Number(y);});return;}
      if(type!=='Genome region')return;
      if(state.genomeRegionApplyingRange)return;
      let a=numeric(event['xaxis.range[0]']),b=numeric(event['xaxis.range[1]']);
      if((a===null||b===null)&&Array.isArray(event['xaxis.range'])){a=numeric(event['xaxis.range'][0]);b=numeric(event['xaxis.range'][1]);}
      if(a===null||b===null||a===b)return;if(a>b)[a,b]=[b,a];
      // Pan must be translation-only. Preserve the raw relayout span before normalizing it, because Plotly commonly reports the range as one array rather than range[0]/range[1].
      const incomingA=a,incomingB=b,incomingSpan=Math.abs(incomingB-incomingA);
      const meta=state.figure?.data?.__genomeRegion,full=Array.isArray(meta?.fullRange)?meta.fullRange.map(Number):null,locked=Math.max(Number.EPSILON,Number(state.genomeRegionLockedSpan)||incomingSpan);
      let mid=(incomingA+incomingB)/2;a=mid-locked/2;b=mid+locked/2;if(full&&full.length===2&&full.every(Number.isFinite)){if(a<full[0]){b+=full[0]-a;a=full[0];}if(b>full[1]){a-=b-full[1];b=full[1];}a=Math.max(full[0],a);b=Math.min(full[1],b);}

      state.genomeRegionViewRange=[a,b];
      if(Math.abs(incomingSpan-locked)>Math.max(1e-7,locked*1e-8)){state.genomeRegionApplyingRange=true;Promise.resolve(Plotly.relayout('plot',{'xaxis.range':[a,b]})).finally(()=>{state.genomeRegionApplyingRange=false;});}
      state.genomeRegionGuidePendingRange=[a,b];clearTimeout(state.genomeRegionGuideTimer);state.genomeRegionGuideTimer=setTimeout(()=>{const pending=state.genomeRegionGuidePendingRange;if(Array.isArray(pending)&&pending.length===2)updateGenomeGuidePath(pending[0],pending[1]);},PERFORMANCE_RENDERING?78:38);
      const rendered=state.genomeRegionRenderedRange;
      if(!Array.isArray(rendered)||rendered.length!==2)return;
      const span=Math.max(Number.EPSILON,b-a),guard=span*.35;
      if(a>=rendered[0]+guard&&b<=rendered[1]-guard)return;
      clearTimeout(state.genomeRegionPanTimer);state.genomeRegionPanTimer=setTimeout(()=>{if($('plotType').value==='Genome region')renderPlot();},PERFORMANCE_RENDERING?360:140);
    });
    $('plot').addEventListener('wheel',event=>{const type=$('plotType').value;if(type==='Genome region'&&$('genomeRegionWheelZoom')&&$('genomeRegionWheelZoom').checked){event.preventDefault();zoomCurrentPlot(event.deltaY<0?.88:1.14);}},{passive:false});
    $('plot').addEventListener('pointerdown',event=>{if(event.button!==0||event.target?.closest?.('.modebar')||event.target?.closest?.('g.colorbar'))return;const time=Date.now();if(eventHitsStudioPlotDatum(event)){state.lastPlotDataClickAt=time;state.plotBlankPress=null;return;}state.plotBlankPress={time,x:event.clientX,y:event.clientY,moved:false};},true);
    // Plotly's drag cover receives releases outside the plot node. Window-level
    // completion makes blank clicks reliable for Genome region and Circos too.
    if(!state.plotBlankWindowBound){state.plotBlankWindowBound=true;
      window.addEventListener('pointermove',event=>{const press=state.plotBlankPress;if(press&&Math.hypot(event.clientX-press.x,event.clientY-press.y)>5)press.moved=true;},true);
      window.addEventListener('pointerup',event=>{const press=state.plotBlankPress;state.plotBlankPress=null;if(!press||press.moved||eventHitsStudioPlotDatum(event))return;setTimeout(()=>{if(Number(state.lastPlotDataClickAt||0)>=press.time)return;if(state.rowSubset||state.memberSelection||state.selectedRows.size)restoreOverallResults();},450);},true);
      window.addEventListener('pointercancel',()=>{state.plotBlankPress=null;},true);
    }
  }
  function themeTextColor() { return $('theme').value === 'dark' ? '#f3f5f3' : '#1e2a22'; }
  function graphFont() {
    const t=state.typography;
    return {family:fontFamilies[t.font]||fontFamilies['Segoe UI'],size:t.size,color:t.useThemeColor?themeTextColor():t.color};
  }
  function applyGenericTypographyCss(){
    const t=state.typography,family=fontFamilies[t.font]||fontFamilies['Segoe UI'],color=t.useThemeColor?themeTextColor():t.color;let style=$('genericTypographyCss');if(!style){style=document.createElement('style');style.id='genericTypographyCss';document.head.appendChild(style);}style.textContent=`#plot text,#plot .hoverlayer text{font-family:${family}!important;font-size:${t.size}px!important;font-weight:${t.bold?700:400}!important;font-style:${t.italic?'italic':'normal'}!important;text-decoration:${t.underline?'underline':'none'}!important;fill:${color}!important;}#plot .bra-selection-info-annotation text{font-size:${Math.min(Number(t.size)||13,12)}px!important;}`;
  }
  function typographyStyleNames(t=state.typography) {
    const styles=[]; if(t.bold)styles.push('Bold');if(t.italic)styles.push('Italic');if(t.underline)styles.push('Underlined');return styles.length?styles.join(', '):'Regular';
  }
  function updateTypographySummary() {
    const t=state.typography;
    $('typographySummary').textContent=`${t.font} · ${t.size} px · ${t.useThemeColor?'theme color':t.color.toUpperCase()} · ${typographyStyleNames(t)}`;
  }
  function validHexColor(value) {
    const text=String(value||'').trim();
    if(/^#[0-9a-f]{6}$/i.test(text))return text.toLowerCase();
    if(/^#[0-9a-f]{3}$/i.test(text))return '#'+text.slice(1).split('').map(c=>c+c).join('').toLowerCase();
    return null;
  }
  function colorToHex(value,fallback='#75bed1') {
    const direct=validHexColor(value);if(direct)return direct;
    const match=String(value||'').match(/rgba?\(\s*(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)/i);
    if(!match)return validHexColor(fallback)||'#75bed1';
    return '#'+match.slice(1,4).map(part=>Math.max(0,Math.min(255,Math.round(Number(part)||0))).toString(16).padStart(2,'0')).join('');
  }
  function plotColor(id,fallback) { const el=$(id); return validHexColor(el&&el.value)||fallback; }
  function generalDataColor(){return plotColor('generalDataColor','#377497');}
  function selectedDataColor(){return plotColor('selectedDataColor','#7b2cbf');}
  function upDataColor(){return plotColor('upDataColor','#ef5350');}
  function downDataColor(){return plotColor('downDataColor','#43a047');}
  function nsDataColor(){return plotColor('nsDataColor','#c9d0cc');}
  function statusDataColor(status){return status==='Upregulated'?upDataColor():status==='Downregulated'?downDataColor():nsDataColor();}
  function colorWithAlpha(color,alpha=.16){const hex=validHexColor(color);if(!hex)return color;const r=parseInt(hex.slice(1,3),16),g=parseInt(hex.slice(3,5),16),b=parseInt(hex.slice(5,7),16);return `rgba(${r},${g},${b},${Math.max(0,Math.min(1,alpha))})`;}
  function significanceTint(color,strength=.75){const hex=validHexColor(color);if(!hex)return color;const t=Math.max(0,Math.min(1,Number(strength)||0)),r=parseInt(hex.slice(1,3),16),g=parseInt(hex.slice(3,5),16),b=parseInt(hex.slice(5,7),16),mix=c=>Math.round(255-(255-c)*t);return `rgb(${mix(r)},${mix(g)},${mix(b)})`;}
  function typographyDraft() {
    return {font:$('fontFamily').value,size:Math.max(6,Math.min(72,Number($('fontSize').value)||13)),color:validHexColor($('fontColorHex').value)||$('fontColor').value,useThemeColor:$('useThemeFontColor').checked,bold:$('fontBold').checked,italic:$('fontItalic').checked,underline:$('fontUnderline').checked};
  }
  function updateTypographyColorState() {
    // Keep the manual controls usable even while automatic theme color is active.
    // If the user edits either color control we switch to manual color immediately.
    $('fontColor').disabled=false;$('fontColorHex').disabled=false;
    const automatic=$('useThemeFontColor').checked;
    $('fontColor').title=automatic?'Choose a color to switch from automatic theme text color to manual color':'Graph text color';
    $('fontColorHex').title=$('fontColor').title;
  }
  function updateTypographySample() {
    updateTypographyColorState();
    const t=typographyDraft(), sample=$('typographySample'), color=t.useThemeColor?themeTextColor():t.color;
    sample.style.fontFamily=fontFamilies[t.font]||fontFamilies['Segoe UI'];sample.style.fontSize=t.size+'px';sample.style.color=color;sample.style.fontWeight=t.bold?'700':'400';sample.style.fontStyle=t.italic?'italic':'normal';sample.style.textDecoration=t.underline?'underline':'none';
    $('typographyMessage').textContent='';
  }
  function setTypographyDraft(t) {
    // Preserve the user's manual fallback color even when automatic theme text
    // color is enabled; otherwise opening this dialog overwrote it with black/white.
    const color=validHexColor(t.color)||'#1e2a22';
    $('fontFamily').value=t.font;$('fontSize').value=t.size;$('fontColor').value=color;$('fontColorHex').value=color;$('useThemeFontColor').checked=t.useThemeColor;$('fontBold').checked=t.bold;$('fontItalic').checked=t.italic;$('fontUnderline').checked=t.underline;updateTypographySample();
  }
  function loadTypographyDialog() { setTypographyDraft(state.typography); }
  function openTypographyDialog() { loadTypographyDialog();$('typographyDialog').showModal(); }
  function applyTypography() {
    if(!$('useThemeFontColor').checked){const color=validHexColor($('fontColorHex').value);if(!color){$('typographyMessage').textContent='Enter a hexadecimal color such as #1e2a22.';$('fontColorHex').focus();return;}$('fontColorHex').value=color;$('fontColor').value=color;}
    state.typography=typographyDraft();$('fontSize').value=state.typography.size;updateTypographySummary();if(specializedActive())sendSpecializedAppearance();else renderPlot();$('typographyDialog').close();
  }
  function updateAxisSpacingLabels() {
    const describe=(input,output)=>{if(!input)return;const value=Math.max(0,Number(input.value)||0);if(output){output.value=value?value+' px':'Auto';output.textContent=output.value;}};
    for(const id of ['yAxisSpace','xAxisSpace','rightAxisSpace','topAxisSpace']){describe($(id),$(id+'Value'));if($(id+'Number'))$(id+'Number').value=$(id)?.value||'0';}
  }
  function resetAppearanceDefaults() {
    const setValue=(id,value)=>{const el=$(id);if(el)el.value=String(value);};
    const setChecked=(id,value)=>{const el=$(id);if(el)el.checked=Boolean(value);};
    setValue('plotTitle','');
    setValue('theme','white');
    setValue('plotBackgroundColor','#ffffff');
    setValue('dragMode','pan');
    setValue('barOrientation','v');
    setChecked('showGrid',false);
    setChecked('showAxisTitles',true);
    setValue('yAxisSpace','0');
    setValue('xAxisSpace','0');
    setValue('rightAxisSpace','0');
    setValue('topAxisSpace','0');
    
    setValue('foldChangeScale','log2');
    setValue('generalDataColor','#377497');
    setValue('selectedDataColor','#7b2cbf');
    setValue('upDataColor','#ef5350');
    setValue('downDataColor','#43a047');
    setValue('nsDataColor','#c9d0cc');
    setValue('networkNodeColor','#377497');
    setValue('networkEdgeColor','#7b8d83');
    setChecked('autoSelectionInfo',true);
    setValue('aggregation','mean');
    setValue('colorScale','Viridis');
    setValue('networkLayout','force');
    setValue('networkEdges','500');
    setValue('pointSize','7');
    setValue('opacity','0.8');
    setValue('volcanoLfcCutoff','1');
    setValue('volcanoPCutoff','0.05');
    setValue('volcanoMinSize','5');
    setValue('volcanoMaxSize','20');
    setValue('volcanoLabelCount','8');
    setChecked('volcanoCounts',true);
    setChecked('volcanoConnectors',true);
    setValue('histogramBins','40');
    state.histogramContigColors=new Map();
    setValue('circosPCutoff','0.05');
    setChecked('circosSigOnly',false);
    setChecked('circosFreeCamera',true);
    resetCircosCamera({apply:false});
    setValue('genomeRegionGeneCount','55');
    setChecked('genomeRegionWheelZoom',true);
    setChecked('genomeRegionAutoScale',true);
    setChecked('genomeRegionGuideLines',false);
    setChecked('showLegend',true);
    setChecked('showLabels',false);
    setChecked('showSpecializedLabels',true);
    setChecked('showSpecializedGrid',false);
    setValue('specializedPrimaryColor','#2f8f83');
    setValue('specializedSecondaryColor','#d1775b');
    setValue('specializedColorScale','Viridis');
    document.querySelectorAll('#specializedNodeColorList input[type="color"]').forEach(input=>{input.value=colorToHex(input.dataset.defaultColor,input.value);});
    const specializedEdgeColor=$('specializedEdgeColor');if(specializedEdgeColor)specializedEdgeColor.value=colorToHex(specializedEdgeColor.dataset.defaultColor,'#52665b');
    state.typography=defaultTypography();
    updateTypographySummary();
    updateAxisSpacingLabels();
    applyDefaultAxisTitles($('plotType').value);
    state.volcanoCountPositions={down:{x:.12,y:1.055},up:{x:.88,y:1.055}};
    state.genomeRegionViewRange=null;
    state.genomeRegionRenderedRange=null;
    state.genomeRegionLockedSpan=null;
    state.genomeRegionYRange=null;
    updateSpecialOptions();
    if(specializedActive())sendSpecializedAppearance();else renderPlot();
    $('plotMessage').textContent='Appearance reset to the default settings for this plot.';
  }
  function aggregate(values, mode) {
    const nums=values.map(numeric).filter(v=>v!==null);
    if(mode==='count') return values.length;
    if(!nums.length) return null;
    if(mode==='none') return nums[0];
    if(mode==='sum') return nums.reduce((a,b)=>a+b,0);
    if(mode==='median'){const x=[...nums].sort((a,b)=>a-b),m=Math.floor(x.length/2);return x.length%2?x[m]:(x[m-1]+x[m])/2;}
    return nums.reduce((a,b)=>a+b,0)/nums.length;
  }
  function scaleSizes(values, minimum=6, maximum=28) {
    const nums=values.map(numeric); const valid=nums.filter(v=>v!==null);
    if(!valid.length) return values.map(()=>Number($('pointSize').value));
    const lo=Math.min(...valid),hi=Math.max(...valid); if(lo===hi)return nums.map(v=>v===null?minimum:(minimum+maximum)/2);
    return nums.map(v=>v===null?minimum:minimum+(maximum-minimum)*(v-lo)/(hi-lo));
  }
  function groupRows(name, sourceRows=state.rows) {
    if (!name) return new Map([['All data', sourceRows]]);
    const groups = new Map();
    sourceRows.forEach(row => { const key = String((['network','combined'].includes(moduleName)&&name===moduleColumnName())?renamedModule(row[name]):(row[name] ?? 'Missing')); if (!groups.has(key)) groups.set(key, []); groups.get(key).push(row); });
    return groups;
  }
  function firstColumn(patterns, kind=null, fallback=true) {
    for (const pattern of patterns) {
      const found = state.columns.find(c => pattern.test(c.name) && (!kind || c.kind === kind));
      if (found) return found.name;
    }
    if (!fallback) return null;
    const found = state.columns.find(c => !kind || c.kind === kind);
    return found ? found.name : null;
  }
  function genomeSeqColumn() {
    const role=state.roles.color;
    if(role&&/(^seqid$|^contig$|replicon|chromosome|^chr$)/i.test(String(role)))return role;
    return firstColumn([/^seqid$/i,/^contig$/i,/replicon/i,/chromosome/i,/^chr$/i],null,false)||null;
  }
  function availableGenomeContigs() {
    const seqCol=genomeSeqColumn();if(!seqCol)return ['Genome'];
    const values=unique(state.rows.map(r=>String(r?.[seqCol]??'').trim()).filter(Boolean));return moduleName==='de'?values:values.sort((a,b)=>String(a).localeCompare(String(b),undefined,{numeric:true}));
  }
  function contigUi(type) {
    if(type==='Histogram')return {picker:'histogramContigPicker',list:'histogramContigList',summary:'histogramContigSummary'};
    if(type==='Circos')return {picker:'circosContigPicker',list:'circosContigList',summary:'circosContigSummary'};
    return {picker:'genomeRegionContigPicker',list:'genomeRegionContigList',summary:'genomeRegionContigSummary'};
  }
  function ensureContigSelection(type,available=null) {
    available=available||availableGenomeContigs();
    if(!state.contigSelectionInitialized[type]){state.contigSelections[type]=new Set(moduleName==='de'?available.slice(0,1):available);state.contigSelectionInitialized[type]=true;}
    else {const keep=new Set([...state.contigSelections[type]].filter(x=>available.includes(x)));state.contigSelections[type]=keep;}
    return state.contigSelections[type];
  }
  function histogramContigColor(contig,available=null) {
    available=available||availableGenomeContigs();if(state.histogramContigColors.has(contig))return state.histogramContigColors.get(contig);const index=Math.max(0,available.indexOf(contig)),color=repliconPalette[index%repliconPalette.length];state.histogramContigColors.set(contig,color);return color;
  }
  function updateContigSelector(type) {
    const ui=contigUi(type),picker=$(ui.picker),list=$(ui.list),summary=$(ui.summary);if(!picker||!list||!summary)return;
    const available=availableGenomeContigs(),selected=ensureContigSelection(type,available);picker.hidden=available.length<=1;
    list.innerHTML=available.map(contig=>{const colorControl=type==='Histogram'?`<input class="contig-color-input" type="color" data-hist-contig="${esc(contig)}" value="${histogramContigColor(contig,available)}" title="Histogram color for ${esc(contig)}">`:'';return `<label class="contig-check-item" title="${esc(contig)}"><input type="checkbox" data-contig-type="${esc(type)}" data-contig="${esc(contig)}" ${selected.has(contig)?'checked':''}>${colorControl}<span>${esc(contig)}</span></label>`;}).join('');
    summary.textContent=available.length<=1?(available.length?`Single contig: ${available[0]}`:'No contig column detected.'):`${selected.size} of ${available.length} contigs selected.`;
    list.querySelectorAll('input[type="checkbox"]').forEach(box=>box.addEventListener('change',()=>{const set=state.contigSelections[type];if(box.checked)set.add(box.dataset.contig);else set.delete(box.dataset.contig);if(type==='Genome region'){state.genomeRegionViewRange=null;state.genomeRegionRenderedRange=null;state.genomeRegionViewKey='';state.genomeRegionLockedSpan=null;}if(type==='Circos'){state.circosAngularView=null;resetCircosCamera({apply:false});}summary.textContent=`${set.size} of ${available.length} contigs selected.`;renderPlot();}));
    if(type==='Histogram')list.querySelectorAll('input[data-hist-contig]').forEach(picker=>picker.addEventListener('input',()=>{state.histogramContigColors.set(picker.dataset.histContig,picker.value);renderPlot();}));
  }
  function updateContigSelectors() { updateContigSelector('Histogram');updateContigSelector('Circos');updateContigSelector('Genome region'); }
  function selectedGenomeContigs(type) { const available=availableGenomeContigs(),selected=ensureContigSelection(type,available);return new Set([...selected].filter(x=>available.includes(x))); }
  function setAllContigs(type,checked) { const available=availableGenomeContigs();state.contigSelectionInitialized[type]=true;state.contigSelections[type]=checked?new Set(available):new Set();if(type==='Genome region'){state.genomeRegionViewRange=null;state.genomeRegionRenderedRange=null;state.genomeRegionViewKey='';state.genomeRegionLockedSpan=null;}if(type==='Circos'){state.circosAngularView=null;resetCircosCamera({apply:false});}updateContigSelector(type);renderPlot(); }
  function includeActiveRowContig(type,rowIndex) {
    if(!Number.isInteger(rowIndex)||!state.rows[rowIndex])return false;const seqCol=genomeSeqColumn();if(!seqCol)return false;const seq=String(state.rows[rowIndex][seqCol]??'').trim();if(!seq)return false;
    ensureContigSelection(type);if(state.contigSelections[type].has(seq))return false;state.contigSelections[type].add(seq);updateContigSelector(type);return true;
  }
  function usableGroup(name, maximum=24) {
    if (!name || columnKind(name)==='numeric') return name;
    return unique(column(name)).length <= maximum ? name : null;
  }
  function setRole(role, variable) {
    state.roles[role] = variable;
    const el = document.querySelector(`.role[data-role="${role}"]`);
    el.classList.toggle('assigned', !!variable);
    el.querySelector('strong').textContent = variable || (['x','y'].includes(role) ? 'Drop variable' : 'Optional');
    updateRelevantControls();
    renderPlot();
  }
  function clearRoles() { Object.keys(state.roles).forEach(role => setRole(role, null)); }

  function populatePlotTypes() {
    $('plotType').innerHTML = (plotTypesByModule[moduleName] || plotTypesByModule.de).map(x => `<option>${x}</option>`).join('');
    updateSpecialOptions();
  }

  function setupDEContrastControls() {
    if(moduleName!=='de')return;
    state.contrastTables=state.tables.filter(t=>/^DE\s+/i.test(String(t.sheet_name||'')) && !/^DE\s*summary/i.test(String(t.sheet_name||'')));
    state.allContrastsKey=(state.tables.find(t=>String(t.sheet_name||'').toLowerCase()==='all contrasts')||{}).key||null;
    state.allContrastRowsKey=(state.tables.find(t=>String(t.sheet_name||'').toLowerCase()==='all contrast rows')||{}).key||null;
    const multi=state.contrastTables.length>=2;
    $('contrastControls').hidden=!multi;
    if(!multi)return;
    $('contrastSelect').innerHTML=state.contrastTables.map(t=>`<option value="${esc(t.key)}">${esc(String(t.sheet_name||t.label).replace(/^DE\s+/i,''))}</option>`).join('');
    state.contrastTableKey=$('contrastSelect').value||state.contrastTables[0].key;
    updateDEContrastControlVisibility();
  }
  function updateDEContrastControlVisibility() {
    if(moduleName!=='de'||$('contrastControls').hidden)return;
    const type=$('plotType').value;
    $('histogramAllContrastsRow').hidden=!(type==='Histogram'&&state.allContrastRowsKey);
    $('circosContrastNote').hidden=type!=='Circos';
    $('genomeRegionContrastNote').hidden=type!=='Genome region';
    $('contrastSelect').disabled=(type==='Circos'||type==='Genome region')||(type==='Histogram'&&$('compareAllContrasts').checked);
  }
  async function syncDEContrastTableForPlot() {
    if(moduleName!=='de'||$('contrastControls').hidden)return false;
    updateDEContrastControlVisibility();
    const type=$('plotType').value;
    let target=state.contrastTableKey||$('contrastSelect').value;
    if((type==='Circos'||type==='Genome region')&&state.allContrastsKey)target=state.allContrastsKey;
    else if(type==='Histogram'&&$('compareAllContrasts').checked&&state.allContrastRowsKey)target=state.allContrastRowsKey;
    else target=$('contrastSelect').value||target;
    if(target&&$('tableSelect').value!==target){$('tableSelect').value=target;await loadTable();return true;}
    return false;
  }
  const plotGuides={
    de:{
      'Volcano':'What it shows: effect size versus statistical significance. What to learn: genes far left/right with high significance are the strongest down/up-regulated candidates.',
      'MA plot':'What it shows: fold change across mean normalized expression using the selected display scale. What to learn: whether effect sizes depend on abundance and whether low-count genes are especially variable.',
      'Circos':'What it shows: each gene is placed at its genomic coordinate on the contigs or replicons you select, and differential expression is shown only as radial bars, without endpoint bubbles. Red bars indicate up-regulation and green bars indicate down-regulation, with one ring per contrast. What to learn: genomic hot regions where neighboring genes or operons respond together and whether different treatments perturb the same or different genomic neighborhoods.',
      'Genome region':'What it shows: a two-panel genomic neighborhood view for the contigs or replicons you select. The upper panel uses gene-width bars for differential-expression values, while the lower panel shows directional gene arrows spanning each gene’s real start-to-end interval on verified + and − strand lanes. Multiple checked contigs are arranged as separate genomic windows in the same plot. What to learn: expression changes and local gene architecture together, including operon-like neighborhoods, strand orientation, gene length, and coordinated regulation of neighboring genes.',
      'Scatter':'What it shows: the relationship between two numeric variables for every gene, with optional color and point-size encoding when an additional variable is useful. What to learn: correlations, outliers, and genes that deviate from the overall trend without needing a separate bubble-plot mode.',
      'Violin + box':'What it shows: the full distribution density together with the embedded box plot, median, quartiles, mean line, and outliers. What to learn: group differences, skew, multimodality, spread, and unusual observations in one view.',
      'Histogram':'What it shows: the frequency distribution of one numeric statistic for the contigs / replicons you choose, using an adjustable number of bins. What to learn: the global spread, skew, and tails of fold changes, scores, or expression, and whether that distribution differs when specific replicons are included or excluded.'
    },
    enrichment:{
      'Dot plot':'What it shows: enriched terms with effect/enrichment strength, significance, and gene-set size. What to learn: which biological processes are most strongly supported.',
      'Bar':'What it shows: enrichment scores or counts by term. What to learn: the highest-ranking pathways or GO terms.',
      'Scatter':'What it shows: relationships among enrichment statistics, with optional color and point-size encoding for extra dimensions. What to learn: terms that combine strong effect, significance, or coverage.',
      'Heatmap':'What it shows: enrichment values encoded by color. What to learn: patterns shared among terms, sources, contrasts, or groups.',
      'Network':'What it shows: terms/genes as connected nodes when edge relationships are available. What to learn: clusters of related functional themes.',
      'Histogram':'What it shows: the distribution of an enrichment statistic. What to learn: whether the result set is concentrated, skewed, or dominated by extremes.'
    },
    network:{
      'Network':'What it shows: genes/modules as nodes and inferred relationships as edges. What to learn: hubs, modules, and highly connected regulatory or co-expression structure.',
      'Scatter':'What it shows: the relationship between two network statistics, with optional color and point-size encoding for extra dimensions. What to learn: hubs or edges that depart from the overall relationship.',
      'Bar':'What it shows: a network score for selected genes, modules, or edges. What to learn: the strongest hubs, modules, or interactions.',
      'Violin + box':'What it shows: distribution density with an embedded box plot, median, quartiles, mean line, and outliers. What to learn: spread, skew, multimodality, and differences among network groups.',
      'Heatmap':'What it shows: network or expression values encoded by color. What to learn: blocks of coordinated relationships.',
      'Line':'What it shows: an ordered trend in a network statistic. What to learn: changes across ranked or ordered nodes/edges.',
      'Histogram':'What it shows: the frequency distribution of a network statistic. What to learn: whether most relationships are weak with a small strong tail or broadly distributed.'
    }
  };
  function updatePlotGuide(){
    const type=$('plotType').value,guide=plotGuides[moduleName]?.[type]||'';
    const match=guide.match(/^What it shows:\s*(.*?)\s*What to learn:\s*(.*)$/i);
    if(match){$('plotGuide').innerHTML=`<p><strong>What it shows</strong><span>${esc(match[1])}</span></p><p><strong>What to learn</strong><span>${esc(match[2])}</span></p>`;}
    else {$('plotGuide').textContent=guide||'Choose variables to explore this result table interactively.';}
  }

  function plotFunctionForType(type) {
    const mapping={'Volcano':traceVolcano,'MA plot':tracesScatter,'Circos':traceCircos,'Genome region':traceGenomeRegion,'Scatter':tracesScatter,'Line':tracesScatter,'Bar':tracesBar,'Violin + box':tracesDistribution,'Histogram':traceHistogram,'Heatmap':traceHeatmap,'Dot plot':traceDot,'Network':traceNetwork};
    return mapping[type]||renderPlot;
  }
  function actualPlotCode() {
    const type=$('plotType').value,fn=plotFunctionForType(type),settings={module:moduleName,plot_type:type,table:state.table?.sheet_name||state.table?.label||'',roles:state.roles,fold_change_display:foldScaleLabel(),theme:$('theme').value,drag_mode:$('dragMode').value,show_grid:$('showGrid').checked,show_legend:$('showLegend').checked,show_labels:$('showLabels').checked};
    return `// Actual browser plotting engine: Plotly.js\n// Current effective settings\nconst currentSettings = ${JSON.stringify(settings,null,2)};\n\n// Plot-specific trace constructor used by this report\n${fn.toString()}\n\n// Shared renderer/layout used by every plot\n${renderPlot.toString()}`;
  }
  function pythonEquivalentCode() {
    const type=$('plotType').value,x=state.roles.x||'',y=state.roles.y||'',value=state.roles.value||'',color=state.roles.color||'',size=state.roles.size||'',label=state.roles.label||'',sheet=state.table?.sheet_name||0,file=state.table?.filename||'analysis results.xlsx';
    const q=v=>JSON.stringify(String(v||''));
    const header=`import pandas as pd\nimport plotly.express as px\nimport plotly.graph_objects as go\n\n# Reproducible Python equivalent of the current interactive view.\n# The actual application uses Plotly.js in the browser; this code reproduces the same scientific mapping.\ndf = pd.read_excel(${q(file)}, sheet_name=${typeof sheet==='number'?sheet:q(sheet)})\n`;
    if(type==='Volcano')return header+`\nimport numpy as np\nx_col=${q(x)}\np_col=${q(y)}\nlabel_col=${q(label)}\ndf = df.dropna(subset=[x_col,p_col]).copy()\ndf['minus_log10_p'] = -np.log10(df[p_col].clip(lower=np.finfo(float).tiny))\nfig = px.scatter(df, x=x_col, y='minus_log10_p', hover_name=label_col or None, color=x_col, color_continuous_scale='RdYlBu_r')\nfig.add_vline(x=-1, line_dash='dash'); fig.add_vline(x=1, line_dash='dash')\nfig.add_hline(y=-np.log10(0.05), line_dash='dashdot')\nfig.update_layout(xaxis_title=${q(foldScaleLabel())}, yaxis_title='')\nfig.show()\n`;
    if(type==='MA plot')return header+`\nfig = px.scatter(df, x=${q(x)}, y=${q(y)}, hover_name=${q(label)} or None, log_x=True)\nfig.update_layout(xaxis_title='Mean normalized expression', yaxis_title=${q(foldScaleLabel())})\nfig.show()\n`;
    if(type==='Circos')return header+`\n# Genome-coordinate Circos differential-expression view.\n# The live report places each gene at its genomic angle and draws a radial segment\n# as radial bars from each track baseline: outward for positive effect, inward for negative effect.\nstart_col=${q(x)}\nlabel_col=${q(label)}\nseq_col=next((c for c in df.columns if c.lower() in ('seqid','contig','replicon','chromosome')), None)\neffect_cols=[c for c in df.columns if ('log2fold' in c.lower() or 'logfc' in c.lower())]\nif not start_col or start_col not in df.columns:\n    df=df.reset_index(drop=True).copy(); df['_position']=df.index+1; start_col='_position'\n# Calculate one cumulative genome angle per gene, adding a small gap between replicons.\n# genome_theta(...) is the cumulative coordinate-to-angle mapping used by the browser.\nfig=go.Figure()\nfor track_i,col in enumerate(effect_cols):\n    base=1+track_i*0.40\n    cap=max(0.5,float(df[col].abs().quantile(0.99)))\n    for _,row in df.dropna(subset=[col]).iterrows():\n        angle=genome_theta(row[start_col], row[seq_col] if seq_col else 'Genome')\n        delta=min(abs(float(row[col]))/cap,1.0)*0.17\n        end_radius=base + delta if row[col]>0 else base-delta\n        color='#e34a42' if row[col]>0 else '#3f78c5'\n        fig.add_trace(go.Barpolar(theta=[angle], r=[abs(end_radius-base)], base=[min(base,end_radius)], marker_color=color, showlegend=False))\n# Add chromosome/plasmid arcs and coordinate tick labels outside the DE tracks.\nfig.update_layout(polar=dict(radialaxis=dict(showticklabels=False,showgrid=False),angularaxis=dict(showticklabels=False,showgrid=False)))\nfig.show()\n`;
    if(type==='Genome region')return header+`\n# Detailed linear genome-region gene track.\n# Each gene is a filled directional polygon spanning its true genomic start/end.\n# Forward and reverse genes occupy separate lanes; there is no redundant DE bar panel.\n# In the live report, arrow color can encode DE status while selection is outlined.\nstart_col=next((c for c in df.columns if c.lower() in ('start','gene_start','position')), None)\nend_col=next((c for c in df.columns if c.lower() in ('end','gene_end','stop')), None)\nstrand_col=next((c for c in df.columns if c.lower()=='strand'), None)\nlabel_col=${q(label)} or next((c for c in df.columns if 'gene' in c.lower()), df.columns[0])\n# Sort a replicon by true coordinates and draw each gene as a strand-aware polygon.\n# The complete replicon remains loaded so pan/zoom never reveals an artificial blank region.\nfig=go.Figure()\n# See the Actual Plotly.js code tab for the exact polygon and linked-selection logic.\nfig.show()\n`;
    if(type==='Histogram'){const bins=Math.max(5,Math.min(200,Math.round(Number($('histogramBins').value)||40))),seq=genomeSeqColumn(),selected=seq?[...selectedGenomeContigs('Histogram')]:[];const filter=seq&&selected.length?`\ndf = df[df[${q(seq)}].astype(str).isin(${JSON.stringify(selected)})]`:'';return header+filter+`\nfig = px.histogram(df, x=${q(x||y)}, color=${q(color)} or None, nbins=${bins}, barmode='overlay', opacity=0.65)\nfig.show()\n`;}
    if(type==='Violin + box')return header+`\nfig = px.violin(df, x=${q(x)} or None, y=${q(y)}, box=True, points='all', hover_name=${q(label)} or None)\nfig.show()\n`;
    if(type==='Bar')return header+`\nfig = px.bar(df, x=${q(x)}, y=${q(y)}, color=${q(color)} or None, hover_name=${q(label)} or None)\nfig.show()\n`;
    if(type==='Heatmap')return header+`\n# For a simple gene/value heatmap:\nplot_df=df[[${q(x)},${q(value||y)}]].dropna().head(300).set_index(${q(x)})\nfig = px.imshow(plot_df.T, aspect='auto', color_continuous_scale=${q($('colorScale').value)})\nfig.show()\n`;
    if(type==='Network')return header+`\n# Network rendering requires source/target columns and a layout algorithm.\n# The application builds node positions interactively; NetworkX can reproduce this in Python.\nimport networkx as nx\nG=nx.from_pandas_edgelist(df, source=${q(x)}, target=${q(y)}, edge_attr=True)\npos=nx.spring_layout(G, seed=1)\nedge_x=[]; edge_y=[]\nfor a,b in G.edges():\n    edge_x += [pos[a][0],pos[b][0],None]; edge_y += [pos[a][1],pos[b][1],None]\nfig=go.Figure([go.Scatter(x=edge_x,y=edge_y,mode='lines',hoverinfo='skip'),go.Scatter(x=[pos[n][0] for n in G],y=[pos[n][1] for n in G],mode='markers+text',text=list(G))])\nfig.show()\n`;
    const ctor=type==='Line'?'px.line':'px.scatter';
    return header+`\nfig = ${ctor}(df, x=${q(x)}, y=${q(y)}, color=${q(color)} or None, hover_name=${q(label)} or None${type==='Scatter'&&size?`, size=${q(size)}`:''})\nfig.show()\n`;
  }
  function updatePlotCodeView() {
    const mode=$('plotCodeMode').value;
    $('plotCodeText').textContent=mode==='analysis'?(state.analysisSource||'The statistical-analysis R source was not embedded in this legacy report. Re-run the analysis with the current software version.'):mode==='python'?pythonEquivalentCode():actualPlotCode();
    $('plotCodeStatus').textContent=mode==='actual'?'This is the actual Plotly.js plotting function used by the report, plus the current variable/settings mapping.':mode==='python'?'This Python code is a reproducible equivalent for learning/verification; the live interactive report itself is rendered by Plotly.js.':'This is the R analysis source embedded when the result report was created.';
  }
  function openPlotCodeDialog(){updatePlotCodeView();$('plotCodeDialog').showModal();}
  function updateRelevantControls() {
    const type=$('plotType').value,colorRole=state.roles.color,sizeRoleName=state.roles.size,isDE=moduleName==='de';
    const axisTitlesApplicable=type!=='Circos',selectionInfoApplicable=isDE&&['Volcano','Scatter'].includes(type),plotLabelsApplicable=['Scatter','Dot plot','Line','Network','Genome region'].includes(type)&&(['Network','Genome region'].includes(type)||Boolean(state.roles.label));
    if($('axisTitleInputs'))$('axisTitleInputs').hidden=!axisTitlesApplicable;
    if($('axisTitleToggle'))$('axisTitleToggle').hidden=!axisTitlesApplicable;
    if($('selectionInfoControls'))$('selectionInfoControls').hidden=!selectionInfoApplicable;
    if($('showLabelsControl'))$('showLabelsControl').hidden=!plotLabelsApplicable;
    if($('showGridControl'))$('showGridControl').hidden=type==='Circos';
    $('foldChangeScaleControl').hidden=!isDE;
    const statusPlot=isDE&&['Volcano','Circos','Genome region'].includes(type),generalControl=$('generalDataColorControl'),selectedControl=$('selectedDataColorControl'),generalLabel=$('generalDataColorLabel'),selectedLabel=$('selectedDataColorLabel'),semantic=$('deSemanticColorControls');
    if(semantic)semantic.hidden=!statusPlot;
    if(generalControl)generalControl.hidden=statusPlot;
    if(selectedControl)selectedControl.hidden=isDE&&['Histogram','Violin + box'].includes(type);
    if(generalLabel){generalLabel.textContent=type==='Histogram'?'Histogram bar color':type==='Violin + box'?'Violin / outlier color':(['MA plot','Scatter'].includes(type)?'Point color':'General point / bar color');}
    if(selectedLabel){selectedLabel.textContent=type==='Circos'?'Selected Circos gene':type==='Genome region'?'Selected genome gene':(['MA plot','Scatter'].includes(type)?'Selected point color':'Selected data color');}
    // The DE studio intentionally keeps only controls that have a clear,
    // plot-specific biological use.  Bar orientation/aggregation, heatmap
    // colour scales, and network layout/edge limits belong to other modules.
    $('barOrientationControl').hidden=isDE||type!=='Bar';
    $('aggregationControl').hidden=isDE||!['Bar','Heatmap'].includes(type);
    $('colorScaleControl').hidden=isDE||!(type==='Heatmap'||(['Scatter','Dot plot'].includes(type)&&colorRole&&columnKind(colorRole)==='numeric'));
    $('networkLayoutControl').hidden=isDE||type!=='Network';
    $('networkEdgesControl').hidden=isDE||type!=='Network';
    if($('genericNetworkColorControls'))$('genericNetworkColorControls').hidden=type!=='Network';
    $('pointSizeControl').hidden=isDE||!['Scatter','Dot plot'].includes(type)||Boolean(sizeRoleName);
    if($('opacityControl'))$('opacityControl').hidden=isDE;
    const labelRole=document.querySelector('.role[data-role="label"]');if(labelRole)labelRole.hidden=type==='Histogram';
    const sizeRole=document.querySelector('.role[data-role="size"]');if(sizeRole)sizeRole.hidden=!['Scatter','Dot plot'].includes(type);
  }
  function updateSpecialOptions() { const type=$('plotType').value; $('volcanoOptions').style.display=type==='Volcano'?'block':'none'; $('histogramOptions').style.display=type==='Histogram'?'block':'none'; $('circosOptions').style.display=type==='Circos'?'block':'none'; $('genomeRegionOptions').style.display=type==='Genome region'?'block':'none'; $('dragMode').value='pan'; if(['Histogram','Circos','Genome region'].includes(type))updateContigSelector(type); updateRelevantControls(); updatePlotGuide(); }
  function prettyAxisName(name){if(!name)return '';if(moduleName==='de'&&isEffectColumn(name))return foldScaleLabel();const known={baseMean:'Mean normalized expression',FDR:'Adjusted p-value',padj:'Adjusted p-value',pvalue:'P-value',PValue:'P-value'};return known[name]||String(name).replace(/_/g,' ').replace(/([a-z])([A-Z])/g,'$1 $2').replace(/\s+/g,' ').trim();}
  function defaultAxisTitles(type) {
    if(type==='Volcano') return [foldScaleLabel(),'−log₁₀('+prettyAxisName(state.roles.y)+')'];
    if(type==='MA plot') return ['Mean normalized expression',foldScaleLabel()];
    if(type==='Dot plot'&&['enrichment','combined'].includes(moduleName)) return [prettyAxisName(state.roles.x)||'Enrichment score',prettyAxisName(state.roles.y)||'Term'];
    if(type==='Bar'&&$('barOrientation').value==='h') return [prettyAxisName(state.roles.y),prettyAxisName(state.roles.x)];
    if(type==='Histogram') return [prettyAxisName(state.roles.x||state.roles.y),'Frequency'];
    if(type==='Violin + box') return [prettyAxisName(state.roles.x)||'Group',prettyAxisName(state.roles.y)||'Value'];
    if(type==='Heatmap') return [prettyAxisName(state.roles.x),prettyAxisName(state.roles.y)||prettyAxisName(state.roles.value)];
    if(type==='Genome region') return ['Genomic position',foldScaleLabel()];
    if(type==='Network'||type==='Circos') return ['',''];
    return [prettyAxisName(state.roles.x),prettyAxisName(state.roles.y)];
  }
  function applyDefaultAxisTitles(type) {
    const titles=defaultAxisTitles(type);$('xTitle').value=titles[0];$('yTitle').value=titles[1];
  }
  function lowCardinalityCategorical(patterns=[], maximum=18) {
    for (const pattern of patterns) {
      const found=state.columns.find(c=>c.kind==='categorical'&&pattern.test(c.name)&&c.unique>0&&c.unique<=maximum);
      if(found)return found.name;
    }
    const found=state.columns.find(c=>c.kind==='categorical'&&c.unique>0&&c.unique<=maximum&&!/^(gene([ _]?id)?|locus([ _]?tag)?|symbol|term([ _]?(id|name))?|description|node)$/i.test(c.name));
    return found?found.name:null;
  }
  function columnNumericFraction(name){if(!name||!state.rows.length)return 0;let seen=0,ok=0;for(const row of state.rows.slice(0,Math.min(2000,state.rows.length))){const v=row[name];if(v===null||v===undefined||v==='')continue;seen++;if(numeric(v)!==null)ok++;}return seen?ok/seen:0;}
  function numericByPattern(patterns,fallback=false){for(const pattern of patterns){const found=state.columns.find(c=>pattern.test(c.name)&&columnNumericFraction(c.name)>=.35);if(found)return found.name;}if(fallback){const found=state.columns.find(c=>columnNumericFraction(c.name)>=.75);return found?found.name:null;}return null;}
  function preferredNumeric(patterns=[]) {
    const named=firstColumn(patterns,'numeric',false);
    return named||firstColumn([],'numeric',false);
  }
  function secondNumeric(exclude, patterns=[]) {
    for(const pattern of patterns){const found=state.columns.find(c=>c.kind==='numeric'&&c.name!==exclude&&pattern.test(c.name));if(found)return found.name;}
    const found=state.columns.find(c=>c.kind==='numeric'&&c.name!==exclude);return found?found.name:null;
  }

  function autoAssign() {
    const type = $('plotType').value;
    updateSpecialOptions();
    state.roles = {x:null,y:null,value:null,color:null,size:null,label:null};
    if (type === 'Volcano') {
      state.roles.x = firstColumn([/log2.*fold/i,/logfc/i,/effect/i], 'numeric');
      state.roles.y = firstColumn([/^padj$/i,/fdr/i,/adj.*p/i,/pvalue/i,/p\.value/i], 'numeric');
      state.roles.label = firstColumn([/gene.*id/i,/locus/i,/symbol/i,/^id$/i],null,false);
    } else if (type === 'MA plot') {
      state.roles.x = firstColumn([/basemean/i,/logcpm/i,/aveexpr/i,/mean.*expression/i], 'numeric');
      state.roles.y = firstColumn([/log2.*fold/i,/logfc/i], 'numeric');
      state.roles.label = firstColumn([/gene.*id/i,/locus/i,/symbol/i,/^id$/i],null,false);
    } else if (type === 'Circos') {
      state.roles.x = numericByPattern([/^start$/i,/gene.*start/i,/position/i], false);
      state.roles.y = numericByPattern([/log2.*fold/i,/logfc/i,/effect/i], false);
      state.roles.value = numericByPattern([/^padj$/i,/fdr/i,/adj.*p/i,/pvalue/i,/p\.value/i], false);
      state.roles.color = firstColumn([/^seqid$/i,/^contig$/i,/replicon/i,/chromosome/i], null, false);
      state.roles.label = firstColumn([/gene.*id/i,/locus/i,/symbol/i,/^id$/i],null,false);
    } else if (type === 'Genome region') {
      state.roles.x = numericByPattern([/^start$/i,/gene.*start/i,/position/i], false);
      state.roles.y = numericByPattern([/log2.*fold/i,/logfc/i,/effect/i], false);
      state.roles.value = numericByPattern([/^padj$/i,/fdr/i,/adj.*p/i,/pvalue/i,/p\.value/i], false);
      state.roles.color = firstColumn([/^seqid$/i,/^contig$/i,/replicon/i,/chromosome/i], null, false);
      state.roles.label = firstColumn([/gene.*id/i,/locus/i,/symbol/i,/^id$/i],null,false);
    } else if (type === 'Dot plot' && moduleName === 'enrichment') {
      state.roles.y = firstColumn([/term.*name/i,/description/i,/pathway/i,/term.*id/i],null,false);
      state.roles.x = firstColumn([/gene.*ratio/i,/enrichment/i,/nes/i,/count/i], 'numeric',false);
      state.roles.size = firstColumn([/^count$/i,/set.*size/i,/genes/i], 'numeric',false);
      state.roles.color = firstColumn([/padj/i,/fdr/i,/pvalue/i], 'numeric',false);
    } else if (type === 'Network') {
      state.roles.x = firstColumn([/^source$/i,/from/i,/regulator/i,/gene1/i],null,false);
      state.roles.y = firstColumn([/^target$/i,/to/i,/gene2/i],null,false);
      state.roles.value = firstColumn([/weight/i,/score/i,/correlation/i,/importance/i], 'numeric',false);
      state.roles.color = firstColumn([/module/i,/type/i,/sign/i],null,false);
    } else if (type === 'Heatmap') {
      state.roles.x = identityColumn() || firstColumn([/gene/i,/term/i,/module/i,/sample/i]);
      state.roles.y = lowCardinalityCategorical([/condition/i,/group/i,/module/i,/source/i,/direction/i],24);
      state.roles.value = preferredNumeric([/log2.*fold/i,/logfc/i,/expression/i,/value/i,/score/i,/correlation/i,/eigengene/i,/count/i]);
      state.roles.label = identityColumn();
    } else if (type === 'Scatter' || type === 'Line') {
      state.roles.x = preferredNumeric([/basemean/i,/mean.*expression/i,/logcpm/i,/aveexpr/i,/stat/i,/score/i,/count/i]);
      state.roles.y = secondNumeric(state.roles.x,[/log2.*fold/i,/logfc/i,/effect/i,/stat/i,/score/i,/value/i,/expression/i]);
      state.roles.color = moduleName==='de'?null:lowCardinalityCategorical([/condition/i,/direction/i,/module/i,/source/i],18);
      state.roles.label = identityColumn();
    } else if (type === 'Bar') {
      if(['enrichment','combined'].includes(moduleName))$('barOrientation').value='h';
      state.roles.x = identityColumn() || firstColumn([/gene/i,/term/i,/module/i],null,false);
      state.roles.y = preferredNumeric([/log2.*fold/i,/logfc/i,/effect/i,/score/i,/count/i,/value/i,/expression/i]);
      state.roles.color = moduleName==='de'?null:lowCardinalityCategorical([/condition/i,/direction/i,/module/i,/source/i],18);
      state.roles.label = identityColumn();
    } else if (type === 'Violin + box') {
      state.roles.x = lowCardinalityCategorical([/condition/i,/direction/i,/group/i,/module/i,/source/i],18);
      state.roles.y = preferredNumeric([/log2.*fold/i,/logfc/i,/effect/i,/score/i,/value/i,/expression/i,/count/i]);
      state.roles.color = null;
      state.roles.label = identityColumn();
    } else if (type === 'Histogram') {
      state.roles.x = preferredNumeric([/log2.*fold/i,/logfc/i,/effect/i,/stat/i,/score/i,/value/i,/expression/i,/count/i,/basemean/i]);
      state.roles.y = null;
      state.roles.color = (moduleName==='de' && $('compareAllContrasts') && $('compareAllContrasts').checked && state.columns.some(c=>/^contrast$/i.test(c.name))) ? firstColumn([/^contrast$/i],null,false) : (moduleName==='de'?null:lowCardinalityCategorical([/condition/i,/direction/i,/module/i,/source/i],12));
      state.roles.label = null;
    } else {
      state.roles.x = firstColumn([/gene/i,/term/i,/module/i,/sample/i,/condition/i]) || firstColumn([], null);
      state.roles.y = firstColumn([/log2.*fold/i,/score/i,/value/i,/expression/i,/count/i,/correlation/i], 'numeric');
      state.roles.color = lowCardinalityCategorical([/condition/i,/module/i,/direction/i,/source/i],18);
      state.roles.label = identityColumn();
    }
    document.querySelectorAll('.role').forEach(el => {
      const role = el.dataset.role, variable = state.roles[role];
      el.classList.toggle('assigned', !!variable);
      el.querySelector('strong').textContent = variable || (['x','y'].includes(role) ? 'Drop variable' : 'Optional');
    });
    applyDefaultAxisTitles(type);
    renderPlot();
  }

  function enrichmentPlotRows(type,announce=true) {
    if(!['enrichment','combined'].includes(moduleName)||!['Scatter','Dot plot','Bar'].includes(type))return state.rows;
    const category=[state.roles.y,state.roles.x].find(role=>role&&columnKind(role)==='categorical'&&unique(state.rows.map(r=>r[role])).length>24);
    if(!category)return state.rows;
    const pcol=firstColumn([/^p\.adjust$/i,/^padj$/i,/fdr/i,/qvalue/i,/pvalue/i,/p\.value/i],'numeric',false);
    const score=firstColumn([/fold.*enrichment/i,/rich.*factor/i,/gene.*ratio/i,/minus.*log/i,/count/i],'numeric',false);
    const sorted=[...state.rows].sort((a,b)=>{if(pcol){const av=numeric(a[pcol]),bv=numeric(b[pcol]);if(av!==null||bv!==null)return (av??Infinity)-(bv??Infinity);}if(score){const av=numeric(a[score]),bv=numeric(b[score]);if(av!==null||bv!==null)return (bv??-Infinity)-(av??-Infinity);}return studioRowIndex(a)-studioRowIndex(b);});
    const kept=[],seen=new Set();for(const row of sorted){const key=String(row[category]??'');if(!key||seen.has(key))continue;seen.add(key);kept.push(row);if(kept.length>=24)break;}
    if(announce)state.categoryPlotNotice=`Showing the 24 strongest unique ${prettyAxisName(category).toLowerCase()} categories to keep labels readable. The linked spreadsheet retains all ${state.rows.length.toLocaleString()} loaded rows.`;
    return kept;
  }

  function tracesScatter(mode='markers') {
    const x=state.roles.x, y=state.roles.y, size=state.roles.size, label=state.roles.label; let group=state.roles.color;
    if (!x || !y) return [];
    const plotRows=enrichmentPlotRows($('plotType').value),perf=PERFORMANCE_RENDERING,traceType=(plotRows.length>(perf?600:1500))?'scattergl':'scatter';
    if(group && columnKind(group)==='numeric') {
      const rows=plotRows;
      return [linkedTrace({type:traceType,mode:mode+($('showLabels').checked&&label?'+text':''),name:'Data',x:rows.map(r=>displayedValue(r,x)),y:rows.map(r=>displayedValue(r,y)),text:label?rows.map(r=>r[label]):undefined,textposition:'top center',hovertext:label?rows.map(r=>r[label]):undefined,marker:{size:size?scaleSizes(rows.map(r=>displayedValue(r,size))):Number($('pointSize').value),color:rows.map(r=>displayedNumeric(r,group)),colorscale:$('colorScale').value,showscale:true,colorbar:{title:prettyAxisName(group)},opacity:Number($('opacity').value)},selected:{marker:{opacity:1,line:{width:3,color:selectedDataColor()}}},unselected:{marker:{opacity:.22}}},rows.map(r=>pointLink([studioRowIndex(r)])))];
    }
    group=usableGroup(group);
    const groups=groupRows(group,plotRows), traces=[];
    for (const [name, rows] of groups) {
      const sizes=size ? scaleSizes(rows.map(r=>displayedValue(r,size))) : Number($('pointSize').value);
      traces.push(linkedTrace({type:traceType, mode: mode + ($('showLabels').checked && label ? '+text' : ''), name, x:rows.map(r=>displayedValue(r,x)), y:rows.map(r=>displayedValue(r,y)), text: label ? rows.map(r=>r[label]) : undefined, textposition:'top center', hovertext: label ? rows.map(r=>r[label]) : undefined, marker:{size:sizes,opacity:Number($('opacity').value),color:group?undefined:generalDataColor()},selected:{marker:{opacity:1,line:{width:3,color:selectedDataColor()}}},unselected:{marker:{opacity:.22}}},rows.map(r=>pointLink([studioRowIndex(r)]))));
    }
    return traces;
  }
  function tracesBar() {
    const x=state.roles.x, y=state.roles.y, group=state.roles.color, orientation=$('barOrientation').value, mode=$('aggregation').value;
    if (!x || !y) return [];
    const traces=[],plotRows=enrichmentPlotRows('Bar');
    for (const [name, rows] of groupRows(usableGroup(group && columnKind(group)!=='numeric' ? group : null),plotRows)) {
      let xv=[],yv=[],links=[];
      if(mode==='none'){xv=rows.map(r=>displayedValue(r,x));yv=rows.map(r=>displayedValue(r,y));links=rows.map(r=>pointLink([studioRowIndex(r)]));}
      else {const by=new Map();rows.forEach(r=>{const key=String(displayedValue(r,x)??'Missing');if(!by.has(key))by.set(key,{values:[],rows:[]});by.get(key).values.push(displayedValue(r,y));by.get(key).rows.push(studioRowIndex(r));});xv=[...by.keys()];yv=xv.map(key=>aggregate(by.get(key).values,mode));links=xv.map(key=>pointLink(by.get(key).rows));}
      const trace={type:'bar',name,x:orientation==='v'?xv:yv,y:orientation==='v'?yv:xv,orientation,opacity:Number($('opacity').value),marker:{color:group?undefined:generalDataColor()},selected:{marker:{opacity:1,line:{width:3,color:selectedDataColor()}}},unselected:{marker:{opacity:.3}}};
      if(group&&columnKind(group)==='numeric'){trace.marker={color:rows.slice(0,xv.length).map(r=>displayedNumeric(r,group)),colorscale:$('colorScale').value,showscale:true,colorbar:{title:prettyAxisName(group)}};}
      traces.push(linkedTrace(trace,links));
    }
    return traces;
  }
  function tracesDistribution(kind) {
    const x=state.roles.x, y=state.roles.y, group=usableGroup(state.roles.color);if(!y)return [];
    const traces=[];
    for (const [name, rows] of groupRows(group)) {
      const trace={type:'violin',name,y:rows.map(r=>displayedValue(r,y)),box:{visible:true},meanline:{visible:true},points:'all',jitter:.12,pointpos:0,opacity:Number($('opacity').value),fillcolor:group?undefined:generalDataColor(),line:group?undefined:{color:generalDataColor()},marker:group?undefined:{color:generalDataColor(),line:{width:.8,color:generalDataColor()}},selected:{marker:{color:selectedDataColor(),opacity:1,line:{width:2.5,color:selectedDataColor()}}},unselected:{marker:{opacity:.45}}};
      if(x&&unique(rows.map(r=>r[x])).length<=40)trace.x=rows.map(r=>r[x]);
      traces.push(linkedTrace(trace,rows.map(r=>pointLink([studioRowIndex(r)]))));
    }
    return traces;
  }
  function traceHistogram() {
    const x=state.roles.x || state.roles.y; if (!x) return [];
    const bins=Math.max(5,Math.min(200,Math.round(Number($('histogramBins').value)||40))),seqCol=genomeSeqColumn();
    let sourceRows=state.rows,selectedContigs=null;
    if(seqCol){selectedContigs=selectedGenomeContigs('Histogram');if(!selectedContigs.size){$('plotMessage').textContent='Select at least one contig / replicon for Histogram.';return [];}sourceRows=state.rows.filter(r=>selectedContigs.has(String(r?.[seqCol]??'').trim()));}
    if(!sourceRows.length){$('plotMessage').textContent='No rows from the selected contigs are available for Histogram.';return [];}
    const groups=new Map(),colors=new Map(),available=availableGenomeContigs();
    if(seqCol&&selectedContigs&&selectedContigs.size>1){sourceRows.forEach(row=>{const key=String(row?.[seqCol]??'').trim()||'Missing contig';if(!groups.has(key))groups.set(key,[]);groups.get(key).push(row);colors.set(key,histogramContigColor(key,available));});}
    else {const histogramGroup=usableGroup(state.roles.color);if(!histogramGroup)groups.set(seqCol&&selectedContigs&&selectedContigs.size===1?[...selectedContigs][0]:'All data',sourceRows);else sourceRows.forEach(row=>{const key=String(row[histogramGroup]??'Missing');if(!groups.has(key))groups.set(key,[]);groups.get(key).push(row);});}
    const all=sourceRows.map(row=>({row,value:displayedNumeric(row,x)})).filter(item=>item.value!==null);if(!all.length)return [];
    let minimum=Math.min(...all.map(item=>item.value)),maximum=Math.max(...all.map(item=>item.value));if(minimum===maximum){minimum-=.5;maximum+=.5;}const step=(maximum-minimum)/bins,centers=Array.from({length:bins},(_v,index)=>minimum+(index+.5)*step);
    return [...groups].map(([name,rows])=>{const buckets=Array.from({length:bins},()=>[]);rows.forEach(row=>{const value=displayedNumeric(row,x);if(value===null)return;const index=Math.max(0,Math.min(bins-1,Math.floor((value-minimum)/step)));buckets[index].push(studioRowIndex(row));});const labels=buckets.map((_bucket,index)=>`${esc(prettyAxisName(x)||x)}: ${compactPlotNumber(minimum+index*step,6)}–${compactPlotNumber(minimum+(index+1)*step,6)}`);return linkedTrace({type:'bar',name,x:centers,y:buckets.map(bucket=>bucket.length),width:step*.92,customdata:labels,opacity:groups.size>1?Math.min(.72,Number($('opacity').value)):Number($('opacity').value),marker:{color:colors.get(name)||(groups.size===1?generalDataColor():undefined),line:{width:.55,color:'#48534c'}},selected:{marker:{opacity:1,line:{width:3,color:selectedDataColor()}}},unselected:{marker:{opacity:.32}},hovertemplate:'%{customdata}<br>Genes / rows: %{y}<br><b>Click to show only these linked rows</b><extra>'+wrapPlotHtml(name,30,3)+'</extra>'},buckets.map(bucket=>pointLink(bucket)));});
  }
  let volcanoDecorations={annotations:[],shapes:[],xRange:null,yRange:null};
  const volcanoColorscale=[[0,'#2c7bb6'],[.25,'#75c8a5'],[.5,'#ffffbf'],[.75,'#fdae61'],[1,'#d7191c']];
  function traceVolcano() {
    const x=state.roles.x, p=state.roles.y, label=state.roles.label; if (!x || !p) return [];
    const lfcCutoff=Math.max(0,Number($('volcanoLfcCutoff').value)||0), pCutoff=Math.min(1,Math.max(Number.MIN_VALUE,Number($('volcanoPCutoff').value)||.05));
    const minSize=Math.max(2,Number($('volcanoMinSize').value)||5),maxSize=Math.max(minSize,Number($('volcanoMaxSize').value)||20),neutral=foldNeutral();
    const points=state.rows.map((r,i)=>{const log2=numeric(r[x]),q=numeric(r[p]);if(log2===null||q===null)return null;const display=transformLog2Effect(log2);if(display===null)return null;const y=-Math.log10(Math.max(q,Number.MIN_VALUE));return {i,r,log2,display,q,y,status:q<=pCutoff&&log2>=lfcCutoff?'Upregulated':q<=pCutoff&&log2<=-lfcCutoff?'Downregulated':'Not significant'};}).filter(Boolean);
    const scores=points.map(d=>d.y).sort((a,b)=>a-b),cap=scores.length?scores[Math.min(scores.length-1,Math.floor(scores.length*.99))]:1,lo=scores.length?scores[0]:0,span=Math.max(Number.EPSILON,cap-lo);
    const sizes=points.map(d=>minSize+(maxSize-minSize)*Math.max(0,Math.min(1,(d.y-lo)/span)));
    const custom=points.map(d=>[label?d.r[label]:`Row ${d.i+1}`,d.q,d.status,d.log2]);
    // A single signed significance value lets the actual point colors and the vertical
    // scale use exactly the same encoding: negative = downregulated, zero = not
    // significant, positive = upregulated; distance from zero = −log10(p-value).
    const signedSignificance=points.map(d=>d.status==='Upregulated'?Math.min(cap,d.y):d.status==='Downregulated'?-Math.min(cap,d.y):0);
    const dynamicVolcanoScale=[[0,downDataColor()],[.46,significanceTint(downDataColor(),.32)],[.5,nsDataColor()],[.54,significanceTint(upDataColor(),.32)],[1,upDataColor()]];
    const halfCap=Math.max(Number.EPSILON,cap/2);
    const traces=[linkedTrace({type:'scattergl',mode:'markers',name:'Genes',showlegend:false,x:points.map(d=>d.display),y:points.map(d=>d.y),customdata:custom,marker:{size:sizes,color:signedSignificance,cmin:-cap,cmax:cap,cmid:0,colorscale:dynamicVolcanoScale,showscale:true,colorbar:{x:1.015,xanchor:'left',xpad:0,y:.5,yanchor:'middle',len:.72,thickness:14,outlinewidth:.8,outlinecolor:'#87938b',ticks:'outside',tickfont:{size:10},tickvals:[-cap,-halfCap,0,halfCap,cap],ticktext:[`Down ${cap.toFixed(1)}`,`Down ${halfCap.toFixed(1)}`,'Not sig.',`Up ${halfCap.toFixed(1)}`,`Up ${cap.toFixed(1)}`]},opacity:Number($('opacity').value),line:{width:.45,color:'rgba(45,55,48,.52)'}},selected:{marker:{opacity:1,line:{width:3,color:selectedDataColor()}}},unselected:{marker:{opacity:.2}},hovertemplate:'<b>%{customdata[0]}</b><br>'+foldScaleLabel()+': %{x:.4g}<br>analysis log₂ FC: %{customdata[3]:.4g}<br>−log₁₀('+p+'): %{y:.4g}<br>'+p+': %{customdata[1]:.4g}<br>status: %{customdata[2]}<extra></extra>'},points.map(d=>pointLink([d.i])))];
    const annotations=[];
    if($('volcanoCounts').checked){const up=points.filter(d=>d.status==='Upregulated').length,down=points.filter(d=>d.status==='Downregulated').length;const dp=state.volcanoCountPositions.down,upPos=state.volcanoCountPositions.up;annotations.push({x:dp.x,y:dp.y,xref:'paper',yref:'paper',text:`← Down ${down}`,showarrow:false,font:{color:downDataColor(),size:14},bgcolor:'rgba(0,0,0,0)',bordercolor:'rgba(0,0,0,0)',borderwidth:0,borderpad:0},{x:upPos.x,y:upPos.y,xref:'paper',yref:'paper',text:`Up ${up} →`,showarrow:false,font:{color:upDataColor(),size:14},bgcolor:'rgba(0,0,0,0)',bordercolor:'rgba(0,0,0,0)',borderwidth:0,borderpad:0});}
    const leftCut=transformLog2Effect(-lfcCutoff),rightCut=transformLog2Effect(lfcCutoff);
    const shapes=[{type:'line',x0:leftCut,x1:leftCut,y0:0,y1:1,yref:'paper',line:{dash:'dash',color:'#3f4942'}},{type:'line',x0:rightCut,x1:rightCut,y0:0,y1:1,yref:'paper',line:{dash:'dash',color:'#3f4942'}},{type:'line',x0:0,x1:1,xref:'paper',y0:-Math.log10(pCutoff),y1:-Math.log10(pCutoff),line:{dash:'dashdot',color:'#3f4942'}}];
    let xRange=null,yRange=null;
    if($('volcanoConnectors').checked&&label&&points.length){
      const n=Math.max(0,Math.min(20,Number($('volcanoLabelCount').value)||0)),sig=points.filter(d=>d.status!=='Not significant'),xs=points.map(d=>d.display),ys=points.map(d=>d.y),xmin=Math.min(...xs),xmax=Math.max(...xs),ymin=Math.min(0,...ys),ymax=Math.max(...ys,1),xspan=Math.max(Number.EPSILON,xmax-xmin),yspan=Math.max(1,ymax-ymin);
      const left=sig.filter(d=>d.log2<0).sort((a,b)=>b.y-a.y||Math.abs(b.log2)-Math.abs(a.log2)).slice(0,n),right=sig.filter(d=>d.log2>0).sort((a,b)=>b.y-a.y||Math.abs(b.log2)-Math.abs(a.log2)).slice(0,n),labelXLeft=xmin-xspan*.36,labelXRight=xmax+xspan*.36;
      function labelSlots(items){if(!items.length)return [];const top=ymax+yspan*.02,bottom=Math.max(ymin,ymax-yspan*.78),gap=items.length>1?(top-bottom)/(items.length-1):0;return items.map((d,j)=>({d,ly:top-gap*j}));}
      function addSide(items,side){labelSlots(items).forEach(({d,ly})=>{const lx=side==='left'?labelXLeft:labelXRight;annotations.push({x:d.display,y:d.y,ax:lx,ay:ly,xref:'x',yref:'y',axref:'x',ayref:'y',text:String(d.r[label]),showarrow:true,arrowhead:2,arrowsize:.85,arrowwidth:1.2,arrowcolor:'#68756d',standoff:5,startstandoff:2,xanchor:side==='left'?'left':'right',align:side==='left'?'left':'right',font:{size:11,color:'#26322a'},bgcolor:'rgba(255,255,255,0)',bordercolor:'rgba(0,0,0,0)',borderwidth:0,borderpad:0});});}
      addSide(left,'left');addSide(right,'right');xRange=[xmin-xspan*.48,xmax+xspan*.48];yRange=[ymin,ymax+yspan*.10];
    }
    volcanoDecorations={annotations,shapes,xRange,yRange};
    return traces;
  }
  // v40: Circos pan/zoom is performed in real Plotly coordinates, never by CSS-transforming the rendered canvas.
  // Keep these compatibility helpers because older control paths call them when resetting/changing contigs.
  function resetCircosCamera({apply=true}={}) { state.circosCamera={x:0,y:0,scale:1}; }
  function applyCircosCamera() { const graph=$('plot');if(graph)graph.classList.toggle('circos-free-camera',$('plotType')?.value==='Circos'&&$('dragMode')?.value==='pan'); }
  function zoomCircosCamera(_multiplier,_clientX=null,_clientY=null) { return false; }
  function normalizeCircleAngle(value) { const n=Number(value);return Number.isFinite(n)?((n%360)+360)%360:null; }
  function circosAngleVisible(angle) { const a=normalizeCircleAngle(angle),view=state.circosAngularView;if(a===null)return false;if(!view)return true;let u=a;while(u<view.start)u+=360;return u<=view.start+view.span+1e-9; }
  function circosDisplayAngle(angle) { const a=normalizeCircleAngle(angle),view=state.circosAngularView;if(a===null)return 0;if(!view)return a;let u=a;while(u<view.start)u+=360;/* Keep the selected interval as a true partial arc. Radial magnification is applied separately by the polar camera so a 1/5-genome selection stays a 1/5-circle arc but is visibly enlarged rather than merely cut from the original circle. */return (u-view.start)-view.span/2; }
  function circosVisibleInterval(a,b) { const view=state.circosAngularView;if(!view)return [a,b];const lo=view.start,hi=view.start+view.span,candidates=[[a,b],[a+360,b+360],[a-360,b-360]];let best=null;for(const [ca,cb] of candidates){const x0=Math.max(lo,ca),x1=Math.min(hi,cb);if(x1>x0&&(!best||x1-x0>best[1]-best[0]))best=[x0,x1];}return best?[best[0]-lo-view.span/2,best[1]-lo-view.span/2]:null; }
  function circosVisibleArcAngles(stepDegrees=1) { const view=state.circosAngularView;if(!view)return Array.from({length:361},(_,i)=>i);const span=Math.max(.5,Math.min(360,view.span)),steps=Math.max(8,Math.ceil(span/Math.max(.25,stepDegrees)));return Array.from({length:steps+1},(_,i)=>-span/2+span*i/steps); }
  function circosRadialMinimum(radialMax) { const view=state.circosAngularView;if(!view||view.span>=359.5)return 0;const focus=Math.max(0,Math.min(1,1-view.span/360)),targetBaseFraction=Math.min(.86,.58+.30*Math.pow(focus,.72)),den=Math.max(.08,1-targetBaseFraction),raw=(1-targetBaseFraction*radialMax)/den;return Math.max(-radialMax*1.65,Math.min(0,raw)); }
  function minimalCircularWindow(angles) { const values=angles.map(normalizeCircleAngle).filter(v=>v!==null).sort((a,b)=>a-b);if(!values.length)return null;const current=state.circosAngularView;const currentSpan=current?current.span:360;if(values.length===1){const span=Math.max(2,Math.min(40,currentSpan*.18));return {start:normalizeCircleAngle(values[0]-span/2),span};}let largest=-1,gapIndex=0;for(let i=0;i<values.length;i++){const a=values[i],b=i===values.length-1?values[0]+360:values[i+1],gap=b-a;if(gap>largest){largest=gap;gapIndex=i;}}let start=values[(gapIndex+1)%values.length],end=values[gapIndex];if(end<start)end+=360;let span=Math.max(.5,end-start),pad=Math.max(.8,span*.12);span=Math.min(currentSpan,span+2*pad);start=normalizeCircleAngle(start-pad);return {start,span}; }
  function zoomCircosToSelectedPoints(points) { const angles=[];for(const point of points||[]){const custom=point?.customdata;if(Array.isArray(custom)&&custom[0]==='__studio_rows__'){const a=numeric(custom[12]);if(a!==null)angles.push(a);}}const view=minimalCircularWindow(angles);if(!view){$('plotMessage').textContent='The Circos zoom box did not contain a gene bar. Drag a box over the genomic bars you want to enlarge.';return;}if(view.span>=359.5){state.circosAngularView=null;}else{state.circosAngularView=view;}resetCircosCamera({apply:false});const fraction=Math.max(1,Math.round(360/Math.max(.1,view.span)));$('plotMessage').textContent=state.circosAngularView?`Circos partial-arc zoom: ${Math.max(.1,view.span).toFixed(1)}° shown (about 1/${fraction} of a circle). The interval keeps its true angular fraction and its radius is magnified to use the canvas more effectively; Reset restores all contigs.`:'Circos returned to the complete circle.';renderPlot(); }

  function circosEffectColumns() {
    const isEffect=name=>isEffectColumn(name);
    const matches=state.columns.filter(c=>isEffect(c.name)&&columnNumericFraction(c.name)>=.35).map(c=>c.name);
    if(state.roles.y&&isEffect(state.roles.y)&&!matches.includes(state.roles.y))matches.unshift(state.roles.y);
    return unique(matches).slice(0,8);
  }
  function matchingProbabilityColumn(effectName) {
    const suffix=String(effectName||'').replace(/^(log2.*fold(change)?|logfc|effect)[ _.-]*/i,'');
    const candidates=state.columns.filter(c=>(/padj/i.test(c.name)||/fdr/i.test(c.name)||/adj.*p/i.test(c.name)||/pvalue/i.test(c.name))&&columnNumericFraction(c.name)>=.35);
    if(suffix){const match=candidates.find(c=>c.name.toLowerCase().includes(suffix.toLowerCase()));if(match)return match.name;}
    return state.roles.value||candidates[0]?.name||null;
  }
  function traceCircos() {
    let startCol=(state.roles.x&&columnNumericFraction(state.roles.x)>=.25)?state.roles.x:numericByPattern([/^start$/i,/gene.*start/i,/position/i],false),endCol=numericByPattern([/^end$/i,/gene.*end/i,/stop/i],false),seqCol=genomeSeqColumn(),label=state.roles.label||identityColumn();
    const effects=circosEffectColumns();if(!effects.length||!startCol)return [];
    const selectedContigs=selectedGenomeContigs('Circos');if(!selectedContigs.size){$('plotMessage').textContent='Select at least one contig / replicon for Circos.';return [];}
    const usable=state.rows.map((r,i)=>({r,i,start:numeric(r[startCol]),end:endCol?numeric(r[endCol]):null,seq:String(seqCol?r[seqCol]||'Genome':'Genome')})).filter(d=>d.start!==null&&selectedContigs.has(d.seq)).map(d=>({...d,end:d.end===null?d.start:d.end}));
    if(!usable.length)return [];
    // Prefer vector SVG strokes whenever the visible Circos complexity is reasonable.
    // This keeps radial bars razor-sharp during native coordinate zoom instead of enlarging rasterized WebGL strokes.
    const vectorCircos=Boolean(state.circosAngularView&&state.circosAngularView.span<359.5)||(usable.length*Math.max(1,effects.length)<=18000),visualLineType=vectorCircos?'scatter':'scattergl';
    const ranges=new Map();usable.forEach(d=>{if(!ranges.has(d.seq))ranges.set(d.seq,{min:d.start,max:d.end});const g=ranges.get(d.seq);g.min=Math.min(g.min,d.start);g.max=Math.max(g.max,d.end);});
    const seqs=[...ranges.keys()].sort((a,b)=>String(a).localeCompare(String(b),undefined,{numeric:true}));
    const rawTotal=seqs.reduce((sum,k)=>sum+Math.max(1,ranges.get(k).max-ranges.get(k).min+1),0),gap=Math.max(1,rawTotal*.014),offsets=new Map();let cursor=0;
    seqs.forEach(k=>{offsets.set(k,cursor);cursor+=Math.max(1,ranges.get(k).max-ranges.get(k).min+1)+gap;});const total=cursor;
    function thetaAt(seq,pos){const g=ranges.get(seq);return 360*(offsets.get(seq)+(pos-g.min))/total;}
    function theta(d){return (thetaAt(d.seq,d.start)+thetaAt(d.seq,d.end))/2;}
    function niceStep(length){const target=Math.max(1,length/6),pow=Math.pow(10,Math.floor(Math.log10(target))),frac=target/pow;return (frac<=1?1:frac<=2?2:frac<=5?5:10)*pow;}
    function polarXY(angle,r){const rad=Number(angle)*Math.PI/180;return [Number(r)*Math.sin(rad),Number(r)*Math.cos(rad)];}
    const pCutoff=Math.min(1,Math.max(Number.MIN_VALUE,Number($('circosPCutoff').value)||.05)),sigOnly=$('circosSigOnly').checked,traces=[],trackGap=.50,amplitude=.36,neutral=foldNeutral();
    effects.forEach((effect,trackIndex)=>{
      const pcol=matchingProbabilityColumn(effect),base=1+trackIndex*trackGap;
      const rows=usable.map(d=>{const log2=numeric(d.r[effect]),display=transformLog2Effect(log2),p=pcol?numeric(d.r[pcol]):null,sig=!pcol||p===null||p<=pCutoff,nativeAngle=theta(d);return {...d,log2,display,p,sig,nativeAngle};}).filter(d=>d.log2!==null&&d.display!==null).filter(d=>!sigOnly||d.sig).filter(d=>circosAngleVisible(d.nativeAngle)).map(d=>({...d,angle:circosDisplayAngle(d.nativeAngle)}));
      const deviations=rows.map(d=>Math.abs(d.display-neutral)).filter(Number.isFinite).sort((a,b)=>a-b),robustCap=deviations.length?Math.max(Number.EPSILON,deviations[Math.min(deviations.length-1,Math.floor(deviations.length*.98))]):1;
      function addBars(kind,color,opacity){
        const subset=rows.filter(d=>kind==='up'?(d.sig&&d.log2>0):kind==='down'?(d.sig&&d.log2<0):!d.sig);if(!subset.length)return;
        const lineX=[],lineY=[],lineLinks=[],hitX=[],hitY=[],hitLinks=[],hitCustom=[],selectedTipX=[],selectedTipY=[];
        // Keep Circos hover/click reliable at extreme native-coordinate zoom. A single
        // invisible marker at the radial-bar midpoint can move completely outside the
        // viewport while a portion of the same bar is still visible. Place a small set
        // of hit markers along the full radial segment instead, including both tips.
        // Marker size is screen-space, so the target remains comfortable at every zoom.
        const hitFractions=[0,.25,.5,.75,1];
        subset.forEach(d=>{const mag=Math.min(1,Math.abs(d.display-neutral)/robustCap)*amplitude,r0=d.log2<0?base-mag:base,r1=d.log2<0?base:base+mag,a=polarXY(d.angle,r0),b=polarXY(d.angle,r1),tip=d.log2<0?a:b,tipFraction=d.log2<0?0:1,link=pointLink([d.i]),custom=['__studio_rows__',d.i,label?d.r[label]:`Row ${d.i+1}`,d.display,d.log2,d.p,d.seq,d.start,d.end,d.r.product||d.r.protein_name||d.r.description||'',effect,d.sig?'Significant':'Not significant',d.nativeAngle];lineX.push(a[0],b[0],null);lineY.push(a[1],b[1],null);lineLinks.push(pointLink([]),pointLink([]),pointLink([]));hitFractions.forEach(f=>{const q=polarXY(d.angle,r0+(r1-r0)*f);hitX.push(q[0]);hitY.push(q[1]);/* Keep every point hover/clickable through customdata, but expose only one focus anchor per gene (the free radial tip, on the first track) to spreadsheet-driven selection. This prevents five selection rings from appearing along one radial bar. */hitLinks.push(trackIndex===0&&f===tipFraction?link:pointLink([]));hitCustom.push(custom);});if(trackIndex===0&&state.selectedRows.has(d.i)){selectedTipX.push(tip[0]);selectedTipY.push(tip[1]);}});
        traces.push(linkedTrace({type:visualLineType,mode:'lines',name:trackIndex===0?(kind==='up'?'Upregulated':kind==='down'?'Downregulated':'Not significant'):effect+' '+kind,showlegend:trackIndex===0,x:lineX,y:lineY,line:{width:2.2,color,simplify:false},opacity,hoverinfo:'skip',connectgaps:false},lineLinks));
        const hovertemplate='<b>%{customdata[2]}</b><br>comparison: %{customdata[10]}<br>'+foldScaleLabel()+': %{customdata[3]:.4g}<br>analysis log₂ FC: %{customdata[4]:.4g}<br>'+(pcol?pcol+': %{customdata[5]:.4g}<br>':'')+'status: %{customdata[11]}<br>replicon: %{customdata[6]}<br>position: %{customdata[7]}–%{customdata[8]}<br>%{customdata[9]}<extra></extra>';
        /* Fully transparent WebGL markers still participate in Plotly's picking buffer, so hover/click stays active without thousands of tiny alpha-blended black markers accumulating into an ugly dark ring. */
        traces.push(linkedTrace({type:'scattergl',mode:'markers',name:'Circos gene hit targets',showlegend:false,x:hitX,y:hitY,customdata:hitCustom,marker:{size:18,color:'rgba(0,0,0,0)',line:{width:0,color:'rgba(0,0,0,0)'}},hovertemplate,selected:{marker:{size:18,color:'rgba(0,0,0,0)',line:{width:0,color:'rgba(0,0,0,0)'}}},unselected:{marker:{opacity:1}}},hitLinks));
        if(selectedTipX.length)traces.push(linkedTrace({type:'scatter',mode:'markers',showlegend:false,hoverinfo:'skip',x:selectedTipX,y:selectedTipY,marker:{size:14,symbol:'circle-open',color:selectedDataColor(),line:{width:2.4,color:selectedDataColor()}}},[]));
      }
      addBars('up',upDataColor(),.96);addBars('down',downDataColor(),.96);if(!sigOnly)addBars('ns',nsDataColor(),.58);
      const baselineTheta=circosVisibleArcAngles(1),bx=[],by=[];baselineTheta.forEach(a=>{const q=polarXY(a,base);bx.push(q[0]);by.push(q[1]);});traces.push(linkedTrace({type:visualLineType,mode:'lines',name:effect,showlegend:false,hoverinfo:'skip',x:bx,y:by,line:{width:.8,color:'#c2cbc5',simplify:false},opacity:.44},[]));
    });
    const outer=1+Math.max(0,effects.length-1)*trackGap+amplitude+.24;
    seqs.forEach((seq,idx)=>{const g=ranges.get(seq),nativeA=360*offsets.get(seq)/total,nativeB=360*(offsets.get(seq)+(g.max-g.min+1))/total,color=repliconPalette[idx%repliconPalette.length],visible=circosVisibleInterval(nativeA,nativeB);if(!visible)return;const [a,b]=visible,steps=Math.max(8,Math.ceil(Math.max(1,b-a)/1.5)),arcX=[],arcY=[];for(let i=0;i<=steps;i++){const q=polarXY(a+(b-a)*i/steps,outer);arcX.push(q[0]);arcY.push(q[1]);}traces.push(linkedTrace({type:visualLineType,mode:'lines',name:seq,showlegend:false,hovertemplate:`<b>${seq}</b><extra></extra>`,x:arcX,y:arcY,line:{width:6,color,simplify:false}},[]));
      const mid=(a+b)/2,shift=seqs.length===2?(idx===0?-13:13):((idx%2===0?-1:1)*Math.min(10,Math.max(3,34/Math.max(1,seqs.length)))),rawLabelTheta=mid+shift,labelTheta=state.circosAngularView?rawLabelTheta:Math.max(2,Math.min(358,rawLabelTheta)),elbowR=outer+.055,labelR=outer+.205+(idx%2)*.025,leaderEndR=labelR-.085,p0=polarXY(mid,outer),p1=polarXY(mid,elbowR),p2=polarXY(labelTheta,leaderEndR),pt=polarXY(labelTheta,labelR);
      traces.push(linkedTrace({type:visualLineType,mode:'lines',showlegend:false,hoverinfo:'skip',x:[p0[0],p1[0],p2[0]],y:[p0[1],p1[1],p2[1]],line:{width:1.25,color,simplify:false}},[]));
      traces.push(linkedTrace({type:'scatter',mode:'text',name:seq,showlegend:false,hovertemplate:`<b>${seq}</b><extra></extra>`,x:[pt[0]],y:[pt[1]],text:[seq],textfont:{size:10,color},textposition:'middle center'},[]));
      const length=Math.max(1,g.max-g.min+1),step=niceStep(length),tx=[],ty=[];let tick=Math.ceil(g.min/step)*step;for(;tick<=g.max;tick+=step){const nativeAng=thetaAt(seq,tick);if(!circosAngleVisible(nativeAng))continue;const ang=circosDisplayAngle(nativeAng),q0=polarXY(ang,outer-.020),q1=polarXY(ang,outer+.010);tx.push(q0[0],q1[0],null);ty.push(q0[1],q1[1],null);}if(tx.length)traces.push(linkedTrace({type:visualLineType,mode:'lines',showlegend:false,hoverinfo:'skip',x:tx,y:ty,line:{width:.75,color:'#7d8981',simplify:false}},[]));
    });
    const boundR=outer+.31;let bounds=[-boundR,boundR,-boundR,boundR];if(state.circosAngularView&&state.circosAngularView.span<359.5){const angles=circosVisibleArcAngles(.5),xs=[],ys=[],inner=Math.max(.48,1-amplitude-.10);for(const a of angles){for(const r of [inner,boundR]){const q=polarXY(a,r);xs.push(q[0]);ys.push(q[1]);}}const xmin=Math.min(...xs),xmax=Math.max(...xs),ymin=Math.min(...ys),ymax=Math.max(...ys),dx=Math.max(.18,xmax-xmin),dy=Math.max(.18,ymax-ymin),padX=dx*.14,padY=dy*.14;bounds=[xmin-padX,xmax+padX,ymin-padY,ymax+padY];}
    traces.__circosOuter=boundR;traces.__circosTrackCount=effects.length;traces.__circosContigCount=seqs.length;traces.__circosAngularView=state.circosAngularView;traces.__circosBounds=bounds;return traces;
  }
  function traceGenomeRegion() {
    let startCol=(state.roles.x&&columnNumericFraction(state.roles.x)>=.25)?state.roles.x:numericByPattern([/^start$/i,/gene.*start/i,/position/i],false),endCol=numericByPattern([/^end$/i,/gene.*end/i,/stop/i],false),seqCol=genomeSeqColumn(),strandCol=firstColumn([/^strand$/i,/orientation/i],null,false),label=state.roles.label||identityColumn();
    if(!startCol)return [];
    const effects=circosEffectColumns(),preferredEffect=(state.roles.y&&isEffectColumn(state.roles.y))?state.roles.y:null,pCutoff=Math.min(1,Math.max(Number.MIN_VALUE,Number($('circosPCutoff').value)||.05)),windowGenes=Math.max(15,Math.min(200,Number($('genomeRegionGeneCount').value)||55));
    const usable=state.rows.map((r,i)=>({r,i,start:numeric(r[startCol]),end:endCol?numeric(r[endCol]):null,seq:String(seqCol?r[seqCol]||'Genome':'Genome')})).filter(d=>d.start!==null).map(d=>({...d,end:d.end===null?d.start:d.end,mid:(d.start+(d.end===null?d.start:d.end))/2}));if(!usable.length)return [];
    const bySeq=new Map();usable.forEach(d=>{if(!bySeq.has(d.seq))bySeq.set(d.seq,[]);bySeq.get(d.seq).push(d);});for(const rows of bySeq.values())rows.sort((a,b)=>a.start-b.start||a.end-b.end);
    const selectedContigs=selectedGenomeContigs('Genome region');
    const selectedSeqs=[...bySeq.keys()].filter(seq=>selectedContigs.has(seq)).sort((a,b)=>String(a).localeCompare(String(b),undefined,{numeric:true}));if(!selectedSeqs.length){$('plotMessage').textContent='Select at least one contig / replicon for Genome region.';return [];}
    const viewKey=selectedSeqs.join('\u0001')+'\u0002'+String(windowGenes);if(state.genomeRegionViewKey!==viewKey){state.genomeRegionViewKey=viewKey;state.genomeRegionViewRange=null;state.genomeRegionRenderedRange=null;state.genomeRegionLockedSpan=null;}
    function burden(d){if(!effects.length)return 0;let score=0;effects.forEach(effect=>{const v=Math.abs(numeric(d.r[effect])||0),pcol=matchingProbabilityColumn(effect),pv=pcol?numeric(d.r[pcol]):null;if(pv===null||pv<=pCutoff)score=Math.max(score,v);});return score;}
    const perSeqGenes=Math.max(8,Math.floor(windowGenes/Math.max(1,selectedSeqs.length))),segments=[];
    selectedSeqs.forEach(seq=>{
      const rows=bySeq.get(seq)||[];if(!rows.length)return;let centerIndex=-1;if(Number.isInteger(state.activeRow))centerIndex=rows.findIndex(d=>d.i===state.activeRow);
      if(centerIndex<0){const span=Math.min(perSeqGenes,rows.length);let sum=rows.slice(0,span).reduce((a,d)=>a+burden(d),0),localBest=sum,localIndex=Math.floor(span/2);for(let i=span;i<rows.length;i++){sum+=burden(rows[i])-burden(rows[i-span]);if(sum>localBest){localBest=sum;localIndex=i-Math.floor(span/2);}}centerIndex=localIndex;}
      const half=Math.floor(perSeqGenes/2),lo=Math.max(0,Math.min(Math.max(0,rows.length-perSeqGenes),centerIndex-half)),windowRows=rows.slice(lo,Math.min(rows.length,lo+perSeqGenes));
      const fullNativeMin=Math.min(...rows.map(d=>Math.min(d.start,d.end))),fullNativeMax=Math.max(...rows.map(d=>Math.max(d.start,d.end)));
      if(selectedSeqs.length===1){segments.push({seq,rows,windowRows,bufferRows:rows,nativeMin:fullNativeMin,nativeMax:fullNativeMax,span:Math.max(1,fullNativeMax-fullNativeMin+1)});return;}
      const flank=Math.min(45,Math.max(10,Math.ceil(perSeqGenes*.55))),bufferRows=rows.slice(Math.max(0,lo-flank),Math.min(rows.length,lo+perSeqGenes+flank));if(!bufferRows.length)return;
      const nativeMin=Math.min(...bufferRows.map(d=>Math.min(d.start,d.end))),nativeMax=Math.max(...bufferRows.map(d=>Math.max(d.start,d.end)));segments.push({seq,rows,windowRows,bufferRows,nativeMin,nativeMax,span:Math.max(1,nativeMax-nativeMin+1)});
    });
    if(!segments.length)return [];
    const spanValues=segments.map(s=>s.span).sort((a,b)=>a-b),medianSpan=spanValues[Math.floor(spanValues.length/2)]||1,gap=Math.max(1,medianSpan*.12);let cursor=0;
    segments.forEach(seg=>{if(selectedSeqs.length===1){seg.offset=seg.nativeMin;seg.plotStart=seg.nativeMin;seg.plotEnd=seg.nativeMax;seg.center=(seg.plotStart+seg.plotEnd)/2;}else{seg.offset=cursor;seg.plotStart=cursor;seg.plotEnd=cursor+seg.span;seg.center=(seg.plotStart+seg.plotEnd)/2;cursor=seg.plotEnd+gap;}seg.rows.forEach(d=>{d.plotStart=seg.offset+(Math.min(d.start,d.end)-seg.nativeMin);d.plotEnd=seg.offset+(Math.max(d.start,d.end)-seg.nativeMin);d.plotMid=(d.plotStart+d.plotEnd)/2;});});
    const allNativeWidths=segments.flatMap(seg=>seg.rows.map(d=>Math.max(1,Math.abs(d.end-d.start)+1))).sort((a,b)=>a-b),globalMedianWidth=allNativeWidths[Math.floor(allNativeWidths.length/2)]||1;
    const fullMin=Math.min(...segments.map(s=>s.plotStart)),fullMax=Math.max(...segments.map(s=>s.plotEnd)),fullPad=Math.max(globalMedianWidth*1.5,(fullMax-fullMin)*.002,1),fullRange=[fullMin-fullPad,fullMax+fullPad];
    let focusRows=segments.flatMap(seg=>seg.windowRows),focusMin=Math.min(...focusRows.map(d=>d.plotStart)),focusMax=Math.max(...focusRows.map(d=>d.plotEnd)),focusSpan=Math.max(globalMedianWidth*8,focusMax-focusMin),focusPad=Math.max(globalMedianWidth*2,focusSpan*.06,1),xRange=[focusMin-focusPad,focusMax+focusPad];
    if(selectedSeqs.length===1&&Array.isArray(state.genomeRegionViewRange)&&state.genomeRegionViewRange.length===2){let a=numeric(state.genomeRegionViewRange[0]),b=numeric(state.genomeRegionViewRange[1]);if(a!==null&&b!==null&&a!==b){if(a>b)[a,b]=[b,a];const requestedSpan=Math.max(Number.EPSILON,Number(state.genomeRegionLockedSpan)||Math.abs(b-a)),mid=(a+b)/2;a=mid-requestedSpan/2;b=mid+requestedSpan/2;if(a<fullRange[0]){b+=fullRange[0]-a;a=fullRange[0];}if(b>fullRange[1]){a-=b-fullRange[1];b=fullRange[1];}xRange=[Math.max(fullRange[0],a),Math.min(fullRange[1],b)];}}
    if(selectedSeqs.length===1&&!Number.isFinite(Number(state.genomeRegionLockedSpan)))state.genomeRegionLockedSpan=Math.max(Number.EPSILON,xRange[1]-xRange[0]);
    if(selectedSeqs.length===1){const perf=PERFORMANCE_RENDERING,viewSpan=Math.max(globalMedianWidth*8,xRange[1]-xRange[0]),renderPad=perf?Math.max(globalMedianWidth*12,viewSpan*.55):Math.max(globalMedianWidth*25,viewSpan*1.2),renderLo=Math.max(fullRange[0],xRange[0]-renderPad),renderHi=Math.min(fullRange[1],xRange[1]+renderPad);segments[0].bufferRows=segments[0].rows.filter(d=>d.plotEnd>=renderLo&&d.plotStart<=renderHi);state.genomeRegionRenderedRange=[renderLo,renderHi];}else state.genomeRegionRenderedRange=[fullMin,fullMax];
    const allBuffer=segments.flatMap(seg=>seg.bufferRows),widths=allBuffer.map(d=>Math.max(1,Math.abs(d.end-d.start)+1)).sort((a,b)=>a-b),medianWidth=widths[Math.floor(widths.length/2)]||globalMedianWidth,showLabels=$('showLabels').checked,traces=[],guideEntries=[],allBarValues=[];
    function normalizedStrand(d){const st=String(strandCol?d.r[strandCol]||'':'').trim().toLowerCase().replace(/−|–/g,'-');if(st==='+'||st==='plus'||st==='forward'||st==='fwd'||st==='1'||st==='1.0')return '+';if(st==='-'||st==='minus'||st==='reverse'||st==='rev'||st==='-1'||st==='-1.0')return '-';return '.';}
    const strandCenterMinus=-.52,strandCenterPlus=.52,trackArrowHalfHeight=.165,trackArrowTipHalfHeight=.265;
    function arrowPolygon(d){const left=Math.min(d.plotStart,d.plotEnd),right=Math.max(d.plotStart,d.plotEnd),length=Math.max(1,right-left),targetHead=Math.max(1,medianWidth*.25),head=Math.min(length*.45,Math.max(length*.25,targetHead)),strand=normalizedStrand(d),y=strand==='-'?strandCenterMinus:strand==='+'?strandCenterPlus:0,h=trackArrowHalfHeight,tipH=trackArrowTipHalfHeight;if(strand==='.')return {x:[left,right,right,left,left],y:[y-h,y-h,y+h,y+h,y-h]};return strand==='-'?{x:[right,left+head,left+head,left,left+head,left+head,right,right],y:[y-h,y-h,y-tipH,y,y+tipH,y+h,y+h,y-h]}:{x:[left,right-head,right-head,right,right-head,right-head,left,left],y:[y-h,y-h,y-tipH,y,y+tipH,y+h,y+h,y-h]};}
    const topEffects=effects.length?effects.slice(0,6):(preferredEffect?[preferredEffect]:[]),selectedBarMarkers=[];
    topEffects.forEach((effect,effectIndex)=>{
      const pcol=matchingProbabilityColumn(effect),rows=allBuffer.map(d=>{const log2=numeric(d.r[effect]),display=transformLog2Effect(log2),p=pcol?numeric(d.r[pcol]):null,sig=!pcol||p===null||p<=pCutoff;return {...d,log2,display,p,sig};}).filter(d=>d.display!==null);
      if(!rows.length)return;
      const nEffects=Math.max(1,topEffects.length),barWidths=rows.map(d=>Math.max(1,(Math.max(1,Math.abs(d.end-d.start)+1)*.84)/nEffects)),barX=rows.map(d=>d.plotStart+(Math.max(1,Math.abs(d.end-d.start)+1)*(effectIndex+.5)/nEffects)),barColors=rows.map(d=>!d.sig?nsDataColor():d.log2>0?upDataColor():d.log2<0?downDataColor():nsDataColor());rows.forEach((d,j)=>{allBarValues.push(d.display);guideEntries.push({x:barX[j],value:d.display,strand:normalizedStrand(d),row:d.i});});
      rows.forEach((d,j)=>{if(state.selectedRows.has(d.i))selectedBarMarkers.push({x:barX[j],y:d.display,row:d.i,label:label?String(d.r[label]??`Row ${d.i+1}`):`Row ${d.i+1}`});});
      traces.push(linkedTrace({type:'bar',name:effect,showlegend:false,x:barX,y:rows.map(d=>d.display),width:barWidths,yaxis:'y',customdata:rows.map(d=>['__studio_rows__',d.i,label?d.r[label]:`Row ${d.i+1}`,d.log2,d.p,d.seq,d.start,d.end,Math.max(1,Math.abs(d.end-d.start)+1),d.r.product||d.r.protein_name||d.r.description||'',effect,d.sig?'Significant':'Not significant']),marker:{color:barColors,line:{width:1.15,color:'#111111'}},opacity:.94,hovertemplate:'<b>%{customdata[2]}</b><br>comparison: %{customdata[10]}<br>'+foldScaleLabel()+': %{y:.4g}<br>analysis log₂ FC: %{customdata[3]:.4g}'+(pcol?'<br>'+pcol+': %{customdata[4]:.4g}':'')+'<br>position: %{customdata[5]}:%{customdata[6]}–%{customdata[7]}<br>gene length: %{customdata[8]} bp<br>%{customdata[9]}<extra></extra>'},rows.map(d=>pointLink([d.i]))));
    });
    if(selectedBarMarkers.length){
      const finiteY=allBuffer.flatMap(d=>topEffects.map(effect=>transformLog2Effect(numeric(d.r[effect])))).filter(v=>v!==null&&Number.isFinite(Number(v))).map(Number),span=Math.max(1e-9,(finiteY.length?Math.max(...finiteY)-Math.min(...finiteY):1)),offset=Math.max(.08,span*.045);
      traces.push(linkedTrace({type:'scatter',mode:'markers',name:'Selected gene',showlegend:false,x:selectedBarMarkers.map(d=>d.x),y:selectedBarMarkers.map(d=>d.y),yaxis:'y',hoverinfo:'skip',marker:{symbol:'circle-open',size:19,color:selectedDataColor(),line:{width:4,color:selectedDataColor()}}},selectedBarMarkers.map(d=>pointLink([d.row]))));
      traces.push(linkedTrace({type:'scatter',mode:'markers+text',name:'Selected gene pointer',showlegend:false,x:selectedBarMarkers.map(d=>d.x),y:selectedBarMarkers.map(d=>d.y+(d.y>=0?offset:-offset)),yaxis:'y',text:selectedBarMarkers.length===1?selectedBarMarkers.map(d=>d.label):undefined,textposition:selectedBarMarkers.map(d=>d.y>=0?'top center':'bottom center'),textfont:{size:12,color:selectedDataColor()},hoverinfo:'skip',marker:{symbol:selectedBarMarkers.map(d=>d.y>=0?'triangle-down':'triangle-up'),size:17,color:selectedDataColor(),line:{width:1.5,color:'#ffffff'}}},selectedBarMarkers.map(d=>pointLink([d.row]))));
    }
    // Semantic color legend: the bars themselves use per-gene colors, so explicit
    // legend swatches are clearer than one legend entry per contrast.
    const geneEffect=preferredEffect||topEffects[0]||null,genePcol=geneEffect?matchingProbabilityColumn(geneEffect):null;
    function geneStyle(d){const log2=geneEffect?numeric(d.r[geneEffect]):null,p=genePcol?numeric(d.r[genePcol]):null,sig=!genePcol||p===null||p<=pCutoff;if(log2===null)return {fill:nsDataColor(),opacity:.72,log2:null,display:null,p,sig:false};return {fill:!sig?nsDataColor():log2>0?upDataColor():log2<0?downDataColor():nsDataColor(),opacity:sig?.92:.62,log2,display:transformLog2Effect(log2),p,sig};}
    // Draw many genes in a handful of grouped polygon traces instead of one Plotly trace per gene.
    // This preserves linked-row interaction while avoiding hundreds of SVG trace objects.
    const geneGroups=new Map();
    allBuffer.forEach(d=>{const poly=arrowPolygon(d),st=geneStyle(d),name=label?String(d.r[label]??`Row ${d.i+1}`):`Row ${d.i+1}`,selected=state.selectedRows.has(d.i),length=Math.max(1,Math.abs(d.end-d.start)+1),custom=[name,st.display,st.log2,st.p,d.seq,d.start,d.end,normalizedStrand(d),length,d.r.product||d.r.protein_name||d.r.description||'',geneEffect||'',st.sig?'Significant':'Not significant'],key=[st.fill,st.opacity,selected?'selected':'normal'].join('|');if(!geneGroups.has(key))geneGroups.set(key,{fill:st.fill,opacity:st.opacity,selected,x:[],y:[],customdata:[],links:[]});const g=geneGroups.get(key);for(let k=0;k<poly.x.length;k++){g.x.push(poly.x[k]);g.y.push(poly.y[k]);g.customdata.push(['__studio_rows__',d.i,...custom]);g.links.push(pointLink([d.i]));}g.x.push(null);g.y.push(null);g.customdata.push(null);g.links.push(pointLink([]));});
    geneGroups.forEach(g=>{traces.push(linkedTrace({type:'scatter',mode:'lines',name:'Gene track',showlegend:false,x:g.x,y:g.y,yaxis:'y2',fill:'toself',fillcolor:g.fill,opacity:g.opacity,line:{width:g.selected?2.0:1.0,color:g.selected?selectedDataColor():'#344239'},customdata:g.customdata,connectgaps:false,hoveron:'points+fills',hovertemplate:'<b>%{customdata[2]}</b><br>position: %{customdata[6]}:%{customdata[7]}–%{customdata[8]}<br>gene length: %{customdata[10]} bp<br>direction: %{customdata[9]}'+(geneEffect?'<br>'+foldScaleLabel()+': %{customdata[3]:.4g}<br>analysis log₂ FC: %{customdata[4]:.4g}'+(genePcol?'<br>'+genePcol+': %{customdata[5]:.4g}':''):'')+'<br>%{customdata[11]}<extra></extra>'},g.links));});
    if(showLabels){segments.forEach(seg=>{const candidates=seg.bufferRows.filter(d=>d.plotMid>=xRange[0]&&d.plotMid<=xRange[1]),span=Math.max(1,xRange[1]-xRange[0]),labelled=candidates.filter(d=>Math.max(1,Math.abs(d.end-d.start)+1)>=span/45).slice(0,16);if(labelled.length)traces.push(linkedTrace({type:'scatter',mode:'text',showlegend:false,hoverinfo:'skip',x:labelled.map(d=>d.plotMid),y:labelled.map(d=>normalizedStrand(d)==='-'?-.78:normalizedStrand(d)==='+'?.78:0),yaxis:'y2',text:labelled.map(d=>label?String(d.r[label]??''):''),textfont:{size:10,color:'#354239'}},labelled.map(d=>pointLink([d.i]))));});}
    const strandKinds=new Set(allBuffer.map(normalizedStrand)),strandTickVals=[],strandTickText=[];if(strandKinds.has('-')){strandTickVals.push(strandCenterMinus);strandTickText.push('− strand');}if(strandKinds.has('.')){strandTickVals.push(0);strandTickText.push('Strand unavailable');}if(strandKinds.has('+')){strandTickVals.push(strandCenterPlus);strandTickText.push('+ strand');}
    const finiteBarValues=allBarValues.filter(v=>Number.isFinite(Number(v))).map(Number),barMin=Math.min(0,...finiteBarValues),barMax=Math.max(0,...finiteBarValues),barSpan=Math.max(1e-9,barMax-barMin||Math.max(1,Math.abs(barMax),Math.abs(barMin))),computedBarYRange=[barMin-barSpan*.055,barMax+barSpan*.055],autoScaleY=$('genomeRegionAutoScale')?.checked!==false;let barYRange=computedBarYRange;if(autoScaleY||!Array.isArray(state.genomeRegionYRange)||state.genomeRegionYRange.length!==2){state.genomeRegionYRange=[...computedBarYRange];}else{const lockedY=state.genomeRegionYRange.map(numeric);if(lockedY.every(v=>v!==null)&&lockedY[0]!==lockedY[1])barYRange=lockedY;else state.genomeRegionYRange=[...computedBarYRange];}
    const contigBlocks=segments.map(s=>({seq:s.seq,start:s.plotStart,end:s.plotEnd,center:s.center,nativeMin:s.nativeMin,nativeMax:s.nativeMax}));traces.__genomeRegion={seq:selectedSeqs.length===1?selectedSeqs[0]:`${selectedSeqs.length} selected contigs`,xRange,fullRange,effects:topEffects,geneEffect,strandTickVals,strandTickText,contigBlocks,multiContig:selectedSeqs.length>1,renderedRange:state.genomeRegionRenderedRange,guideEntries,barYRange,strandCenterMinus,strandCenterPlus,trackArrowHalfHeight,trackArrowTipHalfHeight};return traces;
  }

  function traceHeatmap() {
    const x=state.roles.x,y=state.roles.y,z=state.roles.value; if(!x||!z)return [];
    if(!y){
      const usable=state.rows.map((r,i)=>({r,i,v:displayedNumeric(r,z)})).filter(d=>d.v!==null).sort((a,b)=>Math.abs(b.v)-Math.abs(a.v)).slice(0,28);if(!usable.length)return [];
      const links=[usable.map(d=>pointLink([d.i]))],customdata=[links[0].map(link=>['__studio_rows__',...link.rows])];
      return [linkedTrace({type:'heatmap',x:usable.map(d=>d.r[x]),y:[z],z:[usable.map(d=>d.v)],customdata,colorscale:$('colorScale').value,colorbar:{title:prettyAxisName(z)},hovertemplate:'<b>%{x}</b><br>%{y}: %{z:.4g}<extra></extra>',meta:{bra_compact_heatmap:true}},links)];
    }
    const values=new Map(),sourceRows=new Map(),xScores=new Map(),yScores=new Map();
    state.rows.forEach(r=>{ const xv=r[x],yv=r[y],zv=displayedNumeric(r,z); if(zv===null)return; const xk=String(xv),yk=String(yv),k=xk+'\u0000'+yk,score=Math.abs(Number(zv)||0);if(!values.has(k))values.set(k,[]);values.get(k).push(zv);if(!sourceRows.has(k))sourceRows.set(k,[]);sourceRows.get(k).push(studioRowIndex(r));xScores.set(xk,(xScores.get(xk)||0)+score+1e-9);yScores.set(yk,(yScores.get(yk)||0)+score+1e-9); });
    const ranked=(scores,limit)=>[...scores.entries()].sort((a,b)=>b[1]-a[1]||a[0].localeCompare(b[0])).slice(0,limit).map(item=>item[0]);
    const xs=ranked(xScores,24),ys=ranked(yScores,18);if(!xs.length||!ys.length)return [];
    const matrix=ys.map(yv=>xs.map(xv=>{const k=String(xv)+'\u0000'+String(yv);return values.has(k)?aggregate(values.get(k),$('aggregation').value):null;}));
    const links=ys.map(yv=>xs.map(xv=>pointLink(sourceRows.get(String(xv)+'\u0000'+String(yv))||[])));
    const customdata=links.map(row=>row.map(link=>['__studio_rows__',...link.rows]));
    return [linkedTrace({type:'heatmap',x:xs,y:ys,z:matrix,customdata,colorscale:$('colorScale').value,colorbar:{title:prettyAxisName(z)},hovertemplate:'<b>%{x}</b><br>%{y}<br>'+prettyAxisName(z)+': %{z:.4g}<extra></extra>',meta:{bra_compact_heatmap:true}},links)];
  }
  function traceDot() {
    const traces=tracesScatter('markers'); traces.forEach(t=>{t.marker.sizemode='area'; t.marker.sizeref=1;}); return traces;
  }
  function traceNetwork() {
    const source=state.roles.x,target=state.roles.y; if(!source||!target)return [];
    const maxEdges=Math.max(10,Math.min(5000,Number($('networkEdges').value)||500));
    const edges=state.rows.slice(0,maxEdges).filter(r=>r[source]!==null&&r[target]!==null); const nodes=unique(edges.flatMap(r=>[String(r[source]),String(r[target])])).slice(0,700); const n=nodes.length; if(!n)return [];
    const degree=new Map(nodes.map(x=>[x,0])),nodeRows=new Map(nodes.map(x=>[x,[]])); edges.forEach(r=>{const a=String(r[source]),b=String(r[target]),index=studioRowIndex(r);if(degree.has(a)){degree.set(a,degree.get(a)+1);nodeRows.get(a).push(index);}if(degree.has(b)){degree.set(b,degree.get(b)+1);nodeRows.get(b).push(index);}});
    const pos=new Map(); const layout=$('networkLayout').value;
    if(layout==='grid'){const cols=Math.ceil(Math.sqrt(n));nodes.forEach((node,i)=>pos.set(node,[i%cols,-Math.floor(i/cols)]));}
    else if(layout==='concentric'){const sorted=[...nodes].sort((a,b)=>(degree.get(b)||0)-(degree.get(a)||0));sorted.forEach((node,i)=>{const ring=Math.floor(Math.sqrt(i)),start=ring*ring,count=Math.max(1,(ring+1)*(ring+1)-start),angle=2*Math.PI*(i-start)/count,r=ring+1;pos.set(node,[r*Math.cos(angle),r*Math.sin(angle)]);});}
    else {nodes.forEach((node,i)=>pos.set(node,[Math.cos(2*Math.PI*i/n),Math.sin(2*Math.PI*i/n)]));if(layout==='force'&&n<=250){const nodeIndex=new Map(nodes.map((x,i)=>[x,i]));const coords=nodes.map(x=>pos.get(x).slice());const area=16,k=Math.sqrt(area/n);for(let iter=0;iter<45;iter++){const disp=coords.map(()=>[0,0]);for(let i=0;i<n;i++)for(let j=i+1;j<n;j++){let dx=coords[i][0]-coords[j][0],dy=coords[i][1]-coords[j][1],d=Math.sqrt(dx*dx+dy*dy)+.01,f=k*k/d;disp[i][0]+=dx/d*f;disp[i][1]+=dy/d*f;disp[j][0]-=dx/d*f;disp[j][1]-=dy/d*f;}edges.forEach(e=>{const i=nodeIndex.get(String(e[source])),j=nodeIndex.get(String(e[target]));if(i===undefined||j===undefined)return;let dx=coords[i][0]-coords[j][0],dy=coords[i][1]-coords[j][1],d=Math.sqrt(dx*dx+dy*dy)+.01,f=d*d/k;disp[i][0]-=dx/d*f;disp[i][1]-=dy/d*f;disp[j][0]+=dx/d*f;disp[j][1]+=dy/d*f;});const temp=.12*(1-iter/45);for(let i=0;i<n;i++){const d=Math.sqrt(disp[i][0]**2+disp[i][1]**2)||1;coords[i][0]+=disp[i][0]/d*Math.min(d,temp);coords[i][1]+=disp[i][1]/d*Math.min(d,temp);}}nodes.forEach((node,i)=>pos.set(node,coords[i]));}}
    const ex=[],ey=[];edges.forEach(r=>{const a=pos.get(String(r[source])),b=pos.get(String(r[target]));if(!a||!b)return;ex.push(a[0],b[0],null);ey.push(a[1],b[1],null);});
    return [linkedTrace({type:'scatter',mode:'lines',x:ex,y:ey,hoverinfo:'skip',line:{width:1,color:colorToHex($('networkEdgeColor')?.value,'#7b8d83')},name:'Edges'},[]),linkedTrace({type:'scatter',mode:'markers'+($('showLabels').checked?'+text':''),x:nodes.map(x=>pos.get(x)[0]),y:nodes.map(x=>pos.get(x)[1]),text:nodes,textposition:'top center',hovertext:nodes,marker:{size:nodes.map(x=>6+Math.sqrt(degree.get(x)||0)*2),opacity:Number($('opacity').value),color:colorToHex($('networkNodeColor')?.value,'#377497')},selected:{marker:{opacity:1,line:{width:3,color:selectedDataColor()}}},unselected:{marker:{opacity:.2}},name:'Nodes'},nodes.map(node=>pointLink(nodeRows.get(node))))];
  }
  function genomeGuidePath(meta,range) {
    if(!meta||!Array.isArray(meta.guideEntries)||!Array.isArray(range)||range.length!==2)return '';let lo=numeric(range[0]),hi=numeric(range[1]);if(lo===null||hi===null||lo===hi)return '';if(lo>hi)[lo,hi]=[hi,lo];
    const visible=meta.guideEntries.filter(g=>Number.isFinite(Number(g.x))&&g.x>=lo&&g.x<=hi),guideCap=PERFORMANCE_RENDERING?110:160,stride=Math.max(1,Math.ceil(visible.length/guideCap)),entries=visible.filter((_g,i)=>i%stride===0),barRange=Array.isArray(meta.barYRange)?meta.barYRange:[-1,1],barDomain=[.158,1],trackRange=[-1.12,1.12],trackDomain=[.050,.142],map=(v,r,d)=>d[0]+((v-r[0])/Math.max(Number.EPSILON,r[1]-r[0]))*(d[1]-d[0]),parts=[];
    for(const g of entries){const value=Number(g.value),startValue=value<0?value:0,startPaper=Math.max(barDomain[0],Math.min(barDomain[1],map(startValue,barRange,barDomain))),strand=String(g.strand||'.'),center=strand==='-'?Number(meta.strandCenterMinus??-.52):strand==='+'?Number(meta.strandCenterPlus??.52):0,half=strand==='.'?Number(meta.trackArrowHalfHeight??.165):Number(meta.trackArrowTipHalfHeight??.265),arrowTop=Math.min(trackRange[1],center+half),endPaper=Math.max(trackDomain[0],Math.min(trackDomain[1],map(arrowTop,trackRange,trackDomain))),x=Number(g.x);if(!Number.isFinite(x))continue;parts.push(`M ${x},${startPaper.toFixed(6)} L ${x},${endPaper.toFixed(6)}`);}
    return parts.join(' ');
  }
  function updateGenomeGuidePath(lo,hi) {
    if($('plotType').value!=='Genome region'||!$('genomeRegionGuideLines')?.checked)return;const meta=state.figure?.data?.__genomeRegion,index=meta?.guideShapeIndex;if(!meta||!Number.isInteger(index))return;const path=genomeGuidePath(meta,[lo,hi]);try{Plotly.relayout('plot',{[`shapes[${index}].path`]:path});if(state.figure?.layout?.shapes?.[index])state.figure.layout.shapes[index].path=path;}catch(_err){}
  }
  function studioColorbarCandidates(graph){
    const candidates=[],seen=new Set(),add=item=>{if(item&&!seen.has(item.key)){seen.add(item.key);candidates.push(item);}};
    for(const key of Object.keys(graph?._fullLayout||{})){if(/^coloraxis\d*$/.test(key)&&graph._fullLayout[key]?.showscale!==false)add({kind:'layout',layoutKey:key,key:'layout:'+key});}
    (graph?._fullData||[]).forEach((trace,index)=>{const input=graph?.data?.[index]||trace,uid=String(trace?.uid||input?.uid||'');if(trace?.marker?.showscale===true&&!trace?.marker?.coloraxis)add({kind:'trace',traceIndex:index,path:'marker.colorbar',uid,key:'trace:'+index+':marker.colorbar'});if(trace?.showscale===true&&!trace?.coloraxis)add({kind:'trace',traceIndex:index,path:'colorbar',uid,key:'trace:'+index+':colorbar'});});return candidates;
  }
  function studioColorbarPosition(graph,descriptor){let source,full;if(descriptor.kind==='layout'){source=graph?.layout?.[descriptor.layoutKey]?.colorbar;full=graph?._fullLayout?.[descriptor.layoutKey]?.colorbar;}else{const input=graph?.data?.[descriptor.traceIndex],computed=graph?._fullData?.[descriptor.traceIndex];source=descriptor.path==='marker.colorbar'?input?.marker?.colorbar:input?.colorbar;full=descriptor.path==='marker.colorbar'?computed?.marker?.colorbar:computed?.colorbar;}const x=Number(source?.x),y=Number(source?.y),fullX=Number(full?.x),fullY=Number(full?.y);return {x:Number.isFinite(x)?x:(Number.isFinite(fullX)?fullX:1.02),y:Number.isFinite(y)?y:(Number.isFinite(fullY)?fullY:.5)};}
  function studioMoveColorbar(graph,descriptor,x,y){try{return descriptor.kind==='layout'?Promise.resolve(Plotly.relayout(graph,{[descriptor.layoutKey+'.colorbar.x']:x,[descriptor.layoutKey+'.colorbar.y']:y})):Promise.resolve(Plotly.restyle(graph,{[descriptor.path+'.x']:x,[descriptor.path+'.y']:y},[descriptor.traceIndex]));}catch(_err){return Promise.resolve();}}
  function studioColorbarEdit(update){return Boolean(update&&typeof update==='object'&&Object.keys(update).some(key=>/(?:^|\.)colorbar\.(?:x|y|xanchor|yanchor)$/.test(String(key))));}
  function studioCartesianDomains(graph){const domains={};for(const key of Object.keys(graph?._fullLayout||{})){if(!/^xaxis\d*$/.test(key))continue;const input=graph?.layout?.[key],full=graph?._fullLayout?.[key];if(input?.visible===false||full?.visible===false)continue;const domain=Array.isArray(input?.domain)?input.domain:full?.domain;if(Array.isArray(domain)&&domain.length===2&&domain.every(value=>Number.isFinite(Number(value))))domains[key]=domain.map(Number);}return domains;}
  function studioColorbarOccupiesRight(graph,positions){const anchoredRight=positions.some(item=>Number.isFinite(item.x)&&item.x>=.97),size=graph?._fullLayout?._size,rect=graph?.getBoundingClientRect?.(),bars=[...(graph?.querySelectorAll?.('g.colorbar')||[])];if(size&&rect&&bars.length){const paperRight=rect.left+Number(size.l||0)+Number(size.w||0);return anchoredRight||bars.some(bar=>{const box=bar.getBoundingClientRect();return box.width>0&&box.right>=paperRight+12;});}return anchoredRight;}
  function studioDomainUpdates(dragState,expand){const entries=Object.entries(dragState?.domains||{});if(!entries.length)return {};const minimum=Math.min(...entries.map(([,domain])=>domain[0])),maximum=Math.max(...entries.map(([,domain])=>domain[1])),updates={};if(!expand||maximum>=.995||maximum<=minimum){for(const [key,domain] of entries)updates[key+'.domain']=[...domain];return updates;}const scale=(1-minimum)/(maximum-minimum);for(const [key,domain] of entries)updates[key+'.domain']=[minimum+(domain[0]-minimum)*scale,minimum+(domain[1]-minimum)*scale];return updates;}
  function studioColorbarPixelGeometry(graph,descriptors){const size=graph?._fullLayout?._size,rect=graph?.getBoundingClientRect?.();if(!size||!rect||!Number.isFinite(Number(size.w))||Number(size.w)<=0)return null;const groups=[...(graph?.querySelectorAll?.('g.colorbar')||[])],paperLeft=rect.left+Number(size.l||0),paperRight=paperLeft+Number(size.w||0),items=descriptors.map((descriptor,index)=>{const classMatch=group=>{const name=String(group?.getAttribute?.('class')||'');return (descriptor.uid&&name.includes(descriptor.uid))||(descriptor.kind==='layout'&&name.includes(descriptor.layoutKey));},group=groups.find(classMatch)||groups[index],box=group?.getBoundingClientRect?.(),position=studioColorbarPosition(graph,descriptor);return {descriptor,position,anchorX:paperLeft+position.x*Number(size.w),box};});return {size,rect,paperLeft,paperRight,items};}
  function studioReflowForColorbars(graph){
    const dragState=graph?.__braStudioColorbarState;if(!dragState||dragState.applying||!studioPlotIsDisplayed(graph))return;const descriptors=studioColorbarCandidates(graph),positions=descriptors.map(item=>studioColorbarPosition(graph,item)),rightOccupied=studioColorbarOccupiesRight(graph,positions),geometry=studioColorbarPixelGeometry(graph,descriptors),requested=Number($('rightAxisSpace')?.value)||0;let target=requested||(rightOccupied?dragState.marginRight:28);
    if(!requested&&rightOccupied&&geometry){const rightBars=geometry.items.filter(item=>item.box?.width>0&&item.box.left>=geometry.paperRight-10);if(rightBars.length){const left=Math.min(...rightBars.map(item=>item.box.left));target=Math.max(36,Math.min(dragState.marginRight,Math.ceil(geometry.rect.right-left+10)));}}
    const anchors=geometry?.items.map(item=>({descriptor:item.descriptor,x:item.anchorX,y:item.position.y}))||[],update={'margin.r':target,...studioDomainUpdates(dragState,target<dragState.marginRight-1)};dragState.applying=true;
    Promise.resolve(Plotly.relayout(graph,update)).then(()=>{const size=graph?._fullLayout?._size,rect=graph?.getBoundingClientRect?.();if(!size||!rect||!Number.isFinite(Number(size.w))||Number(size.w)<=0)return;const paperLeft=rect.left+Number(size.l||0),width=Number(size.w);return Promise.all(anchors.map(item=>studioMoveColorbar(graph,item.descriptor,Math.max(-2,Math.min(3,(item.x-paperLeft)/width)),item.y)));}).then(()=>safeStudioResize(graph)).catch(()=>{}).finally(()=>{dragState.applying=false;});
  }
  function queueStudioColorbarReflow(graph){const dragState=graph?.__braStudioColorbarState;if(!dragState)return;if(dragState.frame)cancelAnimationFrame(dragState.frame);dragState.frame=requestAnimationFrame(()=>{dragState.frame=requestAnimationFrame(()=>{dragState.frame=0;studioReflowForColorbars(graph);});});}
  function bindStudioColorbarPointerDrag(graph){
    if(!graph||graph.__braStudioColorbarPointerBound)return;graph.__braStudioColorbarPointerBound=true;
    graph.addEventListener('pointerdown',event=>{
      if(event.button!==0||event.target?.closest?.('.modebar'))return;const group=event.target?.closest?.('g.colorbar');if(!group)return;
      const groups=[...(graph.querySelectorAll?.('g.colorbar')||[])],index=groups.indexOf(group),candidates=studioColorbarCandidates(graph),className=String(group.getAttribute?.('class')||''),descriptor=candidates.find(item=>item.uid&&className.includes(item.uid))||candidates.find(item=>item.kind==='layout'&&className.includes(item.layoutKey))||candidates[index];if(index<0||!descriptor)return;
      const start=studioColorbarPosition(graph,descriptor),size=graph?._fullLayout?._size,graphRect=graph.getBoundingClientRect(),barRect=group.getBoundingClientRect(),paperWidth=Math.max(1,Number(size?.w)||graph.clientWidth||1),paperHeight=Math.max(1,Number(size?.h)||graph.clientHeight||1),paperLeft=graphRect.left+Number(size?.l||0),anchorX=paperLeft+start.x*paperWidth,leftOffset=barRect.left-anchorX,rightOffset=barRect.right-anchorX,minX=Math.max(-2,(graphRect.left+4-paperLeft-leftOffset)/paperWidth),maxX=Math.min(3,(graphRect.right-4-paperLeft-rightOffset)/paperWidth),drag={id:event.pointerId,descriptor,startX:event.clientX,startY:event.clientY,valueX:start.x,valueY:start.y,paperWidth,paperHeight,minX:Math.min(minX,maxX),maxX:Math.max(minX,maxX),moved:false};
      graph.__braStudioColorbarDrag=drag;const state=graph.__braStudioColorbarState;if(state)state.dragging=true;graph.classList.add('bra-colorbar-dragging');
      const move=moveEvent=>{const current=graph.__braStudioColorbarDrag;if(!current||moveEvent.pointerId!==current.id)return;const dx=moveEvent.clientX-current.startX,dy=moveEvent.clientY-current.startY;if(Math.hypot(dx,dy)>3)current.moved=true;const x=Math.max(current.minX,Math.min(current.maxX,current.valueX+dx/current.paperWidth)),y=Math.max(.08,Math.min(.92,current.valueY-dy/current.paperHeight));studioMoveColorbar(graph,current.descriptor,x,y);moveEvent.preventDefault();moveEvent.stopPropagation();};
      const stop=upEvent=>{const current=graph.__braStudioColorbarDrag;if(!current||upEvent.pointerId!==current.id)return;window.removeEventListener('pointermove',move,true);window.removeEventListener('pointerup',stop,true);window.removeEventListener('pointercancel',stop,true);graph.__braStudioColorbarDrag=null;graph.classList.remove('bra-colorbar-dragging');const currentState=graph.__braStudioColorbarState;if(currentState)currentState.dragging=false;if(current.moved)queueStudioColorbarReflow(graph);upEvent.preventDefault();upEvent.stopPropagation();};
      window.addEventListener('pointermove',move,true);window.addEventListener('pointerup',stop,true);window.addEventListener('pointercancel',stop,true);event.preventDefault();event.stopPropagation();
    },true);
  }
  function prepareDraggableColorbars(graph){
    if(!graph)return;const full=graph._fullLayout||{},explicitRight=Number(graph.layout?.margin?.r),computedRight=Number(full?.margin?.r),dragState={marginRight:Number.isFinite(explicitRight)?explicitRight:(Number.isFinite(computedRight)?computedRight:170),bars:{},domains:studioCartesianDomains(graph),applying:false,frame:0};for(const item of studioColorbarCandidates(graph))dragState.bars[item.key]={descriptor:item,...studioColorbarPosition(graph,item)};graph.__braStudioColorbarState=dragState;if(graph.__braStudioColorbarDragBound||typeof graph.on!=='function')return;graph.__braStudioColorbarDragBound=true;
    // Plotly does not consistently expose native colour-bar dragging for every
    // trace type (notably scattergl). The pointer controller covers the whole
    // rendered bar, then reclaims its former right gutter after the move.
    bindStudioColorbarPointerDrag(graph);
    graph.on('plotly_relayout',update=>{const current=graph.__braStudioColorbarState;if(!current?.applying&&!current?.dragging&&studioColorbarEdit(update))queueStudioColorbarReflow(graph);});
    graph.on('plotly_restyle',update=>{const current=graph.__braStudioColorbarState,payload=Array.isArray(update)?update[0]:update;if(!current?.dragging&&studioColorbarEdit(payload))queueStudioColorbarReflow(graph);});
  }
  function resetStudioColorbars(graph){const dragState=graph?.__braStudioColorbarState;if(!dragState||!studioPlotIsDisplayed(graph))return;dragState.applying=true;Promise.resolve(Plotly.relayout(graph,{'margin.r':dragState.marginRight,...studioDomainUpdates(dragState,false)})).then(()=>{for(const saved of Object.values(dragState.bars))studioMoveColorbar(graph,saved.descriptor,saved.x,saved.y);return safeStudioResize(graph);}).catch(()=>{}).finally(()=>{dragState.applying=false;});}
  function studioHasVisibleColorbar(data,layout){for(const key of Object.keys(layout||{})){if(/^coloraxis\d*$/.test(key)&&layout[key]?.showscale!==false)return true;}const colourTypes=new Set(['heatmap','contour','histogram2d','histogram2dcontour','surface','mesh3d','cone','streamtube','isosurface','volume','choropleth','choroplethmap','choroplethmapbox']);return (data||[]).some(trace=>trace?.marker?.showscale===true||trace?.showscale===true||(colourTypes.has(String(trace?.type||'').toLowerCase())&&trace?.showscale!==false));}
  function renderPlot() {
    if (!state.rows.length) return;
    if(hasSpecializedWorkspace()&&$('analysisSelect')&&!$('analysisSelect').value){try{Plotly.purge('plot');}catch(_err){}state.figure=null;state.plotEventsBound=false;$('plotMessage').textContent='Choose a plot or analysis in section 1.';return;}
    const type=$('plotType').value,restoreSelectionRow=Number.isInteger(state.activeRow)&&state.selectedRows.has(state.activeRow)?state.activeRow:null; state.plotSelectionInfo=null; state.categoryPlotNotice=''; applyGenericTypographyCss(); updateRelevantControls(); let data=[];
    try {
      if(type==='Scatter') data=tracesScatter('markers');
      else if(type==='Line') data=tracesScatter('lines+markers');
      else if(type==='Bar') data=tracesBar();
      else if(type==='Violin + box') data=tracesDistribution(type);
      else if(type==='Histogram') data=traceHistogram();
      else if(type==='Heatmap') data=traceHeatmap();
      else if(type==='Volcano') data=traceVolcano();
      else if(type==='MA plot') data=tracesScatter('markers');
      else if(type==='Circos') data=traceCircos();
      else if(type==='Genome region') data=traceGenomeRegion();
      else if(type==='Dot plot') data=traceDot();
      else if(type==='Network') data=traceNetwork();
    } catch (err) { $('plotMessage').textContent='Could not construct the plot: '+err.message; return; }
    if(!data.length){ $('plotMessage').textContent='Assign the required variables for '+type+'.'; Plotly.purge('plot'); state.figure=null; state.plotEventsBound=false; return; }
    const dark=$('theme').value==='dark', simple=$('theme').value==='simple',plotBackground=colorToHex($('plotBackgroundColor')?.value,dark?'#202522':'#ffffff');
    const showGrid=$('showGrid').checked,mainPanel=document.querySelector('.main-panel');
    if(mainPanel){mainPanel.classList.toggle('plot-large',['Circos','Volcano','Genome region'].includes(type));mainPanel.classList.toggle('plot-circos',type==='Circos');mainPanel.classList.toggle('plot-volcano',type==='Volcano');mainPanel.classList.toggle('plot-genome',type==='Genome region');}
    const plotNode=$('plot');if(plotNode){plotNode.style.aspectRatio='auto';plotNode.style.width='100%';plotNode.style.height='100%';const existingContainer=plotNode.querySelector('.plot-container');if(existingContainer)existingContainer.style.transform='';}
    const [defaultXTitle,defaultYTitle]=defaultAxisTitles(type),legendTraceCount=data.filter(trace=>trace&&trace.showlegend!==false&&trace.name&&!/ baseline$/i.test(String(trace.name))).length;
    const showAxisTitles=!$('showAxisTitles')||$('showAxisTitles').checked;
    const titleTop=$('plotTitle').value?64:24,needBottomLegend=$('showLegend').checked&&legendTraceCount>1;
    const layout={title:{text:$('plotTitle').value||''},xaxis:{title:{text:$('xTitle').value||defaultXTitle||'',standoff:6},showgrid:showGrid,automargin:true},yaxis:{title:{text:$('yTitle').value||defaultYTitle||''},showgrid:showGrid,automargin:true},showlegend:$('showLegend').checked&&legendTraceCount>1,hovermode:'closest',hoverdistance:35,hoverlabel:{bgcolor:'#ffffff',bordercolor:'#789083',font:{family:graphFont().family,color:'#173426',size:Math.max(12,Number(graphFont().size)||12)},align:'left',namelength:-1},dragmode:$('dragMode').value,barmode:'group',uirevision:type==='Genome region'?('genome-region-'+String(state.activeRow??'default')):('studio-'+type),autosize:true,margin:{l:60,r:28,t:titleTop,b:needBottomLegend?104:76},paper_bgcolor:plotBackground,plot_bgcolor:plotBackground,font:graphFont(),legend:{orientation:'h',y:-0.14}};
    if(type==='Volcano'){layout.xaxis.title.text=$('xTitle').value||foldScaleLabel();layout.yaxis.title.text=$('yTitle').value||defaultYTitle||('−log₁₀('+prettyAxisName(state.roles.y)+')');layout.shapes=volcanoDecorations.shapes;layout.annotations=volcanoDecorations.annotations;if(volcanoDecorations.xRange)layout.xaxis.range=volcanoDecorations.xRange;if(volcanoDecorations.yRange)layout.yaxis.range=volcanoDecorations.yRange;layout.showlegend=false;layout.margin={l:42,r:$('showLegend').checked?185:42,t:($('volcanoConnectors').checked?34:($('volcanoCounts').checked?58:titleTop)),b:76};}
    if(type==='MA plot'&&state.roles.x){layout.xaxis.type='log';layout.xaxis.title.text=$('xTitle').value||'Mean normalized expression';layout.yaxis.title.text=$('yTitle').value||foldScaleLabel();}
    if(type==='Network'){const xText=$('xTitle').value||'',yText=$('yTitle').value||'',xVisible=showAxisTitles&&Boolean(xText.trim()),yVisible=showAxisTitles&&Boolean(yText.trim());layout.xaxis={visible:xVisible,showticklabels:false,showgrid:false,zeroline:false,title:{text:xText}};layout.yaxis={visible:yVisible,showticklabels:false,showgrid:false,zeroline:false,title:{text:yText},scaleanchor:'x',scaleratio:1};layout.showlegend=false;layout.margin={l:yVisible?64:20,r:20,t:titleTop,b:xVisible?56:20};}
    if(type==='Histogram'&&genomeSeqColumn()&&selectedGenomeContigs('Histogram').size>1){layout.barmode='overlay';}
    if(type==='Histogram'){layout.xaxis.tickformat='.4~g';layout.xaxis.exponentformat='power';layout.xaxis.showexponent='all';layout.xaxis.automargin=true;}
    if(type==='Heatmap'){
      const heat=data.find(trace=>trace&&trace.type==='heatmap'),xValues=Array.isArray(heat?.x)?heat.x:[],yValues=Array.isArray(heat?.y)?heat.y:[];
      if(xValues.length>12){layout.xaxis.tickmode='array';layout.xaxis.tickvals=xValues;layout.xaxis.ticktext=xValues.map((_value,index)=>String(index+1));layout.xaxis.tickangle=0;layout.xaxis.title.text=(layout.xaxis.title.text||prettyAxisName(state.roles.x))+' (numbered; hover for full labels)';layout.margin.b=Math.max(layout.margin.b,76);}
      if(yValues.length>12){layout.yaxis.tickmode='array';layout.yaxis.tickvals=yValues;layout.yaxis.ticktext=yValues.map((_value,index)=>String(index+1));layout.yaxis.title.text=(layout.yaxis.title.text||prettyAxisName(state.roles.y))+' (numbered; hover for full labels)';layout.margin.l=Math.max(layout.margin.l,92);}
    }
    if(type==='Circos'){const bounds=Array.isArray(data.__circosBounds)?data.__circosBounds:[-1.6,1.6,-1.6,1.6],angular=data.__circosAngularView;layout.xaxis={visible:false,range:[bounds[0],bounds[1]],showgrid:false,zeroline:false,fixedrange:false};layout.yaxis={visible:false,range:[bounds[2],bounds[3]],showgrid:false,zeroline:false,fixedrange:false,scaleanchor:'x',scaleratio:1};layout.dragmode=$('dragMode').value;layout.hovermode='closest';layout.hoverdistance=24;layout.uirevision='circos-'+(angular?`${Number(angular.start).toFixed(3)}-${Number(angular.span).toFixed(3)}`:'full');layout.showlegend=$('showLegend').checked&&legendTraceCount>1;layout.legend={orientation:'h',x:0,y:-.08,xanchor:'left',yanchor:'top'};layout.margin={l:28,r:28,t:$('plotTitle').value?58:28,b:layout.showlegend?72:28};}
      if(type==='Genome region'){const meta=data.__genomeRegion;if(meta){const multi=Boolean(meta.multiContig),blocks=meta.contigBlocks||[];layout.dragmode=$('dragMode').value;layout.xaxis={title:{text:$('xTitle').value||(multi?'Selected contig windows · hover for native genomic position':'Genomic position'),standoff:2},range:meta.xRange,minallowed:meta.fullRange[0],maxallowed:meta.fullRange[1],showgrid:showGrid,automargin:true,zeroline:false,ticks:'outside',side:'top'};if(multi){layout.xaxis.tickmode='array';layout.xaxis.tickvals=blocks.map(b=>b.center);layout.xaxis.ticktext=blocks.map(b=>b.seq);layout.xaxis.tickangle=0;layout.shapes=(layout.shapes||[]).concat(blocks.slice(0,-1).map((b,i)=>({type:'line',xref:'x',yref:'paper',x0:(b.end+blocks[i+1].start)/2,x1:(b.end+blocks[i+1].start)/2,y0:0,y1:1,line:{color:'#c8d2cb',width:1,dash:'dot'}})));}else layout.xaxis.tickformat='~s';layout.yaxis={title:{text:$('yTitle').value||foldScaleLabel(),standoff:5},domain:[.158,1],range:meta.barYRange,showgrid:showGrid,automargin:true,zeroline:true,zerolinewidth:1.2,zerolinecolor:'#87958b'};layout.yaxis2={title:{text:''},domain:[.050,.142],range:[-1.12,1.12],tickmode:'array',tickvals:meta.strandTickVals||[-.52,.52],ticktext:meta.strandTickText||['− strand','+ strand'],showgrid:false,automargin:false,zeroline:true,zerolinewidth:1,zerolinecolor:'#d9e1dc',anchor:'x',ticklabelstandoff:6};layout.barmode='overlay';layout.showlegend=false;if($('genomeRegionGuideLines')&&$('genomeRegionGuideLines').checked){layout.shapes=(layout.shapes||[]);meta.guideShapeIndex=layout.shapes.length;layout.shapes.push({type:'path',xref:'x',yref:'paper',path:genomeGuidePath(meta,meta.xRange),line:{color:'rgba(83,102,91,0.25)',width:1,dash:'dot'},layer:'below'});}else meta.guideShapeIndex=null;layout.hovermode='closest';const statusLegend=[['Upregulated',upDataColor()],['Downregulated',downDataColor()],['Not significant',nsDataColor()]],legendXs=[.12,.44,.76],arrowW=.085,arrowH=.012,head=arrowW*.25,legendY=.017;layout.shapes=(layout.shapes||[]);layout.annotations=(layout.annotations||[]);statusLegend.forEach((item,i)=>{const x0=legendXs[i]-arrowW/2,x1=legendXs[i]+arrowW/2,neck=x1-head,y0=legendY-arrowH,y1=legendY+arrowH;layout.shapes.push({type:'path',xref:'paper',yref:'paper',path:`M ${x0},${y0} L ${neck},${y0} L ${neck},${legendY-arrowH*1.75} L ${x1},${legendY} L ${neck},${legendY+arrowH*1.75} L ${neck},${y1} L ${x0},${y1} Z`,fillcolor:item[1],line:{color:'#344239',width:.8},layer:'above'});layout.annotations.push({xref:'paper',yref:'paper',x:legendXs[i],y:.001,text:item[0],showarrow:false,xanchor:'center',yanchor:'top',font:{size:11,color:graphFont().color}});});layout.title={text:$('plotTitle').value||'',x:.5,xanchor:'center',y:.992,yanchor:'top',pad:{b:0}};layout.margin={l:showAxisTitles?108:76,r:28,t:$('plotTitle').value?86:52,b:18};}}
    if(type==='Genome region'&&data.__genomeRegion){
      const meta=data.__genomeRegion,trackDomain=Array.isArray(layout.yaxis2?.domain)?layout.yaxis2.domain:[.050,.142],trackRange=Array.isArray(layout.yaxis2?.range)?layout.yaxis2.range:[-1.12,1.12],tickValues=Array.isArray(meta.strandTickVals)?meta.strandTickVals:[],tickLabels=Array.isArray(meta.strandTickText)?meta.strandTickText:[];
      // Put all vertical-track descriptors in the far-left gutter and reclaim
      // the former title/tick reserve for genomic data.  Paper-coordinate
      // annotations remain visible while panning and cannot be buried by genes.
      layout.yaxis.title={text:''};layout.yaxis2.title={text:''};layout.yaxis2.showticklabels=false;layout.annotations=layout.annotations||[];
      if(showAxisTitles)layout.annotations.push({name:'BRA_GENOME_FOLD_AXIS',xref:'paper',yref:'paper',x:-.074,y:(Number(layout.yaxis.domain?.[0]||.158)+Number(layout.yaxis.domain?.[1]||1))/2,text:$('yTitle').value||foldScaleLabel(),textangle:-90,showarrow:false,xanchor:'center',yanchor:'middle',font:{size:12,color:graphFont().color}});
      tickValues.forEach((value,index)=>{const numericValue=Number(value),fraction=(numericValue-trackRange[0])/Math.max(Number.EPSILON,trackRange[1]-trackRange[0]),paperY=trackDomain[0]+Math.max(0,Math.min(1,fraction))*(trackDomain[1]-trackDomain[0]);layout.annotations.push({name:'BRA_GENOME_STRAND_AXIS',xref:'paper',yref:'paper',x:-.014,y:paperY,text:String(tickLabels[index]??value),showarrow:false,xanchor:'right',yanchor:'middle',font:{size:11,color:graphFont().color}});});
      layout.margin.l=showAxisTitles?94:66;
    }
    if(!showAxisTitles){if(layout.xaxis&&layout.xaxis.title)layout.xaxis.title.text='';if(layout.yaxis&&layout.yaxis.title)layout.yaxis.title.text='';if(layout.yaxis2&&layout.yaxis2.title)layout.yaxis2.title.text='';}
    if(type!=='Network'&&type!=='Circos'){const styleMajorAxis=axis=>{if(!axis||axis.visible===false)return;axis.showline=true;axis.linecolor='#000000';axis.linewidth=1.15;axis.ticks='outside';axis.tickcolor='#000000';axis.tickwidth=1.15;axis.ticklen=6;axis.mirror=false;};styleMajorAxis(layout.xaxis);styleMajorAxis(layout.yaxis);if(type==='Genome region')styleMajorAxis(layout.yaxis2);}
    function wrapCategoryTick(value,width=32,maxLines=3){
      const text=String(value??'').trim();if(text.length<=width)return text;
      const words=text.split(/\s+/),lines=[];let line='';for(const word of words){const next=line?line+' '+word:word;if(next.length<=width||!line)line=next;else{lines.push(line);line=word;if(lines.length>=maxLines-1)break;}}if(line&&lines.length<maxLines)lines.push(line);const used=lines.join(' ');if(used.length<text.length&&lines.length)lines[lines.length-1]=lines[lines.length-1].replace(/[.…]*$/,'')+'…';return lines.join('<br>');
    }
    if(['enrichment','combined'].includes(moduleName)){
      const visibleCategoryRows=enrichmentPlotRows(type,false);
      for(const axisName of ['xaxis','yaxis']){const axis=layout[axisName];if(!axis||axis.type==='log')continue;const horizontalBar=type==='Bar'&&$('barOrientation').value==='h',role=horizontalBar?(axisName==='xaxis'?state.roles.y:state.roles.x):(axisName==='xaxis'?state.roles.x:state.roles.y);if(!role||columnKind(role)!=='categorical')continue;const values=unique(visibleCategoryRows.map(r=>r[role])).slice(0,24),controlledSpace=axisName==='yaxis'?(Number($('yAxisSpace')?.value)||0):(Number($('xAxisSpace')?.value)||0),wrapWidth=controlledSpace>0?Math.max(14,Math.min(76,Math.round(controlledSpace/7.5))):32,maxLines=controlledSpace>0?4:2;if(values.length){axis.tickmode='array';axis.tickvals=values;axis.ticktext=values.map(v=>wrapCategoryTick(v,wrapWidth,maxLines));axis.automargin=true;}}
    }
    if(studioHasVisibleColorbar(data,layout)){layout.margin=layout.margin||{};layout.margin.r=Math.max(175,Number(layout.margin.r)||0);}
    layout.margin=layout.margin||{};const requestedLeftSpace=Number($('yAxisSpace')?.value)||0,requestedBottomSpace=Number($('xAxisSpace')?.value)||0;if(requestedLeftSpace>0)layout.margin.l=requestedLeftSpace;if(requestedBottomSpace>0)layout.margin.b=requestedBottomSpace;const requestedRightSpace=Number($('rightAxisSpace')?.value)||0,requestedTopSpace=Number($('topAxisSpace')?.value)||0;if(requestedRightSpace>0)layout.margin.r=requestedRightSpace;if(requestedTopSpace>0)layout.margin.t=requestedTopSpace;if(requestedLeftSpace>0&&layout.yaxis)layout.yaxis.automargin=false;if(requestedBottomSpace>0&&layout.xaxis)layout.xaxis.automargin=false;
    collectPlotLinks(data);
    const plotConfig={responsive:true,displaylogo:false,displayModeBar:false,scrollZoom:type==='Circos'||!['Genome region'].includes(type),doubleClick:type==='Genome region'?false:'reset+autosize',plotGlPixelRatio:type==='Circos'?2:(PERFORMANCE_RENDERING?1:2),toImageButtonOptions:{format:'png',scale:2},editable:true,edits:{annotationPosition:type==='Volcano',annotationTail:false,annotationText:false,axisTitleText:false,colorbarPosition:true,colorbarTitleText:false,legendPosition:false,legendText:false,shapePosition:false,titleText:false}};
    Plotly.react('plot',data,layout,plotConfig).then(()=>{bindPlotSelectionEvents();prepareDraggableColorbars($('plot'));safeStudioResize();if(type==='Genome region'&&data.__genomeRegion&&Array.isArray(data.__genomeRegion.xRange)){const desired=data.__genomeRegion.xRange.map(Number),actual=$('plot')._fullLayout?.xaxis?.range;if(Array.isArray(actual)&&desired.every(Number.isFinite)&&Math.max(Math.abs(Number(actual[0])-desired[0]),Math.abs(Number(actual[1])-desired[1]))>1e-7){state.genomeRegionApplyingRange=true;Promise.resolve(Plotly.relayout('plot',{'xaxis.range':desired})).finally(()=>{state.genomeRegionApplyingRange=false;});}}restorePendingBakedSelectionView(type);requestAnimationFrame(applyCircosCamera);if(Number.isInteger(restoreSelectionRow)&&['Volcano','Scatter'].includes(type))focusPlotRows([restoreSelectionRow],{scroll:false,hover:false});});
    state.figure={data,layout};
    $('plotMessage').textContent=state.categoryPlotNotice||''; if($('paperSize')) updateExportEstimate();
  }

  function setDragMode(mode){$('dragMode').value=mode;const type=$('plotType').value;try{Plotly.relayout('plot',{dragmode:mode});}catch(_err){}if(type==='Circos'&&mode==='pan'&&$('circosFreeCamera')?.checked!==false)$('plotMessage').textContent='Circos free camera: drag anywhere to move the circle/partial arc. Use the mouse wheel or +/− to zoom.';else if(type==='Circos')$('plotMessage').textContent=mode==='zoom'?'Drag a box to zoom the Circos plotting region.':mode==='select'?'Drag a box to select genes.':'Draw a lasso to select genes.';}
  function zoomCurrentPlot(factor){
    const graph=$('plot'),type=$('plotType').value;if(!graph||!graph._fullLayout)return;
    const updates={};['xaxis','yaxis'].forEach(axis=>{if(type==='Genome region'&&axis==='yaxis')return;const range=graph._fullLayout[axis]?.range;if(!Array.isArray(range)||range.length!==2)return;const a=numeric(range[0]),b=numeric(range[1]);if(a===null||b===null)return;const c=(a+b)/2,h=Math.max(Number.EPSILON,Math.abs(b-a)*factor/2);updates[axis+'.range']=[c-h,c+h];});if(type==='Genome region'&&Array.isArray(updates['xaxis.range'])){state.genomeRegionLockedSpan=Math.max(Number.EPSILON,Math.abs(updates['xaxis.range'][1]-updates['xaxis.range'][0]));state.genomeRegionViewRange=[...updates['xaxis.range']];}if(Object.keys(updates).length)Plotly.relayout('plot',updates);
  }
  function resetPlotView(){const type=$('plotType').value,graph=$('plot');resetStudioColorbars(graph);if(type==='Circos'){state.circosAngularView=null;resetCircosCamera({apply:false});renderPlot();return;}if(type==='Genome region'){state.genomeRegionViewRange=null;state.genomeRegionRenderedRange=null;state.genomeRegionLockedSpan=null;state.genomeRegionYRange=null;renderPlot();return;}try{Plotly.relayout('plot',{'xaxis.autorange':true,'yaxis.autorange':true});}catch(_err){}}

  const CLIENT_MAX_RASTER_PIXELS=100000000;
  const CLIENT_MAX_RASTER_DIMENSION=12000;
  function safeExportStem(value){return String(value||'Bacterial RNA plot').trim().replace(/[<>:"/\\|?*\x00-\x1F]+/g,'_').replace(/[. ]+$/g,'').slice(0,140)||'Bacterial RNA plot';}
  function downloadBlob(blob,filename){const url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download=filename;document.body.appendChild(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(url),30000);}
  function dataUriBlob(uri,forcedType){const comma=uri.indexOf(',');if(comma<0)throw new Error('Invalid image data returned by Plotly.');const meta=uri.slice(5,comma),payload=uri.slice(comma+1),base64=/;base64/i.test(meta),mime=forcedType||meta.split(';')[0]||'application/octet-stream';let bytes;if(base64){const raw=atob(payload);bytes=new Uint8Array(raw.length);for(let i=0;i<raw.length;i++)bytes[i]=raw.charCodeAt(i);}else{const raw=decodeURIComponent(payload);bytes=new TextEncoder().encode(raw);}return new Blob([bytes],{type:mime});}
  function byteJoin(parts){const total=parts.reduce((sum,part)=>sum+part.length,0),out=new Uint8Array(total);let offset=0;for(const part of parts){out.set(part,offset);offset+=part.length;}return out;}
  function textBytes(value){return new TextEncoder().encode(String(value));}
  async function pdfBlobFromJpegUri(uri,pixelWidth,pixelHeight,pageWidthMm=297,pageHeightMm=210){const jpeg=new Uint8Array(await dataUriBlob(uri,'image/jpeg').arrayBuffer()),pageWidth=Math.max(72,(Number(pageWidthMm)||297)*72/25.4),pageHeight=Math.max(72,(Number(pageHeightMm)||210)*72/25.4),scale=Math.min(pageWidth/pixelWidth,pageHeight/pixelHeight),drawWidth=pixelWidth*scale,drawHeight=pixelHeight*scale,x=(pageWidth-drawWidth)/2,y=(pageHeight-drawHeight)/2,content=`q\n${drawWidth.toFixed(3)} 0 0 ${drawHeight.toFixed(3)} ${x.toFixed(3)} ${y.toFixed(3)} cm\n/Im0 Do\nQ\n`,objects=[textBytes('<< /Type /Catalog /Pages 2 0 R >>'),textBytes('<< /Type /Pages /Kids [3 0 R] /Count 1 >>'),textBytes(`<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${pageWidth.toFixed(3)} ${pageHeight.toFixed(3)}] /Resources << /XObject << /Im0 4 0 R >> >> /Contents 5 0 R >>`),byteJoin([textBytes(`<< /Type /XObject /Subtype /Image /Width ${pixelWidth} /Height ${pixelHeight} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length ${jpeg.length} >>\nstream\n`),jpeg,textBytes('\nendstream')]),textBytes(`<< /Length ${textBytes(content).length} >>\nstream\n${content}endstream`)];const header=textBytes('%PDF-1.4\n'),parts=[header],offsets=[0];let cursor=header.length;objects.forEach((body,index)=>{offsets.push(cursor);const object=byteJoin([textBytes(`${index+1} 0 obj\n`),body,textBytes('\nendobj\n')]);parts.push(object);cursor+=object.length;});const xref=cursor,rows=offsets.slice(1).map(offset=>String(offset).padStart(10,'0')+' 00000 n \n').join(''),tail=textBytes(`xref\n0 ${objects.length+1}\n0000000000 65535 f \n${rows}trailer\n<< /Size ${objects.length+1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`);parts.push(tail);return new Blob(parts,{type:'application/pdf'});}
  function plotAspect(){const graph=$('plot'),rect=graph?.getBoundingClientRect();const w=Math.max(320,Number(rect?.width)||Number(graph?._fullLayout?.width)||1200),h=Math.max(260,Number(rect?.height)||Number(graph?._fullLayout?.height)||800);return {w,h,ratio:w/h};}
  function maximumRasterSize(ratio){ratio=Math.max(.05,Math.min(20,Number(ratio)||1));let width=Math.sqrt(CLIENT_MAX_RASTER_PIXELS*ratio),height=width/ratio;const factor=Math.min(1,CLIENT_MAX_RASTER_DIMENSION/Math.max(width,height));width=Math.max(100,Math.floor(width*factor));height=Math.max(100,Math.floor(height*factor));return {width,height};}
  function rasterRenderPlan(widthPx,heightPx){const width=Math.max(100,Math.round(widthPx)),height=Math.max(100,Math.round(heightPx)),ratio=width/height;let baseWidth=Math.min(1800,width),baseHeight=Math.round(baseWidth/ratio);if(baseHeight>1600){baseHeight=Math.min(1600,height);baseWidth=Math.round(baseHeight*ratio);}const scale=Math.max(1,Math.min(width/baseWidth,height/baseHeight));return {baseWidth,baseHeight,scale,width:Math.round(baseWidth*scale),height:Math.round(baseHeight*scale)};}
  function requestedClientPixels(widthMm,heightMm,dpi){const width=Math.round(widthMm/25.4*dpi),height=Math.round(heightMm/25.4*dpi);if(width>CLIENT_MAX_RASTER_DIMENSION||height>CLIENT_MAX_RASTER_DIMENSION||width*height>CLIENT_MAX_RASTER_PIXELS){const max=maximumRasterSize(widthMm/heightMm);throw new Error(`Requested raster size ${width.toLocaleString()} × ${height.toLocaleString()} px exceeds the browser-safe maximum. Use Maximum safe resolution (${max.width.toLocaleString()} × ${max.height.toLocaleString()} px) or export SVG for unlimited enlargement.`);}return {width,height};}
  async function imageFromUri(uri){return await new Promise((resolve,reject)=>{const image=new Image();image.onload=()=>resolve(image);image.onerror=()=>reject(new Error('Could not decode the high-resolution plot image.'));image.src=uri;});}
  async function canvasBlobFromPngUri(uri,format){const image=await imageFromUri(uri),canvas=document.createElement('canvas');canvas.width=image.naturalWidth;canvas.height=image.naturalHeight;const ctx=canvas.getContext('2d',{alpha:format!=='jpeg'});if(!ctx)throw new Error('Browser could not allocate the high-resolution export canvas. Use SVG for unlimited enlargement.');if(format==='jpeg'){ctx.fillStyle='#ffffff';ctx.fillRect(0,0,canvas.width,canvas.height);}ctx.drawImage(image,0,0);const mime=format==='jpeg'?'image/jpeg':'image/webp';return await new Promise((resolve,reject)=>canvas.toBlob(blob=>blob?resolve(blob):reject(new Error(`${format.toUpperCase()} export is not supported by this browser.`)),mime,1.0));}
  function tiffBlobFromImageData(imageData,width,height,dpi){const pixelBytes=width*height*3,entryCount=13,ifdOffset=8,ifdBytes=2+entryCount*12+4;let cursor=ifdOffset+ifdBytes;const bitsOffset=cursor;cursor+=6;if(cursor%2)cursor++;const xResOffset=cursor;cursor+=8;const yResOffset=cursor;cursor+=8;const pixelsOffset=cursor;const buffer=new ArrayBuffer(pixelsOffset+pixelBytes),view=new DataView(buffer);view.setUint8(0,0x49);view.setUint8(1,0x49);view.setUint16(2,42,true);view.setUint32(4,ifdOffset,true);view.setUint16(ifdOffset,entryCount,true);let pos=ifdOffset+2;const entry=(tag,type,count,value)=>{view.setUint16(pos,tag,true);view.setUint16(pos+2,type,true);view.setUint32(pos+4,count,true);if(type===3&&count===1){view.setUint16(pos+8,value,true);view.setUint16(pos+10,0,true);}else view.setUint32(pos+8,value,true);pos+=12;};entry(256,4,1,width);entry(257,4,1,height);entry(258,3,3,bitsOffset);entry(259,3,1,1);entry(262,3,1,2);entry(273,4,1,pixelsOffset);entry(277,3,1,3);entry(278,4,1,height);entry(279,4,1,pixelBytes);entry(282,5,1,xResOffset);entry(283,5,1,yResOffset);entry(284,3,1,1);entry(296,3,1,2);view.setUint32(pos,0,true);view.setUint16(bitsOffset,8,true);view.setUint16(bitsOffset+2,8,true);view.setUint16(bitsOffset+4,8,true);const resolution=Math.max(72,Math.min(2400,Math.round(Number(dpi)||600)));view.setUint32(xResOffset,resolution,true);view.setUint32(xResOffset+4,1,true);view.setUint32(yResOffset,resolution,true);view.setUint32(yResOffset+4,1,true);const source=imageData.data,target=new Uint8Array(buffer,pixelsOffset,pixelBytes);for(let src=0,dst=0;src<source.length;src+=4){target[dst++]=source[src];target[dst++]=source[src+1];target[dst++]=source[src+2];}return new Blob([buffer],{type:'image/tiff'});}
  async function tiffBlobFromPngUri(uri,dpi){const image=await imageFromUri(uri),canvas=document.createElement('canvas');canvas.width=image.naturalWidth;canvas.height=image.naturalHeight;const ctx=canvas.getContext('2d',{alpha:false,willReadFrequently:true});if(!ctx)throw new Error('Browser could not allocate the high-resolution TIFF canvas. Use SVG for unlimited enlargement.');ctx.fillStyle='#ffffff';ctx.fillRect(0,0,canvas.width,canvas.height);ctx.drawImage(image,0,0);const imageData=ctx.getImageData(0,0,canvas.width,canvas.height);return tiffBlobFromImageData(imageData,canvas.width,canvas.height,dpi);}
  async function vectorSafePlotImage(format,width,height){
    const data=Array.isArray(state.figure?.data)?state.figure.data:[],hasWebGL=data.some(trace=>String(trace?.type||'').toLowerCase()==='scattergl');
    if(!hasWebGL)return await Plotly.toImage('plot',{format,width,height,scale:1});
    // WebGL is ideal for interaction but Plotly may rasterize scattergl layers in
    // SVG/PDF.  Publication vector export therefore rerenders the same data once
    // as SVG scatter off-screen without changing the interactive canvas.
    const holder=document.createElement('div');holder.style.cssText=`position:fixed;left:-20000px;top:0;width:${width}px;height:${height}px;background:#fff;`;document.body.appendChild(holder);
    try{const exportData=data.map(trace=>String(trace?.type||'').toLowerCase()==='scattergl'?{...trace,type:'scatter'}:{...trace});const exportLayout={...(state.figure?.layout||{}),width,height,autosize:false};await Plotly.newPlot(holder,exportData,exportLayout,{staticPlot:true,displayModeBar:false,responsive:false});return await Plotly.toImage(holder,{format,width,height,scale:1});}finally{try{Plotly.purge(holder);}catch(_err){}holder.remove();}
  }
  async function clientExportCurrentPlot(format,filename,{widthPx=null,heightPx=null,dpi=600,pageWidthMm=297,pageHeightMm=210}={}){if(!state.figure)throw new Error('Create a plot before exporting.');format=String(format||'png').toLowerCase();if(format==='jpg')format='jpeg';const stem=safeExportStem(filename||`${$('plotType').value} plot`);if(format==='svg'){const aspect=plotAspect(),baseWidth=2400,baseHeight=Math.max(500,Math.round(baseWidth/aspect.ratio)),uri=await vectorSafePlotImage('svg',baseWidth,baseHeight);downloadBlob(dataUriBlob(uri,'image/svg+xml'),stem+'.svg');return `SVG vector export completed. It can be enlarged without pixelation.`;}if(format==='html'){const blob=new Blob(['<!doctype html>\n'+document.documentElement.outerHTML],{type:'text/html;charset=utf-8'});downloadBlob(blob,stem+'.html');return 'Interactive HTML snapshot downloaded.';}const aspect=plotAspect(),max=maximumRasterSize(aspect.ratio),requested=(widthPx&&heightPx)?{width:Math.round(widthPx),height:Math.round(heightPx)}:max;if(requested.width>CLIENT_MAX_RASTER_DIMENSION||requested.height>CLIENT_MAX_RASTER_DIMENSION||requested.width*requested.height>CLIENT_MAX_RASTER_PIXELS)throw new Error('Requested raster export exceeds the browser-safe maximum. Use SVG for unlimited enlargement.');const plan=rasterRenderPlan(requested.width,requested.height);if(format==='pdf'){const jpegUri=await Plotly.toImage('plot',{format:'jpeg',width:plan.baseWidth,height:plan.baseHeight,scale:plan.scale}),blob=await pdfBlobFromJpegUri(jpegUri,plan.width,plan.height,pageWidthMm,pageHeightMm);downloadBlob(blob,stem+'.pdf');return `PDF export completed on a ${Number(pageWidthMm).toFixed(1)} × ${Number(pageHeightMm).toFixed(1)} mm page.`;}const pngUri=await Plotly.toImage('plot',{format:'png',width:plan.baseWidth,height:plan.baseHeight,scale:plan.scale});let blob,ext=format;if(format==='png')blob=dataUriBlob(pngUri,'image/png');else if(format==='jpeg'||format==='webp')blob=await canvasBlobFromPngUri(pngUri,format);else if(format==='tiff'){blob=await tiffBlobFromPngUri(pngUri,dpi);ext='tif';}else throw new Error('Unsupported export format.');downloadBlob(blob,stem+'.'+(format==='jpeg'?'jpg':ext));return `${format.toUpperCase()} export completed at approximately ${plan.width.toLocaleString()} × ${plan.height.toLocaleString()} pixels${format==='tiff'?` with ${Math.round(dpi)} DPI metadata`:''}.`;}
  function downloadCurrentPlot(){const panel=$('publicationExportPanel');if(!panel)return;if(panel.classList.contains('export-modal-open')){closePublicationExport();return;}panel.classList.remove('export-hidden');panel.classList.add('export-modal-open');panel.setAttribute('role','dialog');const name=$('exportName');if(name&&!name.dataset.userEdited)name.value=specializedActive()?'Bacterial RNA specialized analyses':`Bacterial RNA ${$('plotType').value}`;}
  function closePublicationExport(){const panel=$('publicationExportPanel');if(!panel)return;panel.classList.add('export-hidden');panel.classList.remove('export-modal-open');}
  document.addEventListener('keydown',e=>{if(e.key==='Escape')closePublicationExport();});

  function renderVariables(filter='') {
    const q=filter.trim().toLowerCase();
    $('variableList').innerHTML=state.columns.filter(c=>!q||c.name.toLowerCase().includes(q)).map(c=>`<div class="variable" draggable="true" data-name="${esc(c.name)}"><span>${esc(c.name)}</span><small>${esc(c.kind)}</small></div>`).join('');
    document.querySelectorAll('.variable').forEach(el=>{
      el.addEventListener('dragstart',e=>{e.dataTransfer.setData('text/plain',el.dataset.name);});
      el.addEventListener('click',()=>{document.querySelectorAll('.variable').forEach(x=>x.classList.remove('selected'));el.classList.add('selected');state.selectedVariable=el.dataset.name;});
    });
  }
  function renderModuleRenameControls(){
    const panel=$('moduleRenameControls'),list=$('moduleRenameList');if(!panel||!list)return;
    if(!['network','combined'].includes(moduleName)){panel.hidden=true;list.replaceChildren();return;}
    const values=[];const addRows=(rows,columns)=>{const moduleColumns=(columns||[]).map(column=>typeof column==='string'?column:column?.name).filter(isModuleColumnName);for(const row of (rows||[])){for(const column of moduleColumns){const value=row?.[column];if(value!==null&&value!==undefined&&String(value).trim()&&!values.some(existing=>String(existing)===String(value)))values.push(value);if(values.length>=60)return;}}};
    addRows(state.rows,state.columns);const store=window.__OFFLINE_STUDIO_DATA__;if(store?.tables){for(const table of Object.values(store.tables)){addRows(table?.rows,table?.columns);if(values.length>=60)break;}}
    panel.hidden=!values.length;
    list.innerHTML=values.map(value=>{const raw=String(value),name=state.moduleNames.get(raw)||raw;return `<label class="module-rename-row"><span title="${esc(raw)}">${esc(raw)}</span><input type="text" data-module-original="${esc(raw)}" value="${esc(name)}" aria-label="Display name for ${esc(raw)}"></label>`;}).join('');
    list.querySelectorAll('input[data-module-original]').forEach(input=>input.addEventListener('input',()=>{const raw=input.dataset.moduleOriginal||'',name=input.value.trim();if(name&&name!==raw)state.moduleNames.set(raw,name);else state.moduleNames.delete(raw);if(specializedActive())sendSpecializedAppearance();else renderPlot();renderLinkedSpreadsheet();}));
  }
  async function loadTable() {
    const key=$('tableSelect').value, limit=$('rowLimit').value; $('dataSummary').textContent='Loading data…';
    let data=null;
    const offlineStore=window.__OFFLINE_STUDIO_DATA__;
    if(offlineStore&&offlineStore.tables&&offlineStore.tables[key]){
      const source=offlineStore.tables[key], requested=Math.max(1,Number(limit||10000));
      const rows=source.rows.slice(0,requested);
      data={...source,rows,truncated:Boolean(source.truncated||rows.length<source.rows.length)};
    } else {
      const res=await fetch(`/api/table?key=${encodeURIComponent(key)}&limit=${encodeURIComponent(limit)}`); data=await res.json();
      if(!res.ok)throw new Error(data.error||'Could not load table');
    }
    state.table=data;state.rows=data.rows;state.columns=data.columns;state.memberSelection=null;state.memberReturnTerm='';state.rowSubset=null;state.sheetColumnOrder=data.columns.map(c=>c.name);state.rowIndex=new WeakMap();state.rows.forEach((row,index)=>state.rowIndex.set(row,index));state.selectedRows=new Set();state.activeRow=null;state.sheetPage=0;state.sheetSort=null;state.sheetSortDirection=1;state.contigSelections={Histogram:new Set(),Circos:new Set(),'Genome region':new Set()};state.contigSelectionInitialized={Histogram:false,Circos:false,'Genome region':false};state.histogramContigColors=new Map();state.genomeRegionViewRange=null;state.genomeRegionRenderedRange=null;state.genomeRegionViewKey='';state.genomeRegionLockedSpan=null;state.genomeRegionYRange=null;state.circosAngularView=null;resetCircosCamera({apply:false});$('sheetSearch').value='';
    renderVariables();renderModuleRenameControls();clearRoles();autoAssign();updateContigSelectors();$('dataSummary').textContent=`${data.rows.length.toLocaleString()} rows loaded${data.truncated?' (limited for browser performance)':''}.`;$('sheetSource').textContent='';renderLinkedSpreadsheet();renderDataSample();
  }
  function renderDataSample(){const rows=state.rows.slice(0,100),cols=state.columns.map(c=>c.name);$('dataTable').innerHTML=`<thead><tr>${cols.map(c=>`<th>${esc(c)}</th>`).join('')}</tr></thead><tbody>${rows.map(r=>`<tr>${cols.map(c=>`<td>${esc(r[c])}</td>`).join('')}</tr>`).join('')}</tbody>`;}

  function paperDimensions(){let size=$('paperSize').value, dims=size==='Custom'?[Number($('widthMm').value),Number($('heightMm').value)]:paper[size];if($('paperOrientation').value==='landscape'&&dims[0]<dims[1])dims=[dims[1],dims[0]];if($('paperOrientation').value==='portrait'&&dims[0]>dims[1])dims=[dims[1],dims[0]];return dims;}
  function chosenDpi(){const mode=$('dpiMode').value;if(mode==='custom')return Number($('customDpi').value);if(mode==='maximum')return null;return Number(mode);}
  function maxSafeDpi(wmm,hmm){const win=wmm/25.4,hin=hmm/25.4;return Math.max(72,Math.min(2400,Math.floor(MAXDIM()/Math.max(win,hin)),Math.floor(Math.sqrt(160000000/(win*hin)))));}
  function MAXDIM(){return 32000;}
  function updatePaperInputs(){const custom=$('paperSize').value==='Custom';$('widthMm').disabled=!custom;$('heightMm').disabled=!custom;if(!custom){let d=paper[$('paperSize').value];$('widthMm').value=d[0];$('heightMm').value=d[1];}updateExportEstimate();}
  function updateExportEstimate(){const format=$('exportFormat')?.value||'tiff';if(format==='svg'){$('pixelEstimate').textContent='Vector · resolution-independent · unlimited enlargement';return;}if(format==='html'){$('pixelEstimate').textContent='Interactive HTML · resolution-independent';return;}const [w,h]=paperDimensions();let dpi=chosenDpi()||maxSafeDpi(w,h),pxw=Math.round(w/25.4*dpi),pxh=Math.round(h/25.4*dpi);if(window.__OFFLINE_STUDIO_DATA__&&$('dpiMode').value==='maximum'){const max=maximumRasterSize(w/h);pxw=max.width;pxh=max.height;dpi=Math.floor(Math.min(pxw/(w/25.4),pxh/(h/25.4)));}$('pixelEstimate').textContent=format==='pdf'?`${w.toFixed(1)} × ${h.toFixed(1)} mm PDF · embedded ${pxw.toLocaleString()} × ${pxh.toLocaleString()} px plot`:`${w.toFixed(1)} × ${h.toFixed(1)} mm · ${dpi} DPI equivalent · ${pxw.toLocaleString()} × ${pxh.toLocaleString()} px`;}

  async function exportPlot(){const btn=$('exportButton'),format=$('exportFormat').value;if(specializedActive()){if(format==='html'){$('exportStatus').textContent='Interactive HTML is the report currently open; choose PDF, SVG, TIFF, PNG, JPEG, or WebP for an exported plot.';return;}btn.disabled=true;try{const [w,h]=paperDimensions();sendSpecializedCommand('export',{format,pageWidthMm:w,pageHeightMm:h,dpi:chosenDpi()||maxSafeDpi(w,h)});$('exportStatus').textContent=`Started ${format.toUpperCase()} export for ${currentSpecializedFrames().length} selected analysis plot${currentSpecializedFrames().length===1?'':'s'}.`;}finally{btn.disabled=false;}return;}if(!state.figure){$('exportStatus').textContent='Create a plot before exporting.';return;}btn.disabled=true;try{const [w,h]=paperDimensions(),offline=Boolean(window.__OFFLINE_STUDIO_DATA__),requestedDpi=chosenDpi(),dpi=requestedDpi||maxSafeDpi(w,h);if(offline){$('exportStatus').textContent=format==='svg'?'Preparing vector SVG…':format==='pdf'?'Rendering PDF…':'Rendering maximum-quality image…';let widthPx=null,heightPx=null;if(!['svg','html'].includes(format)){if($('dpiMode').value==='maximum'){const max=maximumRasterSize(w/h);widthPx=max.width;heightPx=max.height;}else{const requested=requestedClientPixels(w,h,dpi);widthPx=requested.width;heightPx=requested.height;}}const summary=await clientExportCurrentPlot(format,$('exportName').value,{widthPx,heightPx,dpi,pageWidthMm:w,pageHeightMm:h});$('exportStatus').textContent=summary;return;}$('exportStatus').textContent='Preparing vector snapshot…';const ratio=w/h,svgWidth=2400,svgHeight=Math.max(500,Math.round(svgWidth/ratio)),uri=await vectorSafePlotImage('svg',svgWidth,svgHeight);const comma=uri.indexOf(','),svg=/;base64/i.test(uri.slice(0,comma))?atob(uri.slice(comma+1)):decodeURIComponent(uri.slice(comma+1));const payload={figure:state.figure,svg,format,paper_size:$('paperSize').value,orientation:$('paperOrientation').value,width_mm:w,height_mm:h,dpi_mode:$('dpiMode').value,dpi:requestedDpi,filename:$('exportName').value};$('exportStatus').textContent='Rendering publication-quality file…';const res=await fetch('/api/export',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)});const out=await res.json();if(!res.ok)throw new Error(out.error||'Export failed');$('exportStatus').innerHTML=`Saved: <strong>${esc(out.path)}</strong><br>${esc(out.summary)}`;const a=document.createElement('a');a.href=out.download_url;a.download=out.filename;document.body.appendChild(a);a.click();a.remove();}catch(err){$('exportStatus').textContent='Export failed: '+err.message;}finally{btn.disabled=false;}}

  const GENERIC_ANALYSIS_PREFIX='__generic__:';
  function genericAnalysisPlotType(value){const raw=String(value||'');if(raw==='__generic__')return $('plotType')?.value||'';if(!raw.startsWith(GENERIC_ANALYSIS_PREFIX))return '';try{return decodeURIComponent(raw.slice(GENERIC_ANALYSIS_PREFIX.length));}catch(_err){return raw.slice(GENERIC_ANALYSIS_PREFIX.length);}}
  function genericAnalysisValue(value){return Boolean(genericAnalysisPlotType(value));}
  function selectedAnalysisValues(){const select=$('analysisSelect');if(select)return select.value?[select.value]:[];const fallback=GENERIC_ANALYSIS_PREFIX+encodeURIComponent($('plotType')?.value||'Scatter');return [fallback];}
  function currentSpecializedFrames(){const stack=$('specializedPlotStack');return stack?[...stack.querySelectorAll('iframe.specialized-plot-frame')]:[];}
  function currentSpecializedFrame(){const wanted=$('analysisSelect')?.value||'';return currentSpecializedFrames().find(frame=>frame.dataset.src===wanted)||currentSpecializedFrames()[0]||null;}
  function hasSpecializedWorkspace(){return ['de','enrichment','network','combined'].includes(moduleName);}
  function specializedActive(){return hasSpecializedWorkspace()&&selectedAnalysisValues().some(value=>Boolean(value)&&!genericAnalysisValue(value));}
  function fallbackSpecializedCapabilities(filename=specializedFilename()){
    const value=String(filename||'').toLowerCase(),structural=/(?:circos|network|venn|cellular_component)/.test(value),gradientBlocked=/(?:ma_interactive|pca_interactive|sample_pca_3d|sample_expression_distributions|sample_dendrogram|source_of_variation|de_pvalue_histogram|single_gene_expression)/.test(value);
    return {selectionInfo:/(?:single_gene_expression|de_gene_rank|ma_interactive)/.test(value),labels:/de_gene_rank/.test(value)||!/(?:histogram|single_gene_expression|sample_expression_distributions)/.test(value),gridlines:!structural,axisTitles:!/circos/.test(value),xTitle:'',yTitle:'',gradientPalette:!gradientBlocked};
  }
  function updateSpecializedCapabilityControls(){
    if(!specializedActive())return;
    const frames=currentSpecializedFrames(),reported=frames.map(frame=>frame.__braCapabilities).filter(value=>value&&typeof value==='object'),fallback=fallbackSpecializedCapabilities(),capability=key=>reported.length?reported.some(value=>value[key]===true):fallback[key]===true;
    if($('selectionInfoControls'))$('selectionInfoControls').hidden=!capability('selectionInfo');
    if($('specializedLabelControl'))$('specializedLabelControl').hidden=!capability('labels');
    if($('specializedGridControl'))$('specializedGridControl').hidden=!capability('gridlines');
    if($('axisTitleInputs'))$('axisTitleInputs').hidden=!capability('axisTitles');
    if($('axisTitleToggle'))$('axisTitleToggle').hidden=!capability('axisTitles');
    if($('specializedColorScaleControl'))$('specializedColorScaleControl').hidden=!capability('gradientPalette');
    const active=currentSpecializedFrame(),activeCapabilities=active?.__braCapabilities,source=active?.dataset?.src||specializedFilename();if(capability('axisTitles')&&activeCapabilities&&$('axisTitleInputs')?.dataset?.specializedSource!==source){$('xTitle').value=String(activeCapabilities.xTitle||'');$('yTitle').value=String(activeCapabilities.yTitle||'');$('axisTitleInputs').dataset.specializedSource=source;}
    const formats=activeCapabilities?.exportFormats,exportSelect=$('exportFormat');if(exportSelect){for(const option of exportSelect.options){option.disabled=Array.isArray(formats)&&!formats.includes(option.value)&&option.value!=='html';option.hidden=option.disabled;}if(exportSelect.selectedOptions[0]?.disabled)exportSelect.value='svg';}
    const nativeMap=/kegg[_ ]pathway[_ ]maps/.test(source),exportNote=$('publicationExportPanel')?.querySelector('.export-title p');if(exportNote){if(!exportNote.dataset.original)exportNote.dataset.original=exportNote.textContent;exportNote.textContent=nativeMap?'SVG retains vector overlays and labels over the original KEGG raster image. PNG, JPEG and WebP export the full map at the selected DPI, up to four times its native size.':exportNote.dataset.original;}
  }
  function rebuildSpecializedFrames(){
    const stack=$('specializedPlotStack');if(!stack)return;
    const selected=selectedAnalysisValues().filter(value=>!genericAnalysisValue(value)),signature=selected.join('|');if(stack.dataset.selection===signature)return;
    for(const oldFrame of currentSpecializedFrames()){try{const oldPlot=oldFrame.contentDocument?.querySelector('.js-plotly-plot'),oldPlotly=oldFrame.contentWindow?.Plotly;if(oldPlot&&oldPlotly)oldPlotly.purge(oldPlot);}catch(_err){}}
    stack.replaceChildren();stack.dataset.selection=signature;
    for(const href of selected){const option=[...($('analysisSelect')?.options||[])].find(item=>item.value===href),label=option?.textContent||'Specialized analysis',card=document.createElement('section'),heading=document.createElement('div'),frame=document.createElement('iframe');card.className='specialized-frame-card';heading.className='specialized-frame-title';heading.textContent=label;frame.className='specialized-plot-frame';frame.title=label;frame.dataset.src=href;frame.addEventListener('load',()=>{setTimeout(()=>{sendSpecializedView();sendSpecializedAppearance();sendSpecializedCommand($('dragMode')?.value||'pan');if(moduleName==='de'&&state.selectedRows?.size)postDEGenesToSpecialized([...state.selectedRows]);},60);});frame.src=href;card.append(heading,frame);stack.append(card);}
    stack.style.gridTemplateColumns='minmax(0,1fr)';
    stack.style.gridTemplateRows='minmax(0,1fr)';
    updateSpecializedCapabilityControls();
  }
  const SPECIALIZED_VIEWS={
    'go_dag_interactive.html':[
      ['dag_BP','GO focus DAG · Biological Process'],['dag_MF','GO focus DAG · Molecular Function'],['dag_CC','GO focus DAG · Cellular Component'],['context','Ontology context by level']
    ],
    'go_annotation_landscape_interactive.html':[
      ['gene_length','GO annotations by bacterial gene length'],['categories','GO category composition · BP / MF / CC']
    ]
  };
  const SPECIALIZED_GUIDES={
    'kegg_pathway_maps_interactive.html':{shows:'Your DE log2 fold changes at their original positions on the KEGG pathway diagram. Each coloured slice is one measured gene; contrasts can be switched within the map.',learn:'Select a node to inspect its genes and functions in the linked spreadsheet. Check the mapping audit for unmatched IDs. Colour reflects expression change, not pathway flux or an enrichment p-value.'},
    'go_dag_interactive.html':{shows:'GO ontology relationships around enriched terms, or the distribution of mapped annotations across ontology levels.',learn:'Use the focus DAG to see how enriched terms share ancestors. Use ontology context to judge whether the reported signal is concentrated at broad or specific GO levels.'},
    'go_annotation_landscape_interactive.html':{shows:'How GO annotations relate to bacterial gene length and how annotations are distributed among broad BP, MF and CC categories.',learn:'Use gene length to check annotation bias and category composition to see which broad functional classes dominate the mapped genes.'},
    'go_semantic_similarity_interactive.html':{shows:'Pairwise Lin semantic similarity among GO terms, ordered by semantic clusters.',learn:'Large high-similarity blocks indicate functionally related or redundant GO terms. Separate blocks indicate distinct functional themes.'},
    'go_cellular_component_interactive.html':{shows:'A bacterial localization summary of proteins/genes assigned to GO Cellular Component categories.',learn:'Use it to identify where regulated functions are localized. Click a component to inspect its members, or drag a label to reposition it while its leader remains anchored to the correct structure.'},
    'enrichment_rich_factor_interactive.html':{shows:'RichFactor for enriched terms, with point size and significance providing complementary context.',learn:'Larger RichFactor means a larger fraction of the annotated background for that term is represented among the selected genes; interpret it together with significance and gene count.'},
    'enrichment_circos_interactive.html':{shows:'A circular summary connecting enriched terms with gene counts, regulation direction, significance and RichFactor.',learn:'Use the concentric tracks to compare several enrichment statistics at once, then click a sector to inspect the contributing genes/proteins.'},
    'enrichment_bar_interactive.html':{shows:'The strongest enriched terms ranked by statistical evidence.',learn:'Longer bars indicate stronger enrichment evidence. Click a bar to inspect the genes/proteins responsible for that term.'},
    'enrichment_dot_interactive.html':{shows:'Enriched terms as points combining enrichment magnitude, significance and gene-set size.',learn:'Look for terms that are both strongly enriched and statistically supported, then inspect their member genes/proteins.'},
    'enrichment_network_interactive.html':{shows:'A term-overlap network in which related enriched terms are connected by shared genes.',learn:'Clusters of connected terms represent related biological themes; isolated terms are more distinct. Click a term to inspect shared/member genes.'},
    'gene_term_network_interactive.html':{shows:'Direct connections between enriched GO/pathway terms and their member genes/proteins.',learn:'Use this graph to identify genes that connect several enriched functions and to trace a term back to its contributing genes.'},
    'gene_network_interactive.html':{shows:'The co-expression or inferred regulatory network using the plotted network-edge result table.',learn:'Use connected groups and high-degree nodes to identify candidate modules and hubs; an edge is an association or prediction, not proof of regulation.'},
    'pathway_enrichment_bar_interactive.html':{shows:'Online KEGG pathway enrichment calculated from the same selected genes and tested-gene universe as the GO analysis.',learn:'Longer bars indicate stronger pathway enrichment evidence. Click a pathway to reveal its member genes in the shared spreadsheet.'},
    'pathway_enrichment_dot_interactive.html':{shows:'Online KEGG pathways combining enrichment magnitude, significance and gene count.',learn:'Prioritize pathways that are strongly enriched, statistically supported and represented by several genes.'},
    'pathway_enrichment_network_interactive.html':{shows:'KEGG pathways connected when they share selected genes.',learn:'Clusters summarize related pathway responses; click a pathway node to inspect its contributing genes.'},
    'pathway_gene_term_network_interactive.html':{shows:'Direct links between selected genes and enriched KEGG pathways.',learn:'Use the graph to identify genes shared by several pathways and pathways driven by the same response genes.'},
    'string_ppi_gene_network_interactive.html':{shows:'STRING protein associations for identifiers resolved in the selected organism, overlaid with available co-expression evidence.',learn:'Use high-connectivity proteins and edges supported by both sources as candidates for follow-up; association does not prove direct regulation.'},
    'module_trait_interactive.html':{shows:'Correlations between automatically detected co-expression modules and sample traits.',learn:'Prioritize module–trait pairs with strong absolute correlations, then inspect biological consistency and sample size before interpreting them.'},
    'module_expression_heatmap_interactive.html':{shows:'Standardized expression of genes grouped by their automatically detected co-expression modules.',learn:'Look for modules with coherent sample patterns and compare those patterns with functional-enrichment labels and experimental conditions.'},
    'module_expression_trends_interactive.html':{shows:'Module-level expression trends across samples or ordered experimental groups.',learn:'Use the trends to compare when modules rise or fall and to identify modules whose behavior matches the biological design.'},
    'gsea_term_profiles_interactive.html':{shows:'Running enrichment score profiles for selected ranked gene sets.',learn:'The ES peak shows where a gene set is concentrated in the ranked list; leading-edge genes drive that enrichment.'},
    'gsea_multi_term_running_score_interactive.html':{shows:'Running enrichment-score curves for several gene sets on the same ranked list.',learn:'Compare the direction and location of enrichment peaks to see which biological programs shift together.'},
    'gsea_global_es_interactive.html':{shows:'The distribution of enrichment scores across all tested gene sets.',learn:'Use the distribution to see whether enrichment is globally biased toward one side of the ranked list and where the strongest gene sets lie.'},
    'gsea_nes_significance_interactive.html':{shows:'Normalized enrichment score (NES) against nominal significance and FDR.',learn:'Prioritize gene sets with large absolute NES and strong statistical support; NES allows comparison across differently sized gene sets.'},
    'ma_interactive.html':{shows:'Log fold change against mean expression for every tested gene.',learn:'Check whether effect sizes depend on abundance and whether low-expression genes dominate apparent extremes.'},
    'pca_interactive.html':{shows:'The two leading axes of variation among samples.',learn:'Look for condition separation, batch structure and sample outliers before interpreting differential expression.'},
    'sample_expression_distributions_interactive.html':{shows:'Per-sample normalized expression distributions, with a batch-adjusted view when a batch was modeled. Color identifies experimental condition, so replicates from the same condition always share one color.',learn:'Compare distributions within and between the condition colors. Strongly different medians, spreads or tails can reveal library or normalization problems that merit investigation.'},
    'sample_correlation_interactive.html':{shows:'Pairwise sample correlations after normalization and, when available, after visualization-only batch adjustment.',learn:'Replicates should generally be more similar to one another than to unrelated conditions. Unexpected blocks can indicate batch effects or mislabeled samples.'},
    'sample_dendrogram_interactive.html':{shows:'Average-linkage hierarchical clustering of samples using correlation distance.',learn:'Check whether replicates cluster together and whether clusters follow the intended biological design.'},
    'sample_pca_3d_interactive.html':{shows:'Interactive PC1–PC3 sample structure before and, when available, after visualization-only batch adjustment.',learn:'Rotate the plot to inspect separation that may be hidden in two dimensions; do not infer significance from visual distance alone.'},
    'source_of_variation_interactive.html':{shows:'The distribution of per-gene variance explained by repeated metadata factors.',learn:'Large median η² identifies factors that structure expression broadly. Compare before/after batch adjustment to confirm that the nominated batch is reduced while condition is preserved.'},
    'de_pvalue_histogram_interactive.html':{shows:'Raw p-value counts for each contrast.',learn:'A near-uniform background with enrichment near zero is expected when some genes truly change. Severe global distortion can indicate model or design problems.'},
    'de_gene_rank_interactive.html':{shows:'Every tested gene ordered by its signed test statistic.',learn:'Inspect the continuous evidence used for ranking rather than relying only on a binary significance cutoff.'},
    'top_variable_genes_heatmap_interactive.html':{shows:'Standardized expression of the most variable genes across samples.',learn:'Look for coherent sample blocks, outliers and groups of genes sharing condition-dependent patterns.'},
    'single_gene_expression_interactive.html':{shows:'Sample-level normalized expression for the gene selected in the linked spreadsheet, grouped by condition.',learn:'Select any gene row in the spreadsheet to inspect its replicate spread and outliers here.'},
    'de_upset_interactive.html':{shows:'Exclusive overlaps among significant-gene sets from multiple treatment-versus-control contrasts.',learn:'Large intersections identify shared responses; single-contrast intersections identify condition-specific responses. Click a bar or dot to inspect the genes.'},
    'de_venn_interactive.html':{shows:'Exclusive and shared significant-gene regions for two or three treatment-versus-control contrasts.',learn:'Use the Venn view for an intuitive small-set comparison and the UpSet view for precise or larger multi-contrast comparisons. Click a count to inspect its genes.'},
    'fold_change_comparison_interactive.html':{shows:'Pairwise comparison of log2 fold changes across contrasts.',learn:'Points near the diagonal are concordant. Opposite-sign quadrants identify genes whose response reverses between treatments.'},
    'expression_trend_clusters_interactive.html':{shows:'Fuzzy clusters of standardized condition-mean expression profiles.',learn:'Centroids summarize response patterns; faint lines show strong member genes. Membership below 0.5 is flagged as ambiguous in Excel, and clustering is exploratory rather than a significance test.'}
  };
  function specializedFilename(){const raw=decodeURIComponent(($('analysisSelect')?.value||'').split('/').pop()||'');return raw.replace(/ /g,'_');}
  function specializedGuide(){
    const key=specializedFilename(),guide=SPECIALIZED_GUIDES[key]||{shows:'A specialized analysis generated from the finalized GO/KEGG result data.',learn:'Use the interactive marks and linked spreadsheet together to inspect the biological genes/proteins behind the pattern.'};
    const node=$('plotGuide');if(node)node.innerHTML=`<p><strong>What it shows</strong><span>${esc(guide.shows)}</span></p><p><strong>What to learn</strong><span>${esc(guide.learn)}</span></p>`;
  }
  function sendSpecializedCommand(command,extra={}){currentSpecializedFrames().forEach(frame=>{if(frame.contentWindow)frame.contentWindow.postMessage({type:'bra-specialized-command',command,...extra},'*');});}
  function sendSpecializedView(){const frame=currentSpecializedFrame(),select=$('specializedViewSelect');if(frame&&!frame.hidden&&frame.contentWindow&&select&&!$('specializedViewSection').hidden)frame.contentWindow.postMessage({type:'bra-specialized-view',view:select.value},'*');}
  function configureSpecializedView(){
    const section=$('specializedViewSection'),select=$('specializedViewSelect'),checklist=$('specializedViewChecklist'),hint=$('specializedViewHint');if(!section||!select||!checklist)return;
    const views=SPECIALIZED_VIEWS[specializedFilename()]||[];section.hidden=!specializedActive()||!views.length;
    if(views.length){const previous=views.some(v=>v[0]===select.value)?select.value:views[0][0];select.innerHTML=views.map(v=>`<option value="${esc(v[0])}">${esc(v[1])}</option>`).join('');select.value=previous;checklist.innerHTML=views.map(v=>`<label class="analysis-check-item"><input class="specialized-view-check" type="checkbox" value="${esc(v[0])}" ${v[0]===previous?'checked':''}><span>${esc(v[1])}</span></label>`).join('');checklist.querySelectorAll('.specialized-view-check').forEach(box=>box.addEventListener('change',()=>{if(box.checked)checklist.querySelectorAll('.specialized-view-check').forEach(other=>{if(other!==box)other.checked=false;});else box.checked=true;select.value=box.value;sendSpecializedView();setTimeout(sendSpecializedAppearance,40);}));hint.textContent=specializedFilename()==='go_dag_interactive.html'?'Tick one ontology focus DAG or the ontology-level context view. The plot canvas can scroll internally when the DAG is wider than the visible region.':'Tick the gene-length view or the broad GO category composition view.';}
    else checklist.replaceChildren();
    const appearance=$('appearanceSectionSummary');if(appearance)appearance.textContent=(!section.hidden)?'3. Appearance':'2. Appearance';
  }
  function specializedNodeColors(){const colors={};document.querySelectorAll('#specializedNodeColorList input[type="color"]').forEach(input=>{const group=String(input.dataset.group||'');if(group)colors[group]=colorToHex(input.value,'#75bed1');});return colors;}
  function configureSpecializedNetworkColors(payload){
    const section=$('specializedNetworkColorControls'),list=$('specializedNodeColorList'),edge=$('specializedEdgeColor');if(!section||!list||!edge)return;
    const groups=Array.isArray(payload?.nodeGroups)?payload.nodeGroups.filter(group=>group&&String(group.name||'').trim()):[];
    if(!specializedActive()||!groups.length){section.hidden=true;list.replaceChildren();return;}
    list.replaceChildren();
    groups.forEach((group,index)=>{const label=document.createElement('label'),span=document.createElement('span'),input=document.createElement('input'),fallback=['#75bed1','#dc7f8c','#edb458','#8b78bd','#65b891','#e98957'][index%6],color=colorToHex(group.color,fallback);span.textContent=String(group.name);input.type='color';input.value=color;input.dataset.group=String(group.name);input.dataset.defaultColor=color;input.setAttribute('aria-label',String(group.name)+' node color');input.addEventListener('input',sendSpecializedAppearance);label.append(span,input);list.append(label);});
    const edgeDefault=colorToHex(payload?.edgeColor,'#52665b');edge.value=edgeDefault;edge.dataset.defaultColor=edgeDefault;edge.oninput=sendSpecializedAppearance;section.hidden=false;
  }
  function sendSpecializedAppearance(){
    if(!hasSpecializedWorkspace())return;const payload={type:'bra-specialized-appearance',fontFamily:$('fontFamily')?.value||'Segoe UI',fontSize:Number($('fontSize')?.value)||13,fontColor:$('useThemeFontColor')?.checked?'':($('fontColorHex')?.value||$('fontColor')?.value||''),bold:Boolean($('fontBold')?.checked),italic:Boolean($('fontItalic')?.checked),underline:Boolean($('fontUnderline')?.checked),plotTitle:$('plotTitle')?.value||'',backgroundColor:colorToHex($('plotBackgroundColor')?.value,'#ffffff'),showLabels:Boolean($('showSpecializedLabels')?.checked),showGridlines:Boolean($('showSpecializedGrid')?.checked),showSelectionInfo:$('autoSelectionInfo')?.checked!==false,showAxisTitles:$('showAxisTitles')?.checked!==false,hasAxisTitleOverride:Boolean(currentSpecializedFrame()?.__braCapabilities),xAxisTitle:$('xTitle')?.value||'',yAxisTitle:$('yTitle')?.value||'',axisLeftSpace:Number($('yAxisSpace')?.value)||0,axisBottomSpace:Number($('xAxisSpace')?.value)||0,axisRightSpace:Number($('rightAxisSpace')?.value)||0,axisTopSpace:Number($('topAxisSpace')?.value)||0,useCustomColors:true,primaryColor:colorToHex($('specializedPrimaryColor')?.value,'#2f8f83'),secondaryColor:colorToHex($('specializedSecondaryColor')?.value,'#d1775b'),specializedColorScale:$('specializedColorScale')?.value||'Viridis',moduleNames:Object.fromEntries(state.moduleNames||new Map()),nodeColors:specializedNodeColors(),edgeColor:colorToHex($('specializedEdgeColor')?.value,'#52665b')};
    currentSpecializedFrames().forEach(frame=>{if(frame.contentWindow)frame.contentWindow.postMessage(payload,'*');});
  }
  function updateEnrichmentAnalysisMode(){
    if(!hasSpecializedWorkspace())return;const select=$('analysisSelect');if(!select)return;
    const selected=selectedAnalysisValues(),none=!selected.length,generic=!none&&selected.every(genericAnalysisValue),stack=$('specializedPlotStack');
    // Generic visualizations now use their verified automatic variable mapping.
    // Keep the legacy controls in the document for the renderer, but never show
    // the redundant variable-search, drag-role, or auto-assign panel.
    $('genericDataControls').hidden=true;$('genericPlotSection').hidden=true;$('plot').hidden=!generic;if($('plotEmptyState'))$('plotEmptyState').hidden=!none;
    // The same toolbar stays visible for specialized plots; only generic-variable
    // controls and generic data-colour controls are removed.
    $('genericPreviewHead').hidden=false;
    if($('dataColorControls'))$('dataColorControls').hidden=!generic;
    if($('specializedLabelControl'))$('specializedLabelControl').hidden=true;
    if($('specializedGridControl'))$('specializedGridControl').hidden=true;
    if($('specializedPlotColorControls'))$('specializedPlotColorControls').hidden=generic||none;
    if($('specializedNetworkColorControls'))$('specializedNetworkColorControls').hidden=true;
    // Specialized figures use their own primary/secondary and gradient controls.
    // Hide only the generic plotting controls whose roles do not map to a
    // finalized scientific figure; typography and specialized colors stay live.
    const genericOnlyControls=['theme','barOrientation','showGrid','foldChangeScale','aggregation','colorScale','networkLayout','networkEdges','pointSize','opacity','showLegend','showLabels'];
    genericOnlyControls.forEach(id=>{const el=$(id);if(!el)return;const target=el.closest('label')||el;target.hidden=!generic;});
    if($('axisTitleInputs'))$('axisTitleInputs').hidden=none;
    if($('axisTitleToggle'))$('axisTitleToggle').hidden=none;
    if($('showLabelsControl'))$('showLabelsControl').hidden=!generic;
    if($('selectionInfoControls'))$('selectionInfoControls').hidden=true;
    if($('specializedColorScaleControl'))$('specializedColorScaleControl').hidden=false;
    ['volcanoOptions','histogramOptions','circosOptions','genomeRegionOptions'].forEach(id=>{const el=$(id);if(el)el.hidden=!generic;});
    if($('viewPlotCode'))$('viewPlotCode').hidden=!generic;
    if(stack){stack.hidden=generic||none;if(!generic&&!none){rebuildSpecializedFrames();setTimeout(()=>{sendSpecializedView();sendSpecializedAppearance();},180);}else if(none){stack.replaceChildren();stack.dataset.selection='';}}
    document.querySelectorAll('.plot-toolbar button').forEach(button=>button.disabled=none);
    if(none){try{Plotly.purge('plot');}catch(_err){}state.figure=null;state.plotEventsBound=false;}
    const hint=$('analysisModeHint');if(hint)hint.textContent=none?(moduleName==='combined'?'No plot is selected. Choose KEGG/pathway results under “KEGG / pathway database analyses” or PPI results under “STRING PPI analyses”.':'No plot is selected. Click this list and choose the result you want to inspect.'):generic?'The selected visualization uses the best matching result sheet and variables automatically.':'This finalized analysis uses its own verified data and remains linked to the spreadsheet.';
    if(generic||none){if($('specializedViewSection'))$('specializedViewSection').hidden=true;const appearance=$('appearanceSectionSummary');if(appearance)appearance.textContent='2. Appearance';if(none){const guide=$('plotGuide');if(guide)guide.textContent='Choose a plot or analysis in section 1. Nothing is drawn automatically.';}else safeStudioResize();}
    else{configureSpecializedView();specializedGuide();updateSpecializedCapabilityControls();}
    if(generic){updateRelevantControls();const exports=$('exportFormat');if(exports)for(const option of exports.options){option.hidden=false;option.disabled=false;}const note=$('publicationExportPanel')?.querySelector('.export-title p');if(note?.dataset.original)note.textContent=note.dataset.original;}
    requestAnimationFrame(fitLinkedSheetToViewport);
  }
  function preferredGenericTable(type){
    if(moduleName==='de')return null;
    const patterns=type==='Network'?[/(?:string|ppi).*edge/i,/network.*edge/i,/edge/i]:type==='Line'?[/module.*trend/i,/module.*expression/i,/enrichment.*result/i]:[/enrichment.*result/i,/pathway.*enrichment/i,/module.*trait/i];
    for(const pattern of patterns){const match=state.tables.find(table=>pattern.test(String(table.sheet_name||table.label||'')));if(match)return match.key;}
    return state.tables[0]?.key||null;
  }
  async function selectTableForGenericPlot(type){
    const contrastChanged=await syncDEContrastTableForPlot();if(contrastChanged)return true;
    const target=preferredGenericTable(type);if(target&&$('tableSelect').value!==target){$('tableSelect').value=target;await loadTable();return true;}return false;
  }
  async function handleAnalysisSelectChange(){
    if(!hasSpecializedWorkspace())return;
    state.memberSelection=null;state.memberReturnTerm='';state.rowSubset=null;$('sheetBackToResults').hidden=true;
    const genericType=genericAnalysisPlotType($('analysisSelect')?.value);if(genericType&&[...$('plotType').options].some(option=>option.value===genericType)){$('plotType').value=genericType;updateSpecialOptions();}
    updateEnrichmentAnalysisMode();
    if(genericType){const changed=await selectTableForGenericPlot(genericType);if(!changed)autoAssign();}
    renderLinkedSpreadsheet();
  }
  async function init(){
    populatePlotTypes();updateTypographySummary();updateAxisSpacingLabels();
    // Keep Appearance expanded on every first open; only the sidebar itself
    // scrolls, so expanding it never creates a second page-level scrollbar.
    if($('appearanceSection'))$('appearanceSection').open=true;
    const offlineStore=window.__OFFLINE_STUDIO_DATA__;
    const meta=offlineStore?{tables:offlineStore.meta,member_annotations:offlineStore.member_annotations||{}}:await (await fetch('/api/meta')).json();
    state.tables=Array.isArray(meta.tables)?meta.tables:[];state.memberAnnotations=meta.member_annotations||offlineStore?.member_annotations||{};state.analysisSource=offlineStore?.analysis_source||'';
    $('tableSelect').innerHTML=state.tables.map(t=>`<option value="${esc(t.key)}">${esc(t.label)}</option>`).join('');
    if(moduleName==='enrichment'){const label=document.querySelector('label[for="tableSelect"]');if(label)label.textContent='GO analysis results · Enrichment results';$('tableSelect').disabled=true;const hint=document.querySelector('.topbar-hint');if(hint)hint.remove();}
    if(moduleName==='network'){const label=document.querySelector('label[for="tableSelect"]');if(label)label.textContent='PPI / network result sheet';const hint=document.querySelector('.topbar-hint');if(hint)hint.remove();const back=$('sheetBackToResults');if(back)back.textContent='Back to network results';}
    if(moduleName==='combined'){const label=document.querySelector('label[for="tableSelect"]');if(label)label.textContent='Combined analysis result sheet';$('tableSelect').disabled=false;const hint=document.querySelector('.topbar-hint');if(hint)hint.remove();}
    if(!state.tables.length){$('dataSummary').textContent='No result tables were embedded in this report. Re-run the analysis to regenerate the interactive HTML after the Excel workbook is created.';return;}
    setupDEContrastControls();
    if(moduleName==='de'&&state.contrastTables.length>=2){state.contrastTableKey=state.contrastTables[0].key;$('contrastSelect').value=state.contrastTableKey;$('tableSelect').value=state.contrastTableKey;}
    await loadTable();
    const initialGeneric=genericAnalysisPlotType($('analysisSelect')?.value);if(initialGeneric&&[...$('plotType').options].some(option=>option.value===initialGeneric)){$('plotType').value=initialGeneric;updateSpecialOptions();await selectTableForGenericPlot(initialGeneric);}
    updateEnrichmentAnalysisMode();
  }
  function jumpToSheetRow() {
    const indices=orderedSheetIndices(),requested=Math.trunc(Number($('sheetJumpRow').value));
    if(!Number.isInteger(requested)||requested<1||requested>indices.length){$('sheetPageSummary').textContent=`Enter a row from 1 to ${indices.length.toLocaleString()}.`;return;}
    const rowIndex=indices[requested-1];selectSpreadsheetRows([rowIndex],{reveal:true,focusPlot:true});
  }
  function jumpToSheetPage() {
    const indices=orderedSheetIndices(),pageSize=sheetPageSizeFor(indices.length),pages=Math.max(1,Math.ceil(indices.length/pageSize)),requested=Math.trunc(Number($('sheetJumpPage').value));
    if(!Number.isInteger(requested)||requested<1||requested>pages){$('sheetPageSummary').textContent=`Enter a page from 1 to ${pages}.`;return;}
    state.sheetPage=requested-1;renderLinkedSpreadsheet();
  }
  document.querySelectorAll('.role').forEach(el=>{el.addEventListener('dragover',e=>e.preventDefault());el.addEventListener('drop',e=>{e.preventDefault();setRole(el.dataset.role,e.dataTransfer.getData('text/plain'));});el.addEventListener('click',()=>{if(state.selectedVariable)setRole(el.dataset.role,state.selectedVariable);else setRole(el.dataset.role,null);});});
  let renderTimer=null;const scheduleRender=()=>{clearTimeout(renderTimer);renderTimer=setTimeout(renderPlot,180);};
  ['theme','plotBackgroundColor','barOrientation','aggregation','colorScale','networkLayout','networkEdges','pointSize','opacity','showGrid','showLegend','showLabels','plotTitle','volcanoLfcCutoff','volcanoPCutoff','volcanoMinSize','volcanoMaxSize','volcanoLabelCount','volcanoCounts','volcanoConnectors','histogramBins','circosPCutoff','circosSigOnly','circosFreeCamera','genomeRegionGeneCount','genomeRegionAutoScale','genomeRegionGuideLines'].forEach(id=>{const el=$(id);if(el)el.addEventListener('input',scheduleRender);});
  ['showAxisTitles','xTitle','yTitle'].forEach(id=>{const el=$(id);if(el)el.addEventListener('input',()=>specializedActive()?sendSpecializedAppearance():scheduleRender());});
  $('dragMode').addEventListener('change',()=>specializedActive()?sendSpecializedCommand($('dragMode').value):setDragMode($('dragMode').value));
  if($('genomeRegionAutoScale'))$('genomeRegionAutoScale').addEventListener('change',()=>{if($('genomeRegionAutoScale').checked)state.genomeRegionYRange=null;});
  const histAll=$('histogramContigAll'),histNone=$('histogramContigNone'),circosAll=$('circosContigAll'),circosNone=$('circosContigNone'),genomeAll=$('genomeRegionContigAll'),genomeNone=$('genomeRegionContigNone');if(histAll)histAll.addEventListener('click',()=>setAllContigs('Histogram',true));if(histNone)histNone.addEventListener('click',()=>setAllContigs('Histogram',false));if(circosAll)circosAll.addEventListener('click',()=>setAllContigs('Circos',true));if(circosNone)circosNone.addEventListener('click',()=>setAllContigs('Circos',false));if(genomeAll)genomeAll.addEventListener('click',()=>setAllContigs('Genome region',true));if(genomeNone)genomeNone.addEventListener('click',()=>setAllContigs('Genome region',false));
  $('foldChangeScale').addEventListener('change',()=>{state.genomeRegionYRange=null;applyDefaultAxisTitles($('plotType').value);renderPlot();});
  if($('analysisSelect'))$('analysisSelect').addEventListener('change',handleAnalysisSelectChange);if($('specializedViewSelect'))$('specializedViewSelect').addEventListener('change',()=>{sendSpecializedView();setTimeout(sendSpecializedAppearance,40);});
  $('plotType').addEventListener('change',async()=>{updateSpecialOptions();const changed=await syncDEContrastTableForPlot();if(!changed)autoAssign();});
  $('contrastSelect').addEventListener('change',async()=>{state.contrastTableKey=$('contrastSelect').value;const changed=await syncDEContrastTableForPlot();if(!changed&&$('tableSelect').value!==state.contrastTableKey){$('tableSelect').value=state.contrastTableKey;await loadTable();}});
  $('compareAllContrasts').addEventListener('change',async()=>{const changed=await syncDEContrastTableForPlot();if(!changed)autoAssign();});
  function bindPaneSplitter(splitter,onMove){let active=false;splitter.addEventListener('pointerdown',event=>{if(window.matchMedia('(max-width:1000px)').matches)return;active=true;splitter.classList.add('dragging');splitter.setPointerCapture(event.pointerId);event.preventDefault();});splitter.addEventListener('pointermove',event=>{if(!active)return;onMove(event);safeStudioResize();});const stop=()=>{active=false;splitter.classList.remove('dragging');safeStudioResize();};splitter.addEventListener('pointerup',stop);splitter.addEventListener('pointercancel',stop);}
  bindPaneSplitter($('sidebarSplitter'),event=>{const workspace=document.querySelector('.workspace'),rect=workspace.getBoundingClientRect();const width=Math.max(260,Math.min(520,event.clientX-rect.left));workspace.style.setProperty('--sidebar-width',width+'px');});
  $('sidebarSplitter').addEventListener('dblclick',()=>document.querySelector('.workspace').style.setProperty('--sidebar-width','330px'));
  bindPaneSplitter($('plotSheetSplitter'),event=>{const panel=document.querySelector('.main-panel'),rect=panel.getBoundingClientRect();const width=Math.max(620,Math.min(rect.width-348,event.clientX-rect.left));panel.style.setProperty('--plot-width',width+'px');try{localStorage.setItem('bra_plot_width',String(width));}catch(_err){}});
  $('plotSheetSplitter').addEventListener('dblclick',()=>{document.querySelector('.main-panel').style.setProperty('--plot-width','760px');try{localStorage.removeItem('bra_plot_width');}catch(_err){}});
  try{const saved=Number(localStorage.getItem('bra_plot_width'));if(Number.isFinite(saved)&&saved>=620)document.querySelector('.main-panel').style.setProperty('--plot-width',Math.min(saved,1200)+'px');}catch(_err){}
  $('tableSelect').addEventListener('change',async()=>{const matching=state.contrastTables.find(t=>t.key===$('tableSelect').value);if(matching){state.contrastTableKey=matching.key;$('contrastSelect').value=matching.key;}await loadTable();});$('rowLimit').addEventListener('change',loadTable);$('variableSearch').addEventListener('input',e=>renderVariables(e.target.value));$('autoAssign').addEventListener('click',autoAssign);$('clearRoles').addEventListener('click',clearRoles);$('resetView').addEventListener('click',()=>specializedActive()?sendSpecializedCommand('reset'):resetPlotView());$('toolbarZoomIn').addEventListener('click',()=>specializedActive()?sendSpecializedCommand('zoomIn'):zoomCurrentPlot(.72));$('toolbarZoomOut').addEventListener('click',()=>specializedActive()?sendSpecializedCommand('zoomOut'):zoomCurrentPlot(1.38));$('toolbarDownload').addEventListener('click',downloadCurrentPlot);if($('openData'))$('openData').addEventListener('click',()=>$('dataDialog').showModal());if($('closeData'))$('closeData').addEventListener('click',()=>$('dataDialog').close());
  $('viewPlotCode').addEventListener('click',openPlotCodeDialog);$('closePlotCode').addEventListener('click',()=>$('plotCodeDialog').close());$('plotCodeMode').addEventListener('change',updatePlotCodeView);$('copyPlotCode').addEventListener('click',async()=>{const text=$('plotCodeText').textContent||'';try{await navigator.clipboard.writeText(text);$('plotCodeStatus').textContent='Code copied to clipboard.';}catch(_err){const area=document.createElement('textarea');area.value=text;document.body.appendChild(area);area.select();document.execCommand('copy');area.remove();$('plotCodeStatus').textContent='Code copied to clipboard.';}});
  window.addEventListener('resize',()=>requestAnimationFrame(fitLinkedSheetToViewport));window.addEventListener('scroll',()=>requestAnimationFrame(fitLinkedSheetToViewport),{passive:true});requestAnimationFrame(fitLinkedSheetToViewport);
  $('sheetBackToResults').addEventListener('click',restoreEnrichmentResults);
  window.addEventListener('message',event=>{const payload=event?.data;if(!payload)return;if(payload.type==='bra-specialized-selection'){showSpecializedMembers(payload,event.source);return;}if(payload.type==='bra-specialized-clear-selection'){if(state.memberSelection||state.rowSubset||state.selectedRows.size)restoreOverallResults();$('plotMessage').textContent='Returned to the complete linked result sheet.';return;}if(payload.type==='bra-specialized-ready'||payload.type==='bra-specialized-capabilities'){const frame=currentSpecializedFrames().find(item=>item.contentWindow===event.source);if(frame&&payload.capabilities&&typeof payload.capabilities==='object')frame.__braCapabilities=payload.capabilities;updateSpecializedCapabilityControls();if(payload.type==='bra-specialized-ready'){configureSpecializedNetworkColors(payload);sendSpecializedView();sendSpecializedCommand($('dragMode')?.value||'pan');setTimeout(sendSpecializedAppearance,40);}}});
  $('sheetSearch').addEventListener('input',()=>{state.sheetPage=0;renderLinkedSpreadsheet();});$('sheetPageSize').addEventListener('change',()=>{updateSheetPageSizeControls();state.sheetPage=0;renderLinkedSpreadsheet();});$('sheetCustomPageSize').addEventListener('change',()=>{if($('sheetPageSize').value!=='custom')return;state.sheetPage=0;renderLinkedSpreadsheet();});$('sheetCustomPageSize').addEventListener('keydown',e=>{if(e.key==='Enter'&&$('sheetPageSize').value==='custom'){state.sheetPage=0;renderLinkedSpreadsheet();}});updateSheetPageSizeControls();$('sheetPrevious').addEventListener('click',()=>{state.sheetPage=Math.max(0,state.sheetPage-1);renderLinkedSpreadsheet();});$('sheetNext').addEventListener('click',()=>{state.sheetPage+=1;renderLinkedSpreadsheet();});$('sheetJumpRowGo').addEventListener('click',jumpToSheetRow);$('sheetJumpPageGo').addEventListener('click',jumpToSheetPage);$('sheetJumpRow').addEventListener('keydown',e=>{if(e.key==='Enter')jumpToSheetRow();});$('sheetJumpPage').addEventListener('keydown',e=>{if(e.key==='Enter')jumpToSheetPage();});
  const linkedSheet=document.querySelector('.linked-sheet');if(linkedSheet)linkedSheet.addEventListener('click',event=>{if(event.target?.closest?.('tbody tr,thead th,button,input,select,a,label'))return;const selectedMember=$('linkedTable').querySelector('tbody tr.selected-row');if(state.memberSelection&&selectedMember){selectedMember.classList.remove('selected-row');sendSpecializedCommand('clearSelection');$('plotMessage').textContent='Selection cleared; the member list remains open.';return;}if(state.rowSubset||state.selectedRows.size)restoreOverallResults();});
  if($('sheetExportExcel'))$('sheetExportExcel').addEventListener('click',exportLinkedSheetExcel);
  // v40 Circos uses Plotly's native Cartesian pan/zoom. No CSS canvas transform or custom pointer capture is used, so hover/click hit-testing always remains aligned with the visible genes.
  $('circosFreeCamera').addEventListener('change',()=>{if($('plotType').value==='Circos')setDragMode($('circosFreeCamera').checked?'pan':$('dragMode').value);});

  $('resetAppearance').addEventListener('click',resetAppearanceDefaults);$('openTypography').addEventListener('click',openTypographyDialog);$('closeTypography').addEventListener('click',()=>$('typographyDialog').close());$('cancelTypography').addEventListener('click',()=>$('typographyDialog').close());$('applyTypography').addEventListener('click',applyTypography);$('resetTypography').addEventListener('click',()=>setTypographyDraft(defaultTypography()));
  ['fontFamily','fontSize','useThemeFontColor','fontBold','fontItalic','fontUnderline'].forEach(id=>$(id).addEventListener('input',()=>{updateTypographySample();sendSpecializedAppearance();}));$('fontColor').addEventListener('input',()=>{$('useThemeFontColor').checked=false;$('fontColorHex').value=$('fontColor').value;updateTypographySample();});$('fontColorHex').addEventListener('input',()=>{const color=validHexColor($('fontColorHex').value);if(color){$('fontColor').value=color;$('useThemeFontColor').checked=false;}updateTypographySample();});
  ['generalDataColor','selectedDataColor','upDataColor','downDataColor','nsDataColor','networkNodeColor','networkEdgeColor'].forEach(id=>{const el=$(id);if(el)el.addEventListener('input',scheduleRender);});
  const clearTransientSelectionHover=()=>{try{Plotly.Fx.unhover('plot');}catch(_err){}};
  if($('autoSelectionInfo'))$('autoSelectionInfo').addEventListener('change',()=>{if(!$('autoSelectionInfo').checked)clearTransientSelectionHover();if(specializedActive())sendSpecializedAppearance();else if($('autoSelectionInfo').checked)refreshStudioSelectionInfo();else removeStudioSelectionInfo();});
  ['yAxisSpace','xAxisSpace','rightAxisSpace','topAxisSpace'].forEach(id=>{
    const range=$(id),number=$(id+'Number');if(!range||!number)return;
    const apply=value=>{range.value=String(Math.max(0,Math.min(Number(range.max),Math.round(Number(value)||0))));updateAxisSpacingLabels();if(specializedActive())sendSpecializedAppearance();else scheduleRender();};
    range.addEventListener('input',()=>apply(range.value));number.addEventListener('input',()=>{if(number.value!=='')apply(number.value);});number.addEventListener('change',()=>apply(number.value));
  });
  ['plotTitle','plotBackgroundColor','fontColor','fontColorHex'].forEach(id=>{const el=$(id);if(el)el.addEventListener('input',sendSpecializedAppearance);});
  if($('showSpecializedLabels'))$('showSpecializedLabels').addEventListener('change',sendSpecializedAppearance);
  if($('showSpecializedGrid'))$('showSpecializedGrid').addEventListener('change',sendSpecializedAppearance);
  ['specializedPrimaryColor','specializedSecondaryColor','specializedColorScale'].forEach(id=>{const el=$(id);if(el)el.addEventListener('input',sendSpecializedAppearance);});
  // Publication export controls work in both server and offline reports.
  // Bind defensively so older reports without these controls can still initialize.
  ['exportFormat','paperSize','paperOrientation','dpiMode','customDpi','widthMm','heightMm'].forEach(id=>{const el=$(id);if(!el)return;el.addEventListener('input',()=>{if(id==='paperSize')updatePaperInputs();const customDpi=$('customDpi'),dpiMode=$('dpiMode');if(customDpi&&dpiMode)customDpi.disabled=dpiMode.value!=='custom';if($('paperSize'))updateExportEstimate();});});
  const exportButton=$('exportButton');if(exportButton)exportButton.addEventListener('click',exportPlot);const closeExport=$('closePublicationExport');if(closeExport)closeExport.addEventListener('click',closePublicationExport);const exportName=$('exportName');if(exportName)exportName.addEventListener('input',()=>exportName.dataset.userEdited='1');
  const stopServer=$('stopServer');if(stopServer)stopServer.addEventListener('click',async()=>{await fetch('/api/shutdown',{method:'POST'});const status=$('serverStatus'),exportStatus=$('exportStatus');if(status)status.textContent='Server closing';if(exportStatus)exportStatus.textContent='You may close this browser tab.';});
  let resizeTimer=null;window.addEventListener('resize',()=>{clearTimeout(resizeTimer);resizeTimer=setTimeout(()=>{if(state.figure)safeStudioResize();},120);});
  init().catch(err=>{$('dataSummary').textContent='Studio startup failed: '+err.message;});
})();
</script>'''


class StudioHandler(BaseHTTPRequestHandler):
    server_version = "BacterialRNAVisualizationStudio/1.3"

    @property
    def state(self) -> StudioState:
        return self.server.state  # type: ignore[attr-defined]

    def log_message(self, fmt: str, *args: Any) -> None:
        sys.stdout.write("[%s] %s\n" % (self.log_date_time_string(), fmt % args))
        sys.stdout.flush()

    def _send(self, status: int, body: bytes, content_type: str, extra: dict[str, str] | None = None) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        if extra:
            for key, value in extra.items():
                self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def _json(self, status: int, payload: Any) -> None:
        self._send(status, json.dumps(payload, ensure_ascii=False).encode("utf-8"), "application/json; charset=utf-8")

    def do_GET(self) -> None:  # noqa: N802
        self.state.touch()
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/":
            companion = _companion_analysis_html(self.state.module, self.state.output_dir)
            html = HTML_TEMPLATE.replace("__MODULE__", self.state.module).replace("__TITLE__", MODULE_TITLES[self.state.module])
            specialized_workspace = self.state.module in {"de", "enrichment", "network", "combined"}
            html = html.replace("__SECTION_ONE_TITLE__", "1. Analysis / visualization" if specialized_workspace else "1. Data")
            html = html.replace("__SECTION_ONE_EXTRA__", companion if specialized_workspace else "")
            html = html.replace("__COMPANION_ANALYSES_TOP__", "" if specialized_workspace else companion)
            self._send(200, html.encode("utf-8"), "text/html; charset=utf-8")
            return
        if parsed.path == "/plotly.min.js":
            self._send(200, py_offline.get_plotlyjs().encode("utf-8"), "application/javascript; charset=utf-8")
            return
        if parsed.path == "/api/meta":
            tables = [self.state.table_metadata(source) for source in self.state.tables]
            self._json(200, {"module": self.state.module, "title": MODULE_TITLES[self.state.module], "tables": tables, "output_dir": str(self.state.output_dir), "member_annotations": self.state.member_annotations})
            return
        if parsed.path == "/api/table":
            query = urllib.parse.parse_qs(parsed.query)
            key = query.get("key", [""])[0]
            try:
                limit = min(MAX_ROWS_HARD, max(1, int(query.get("limit", [str(MAX_ROWS_DEFAULT)])[0])))
            except ValueError:
                limit = MAX_ROWS_DEFAULT
            source = self.state.source(key)
            if not source:
                self._json(404, {"error": "Unknown data table."})
                return
            try:
                frame = read_delimited(source.path, limit + 1, source.sheet_name)
                truncated = len(frame) > limit
                if truncated:
                    frame = frame.iloc[:limit].copy()
                columns = []
                for col in frame.columns:
                    numeric = pd.to_numeric(frame[col], errors="coerce")
                    columns.append({"name": str(col), "kind": "numeric" if numeric.notna().mean() >= 0.75 else "categorical", "unique": int(frame[col].nunique(dropna=True))})
                rows = [{str(k): clean_json_value(v) for k, v in row.items()} for row in frame.to_dict(orient="records")]
                self._json(200, {"key": source.key, "label": source.label, "path": str(source.path), "filename": source.path.name, "sheet_name": source.sheet_name, "columns": columns, "rows": rows, "truncated": truncated})
            except Exception as exc:
                self._json(500, {"error": f"Could not read {source.path.name}: {exc}"})
            return
        if parsed.path not in {"/", "/plotly.min.js"} and not parsed.path.startswith("/api/") and not parsed.path.startswith("/download/"):
            relative = urllib.parse.unquote(parsed.path.lstrip("/"))
            candidate = (self.state.output_dir / relative).resolve()
            root = self.state.output_dir.resolve()
            try:
                candidate.relative_to(root)
            except ValueError:
                self._json(403, {"error": "Resource is outside the result directory."})
                return
            if candidate.is_file():
                mime = mimetypes.guess_type(candidate.name)[0] or "application/octet-stream"
                self._send(200, candidate.read_bytes(), mime)
                return
        if parsed.path.startswith("/download/"):
            token = parsed.path.rsplit("/", 1)[-1]
            target = self.state.exports.get(token)
            if not target or not target.is_file():
                self._json(404, {"error": "Export file not found."})
                return
            content = target.read_bytes()
            mime = mimetypes.guess_type(target.name)[0] or "application/octet-stream"
            self._send(200, content, mime, {"Content-Disposition": f'attachment; filename="{target.name}"'})
            return
        self._json(404, {"error": "Not found."})

    def do_POST(self) -> None:  # noqa: N802
        self.state.touch()
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/api/shutdown":
            self._json(200, {"ok": True})
            threading.Thread(target=self.server.shutdown, daemon=True).start()
            return
        if parsed.path != "/api/export":
            self._json(404, {"error": "Not found."})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        if length <= 0 or length > MAX_JSON_BYTES:
            self._json(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, {"error": "The export request is too large."})
            return
        try:
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
            result = self._export(payload)
            self._json(200, result)
        except Exception as exc:
            traceback.print_exc()
            self._json(500, {"error": str(exc)})

    def _export(self, payload: dict[str, Any]) -> dict[str, Any]:
        fmt = str(payload.get("format", "tiff")).lower()
        if fmt == "jpg":
            fmt = "jpeg"
        if fmt not in {"png", "jpeg", "webp", "tiff", "svg", "pdf", "html"}:
            raise ValueError("Unsupported export format.")
        width_mm = float(payload.get("width_mm", 297.0))
        height_mm = float(payload.get("height_mm", 210.0))
        if not (20 <= width_mm <= 2000 and 20 <= height_mm <= 2000):
            raise ValueError("Width and height must be between 20 and 2,000 mm.")
        dpi_mode = str(payload.get("dpi_mode", "maximum"))
        requested_dpi = payload.get("dpi")
        width_in, height_in = width_mm / 25.4, height_mm / 25.4
        max_safe = max(72, min(MAX_DPI, int(MAX_EXPORT_DIMENSION / max(width_in, height_in)), int(math.sqrt(MAX_EXPORT_PIXELS / (width_in * height_in)))))
        if dpi_mode == "maximum" or requested_dpi in {None, "", 0}:
            dpi = max_safe
        else:
            dpi = int(float(requested_dpi))
            if not (72 <= dpi <= MAX_DPI):
                raise ValueError("DPI must be between 72 and 2,400.")
            if int(width_in * dpi) > MAX_EXPORT_DIMENSION or int(height_in * dpi) > MAX_EXPORT_DIMENSION or int(width_in * height_in * dpi * dpi) > MAX_EXPORT_PIXELS:
                raise ValueError(f"The requested image is too large for safe export. Use at most {max_safe} DPI for this paper size.")
        width_px = max(100, int(round(width_in * dpi)))
        height_px = max(100, int(round(height_in * dpi)))
        base = safe_name(str(payload.get("filename", "Publication plot")))
        ext = "jpg" if fmt == "jpeg" else ("tif" if fmt == "tiff" else fmt)
        target = self.state.export_dir / f"{base}.{ext}"
        counter = 2
        while target.exists():
            target = self.state.export_dir / f"{base} {counter}.{ext}"
            counter += 1

        if fmt == "html":
            figure = payload.get("figure")
            if not isinstance(figure, dict):
                raise ValueError("The current Plotly figure was not supplied.")
            html = pio.to_html(
                figure,
                include_plotlyjs=True,
                full_html=True,
                config={
                    "responsive": True,
                    "displaylogo": False,
                    "editable": True,
                    "edits": {
                        "annotationPosition": True,
                        "annotationTail": False,
                        "annotationText": False,
                        "axisTitleText": False,
                        "colorbarPosition": True,
                        "colorbarTitleText": False,
                        "legendPosition": False,
                        "legendText": False,
                        "shapePosition": False,
                        "titleText": False,
                    },
                },
            )
            target.write_text(html, encoding="utf-8")
            summary = "Interactive HTML with embedded Plotly.js. Paper size and DPI do not apply to HTML."
        else:
            svg_text = str(payload.get("svg", ""))
            if not svg_text.lstrip().startswith("<svg"):
                raise ValueError("The browser did not provide a valid SVG snapshot.")
            # Give vector exports an exact physical page size while retaining the
            # original Plotly viewBox. CairoSVG then performs high-quality scaling.
            svg_text = re.sub(r'<svg\b([^>]*)\bwidth="[^"]*"', r'<svg\1', svg_text, count=1)
            svg_text = re.sub(r'<svg\b([^>]*)\bheight="[^"]*"', r'<svg\1', svg_text, count=1)
            svg_text = svg_text.replace("<svg", f'<svg width="{width_mm}mm" height="{height_mm}mm"', 1)
            svg_bytes = svg_text.encode("utf-8")
            if fmt == "svg":
                target.write_bytes(svg_bytes)
            else:
                if cairosvg is None:
                    raise RuntimeError(f"CairoSVG is unavailable: {CAIROSVG_IMPORT_ERROR}")
                if fmt == "pdf":
                    cairosvg.svg2pdf(bytestring=svg_bytes, write_to=str(target))
                else:
                    png_bytes = cairosvg.svg2png(bytestring=svg_bytes, output_width=width_px, output_height=height_px)
                    if fmt == "png":
                        if Image is None:
                            target.write_bytes(png_bytes)
                        else:
                            with Image.open(io.BytesIO(png_bytes)) as image:
                                image.save(target, format="PNG", dpi=(dpi, dpi), optimize=True)
                    else:
                        if Image is None:
                            raise RuntimeError(f"Pillow is unavailable: {PIL_IMPORT_ERROR}")
                        with Image.open(io.BytesIO(png_bytes)) as image:
                            image = image.convert("RGB")
                            if fmt == "jpeg":
                                image.save(target, format="JPEG", quality=100, subsampling=0, dpi=(dpi, dpi), optimize=True)
                            elif fmt == "webp":
                                image.save(target, format="WEBP", quality=100, lossless=True, method=6)
                            else:
                                image.save(target, format="TIFF", compression="tiff_lzw", dpi=(dpi, dpi))
            summary = f"{width_mm:.1f} × {height_mm:.1f} mm, {dpi} DPI, {width_px:,} × {height_px:,} pixels."

        token = base64.urlsafe_b64encode(os.urandom(12)).decode("ascii").rstrip("=")
        self.state.exports[token] = target
        return {"ok": True, "path": str(target), "filename": target.name, "download_url": f"/download/{token}", "summary": summary, "dpi": dpi, "width_px": width_px, "height_px": height_px}


def idle_watcher(state: StudioState) -> None:
    while state.server:
        time.sleep(30)
        if time.time() - state.last_activity > state.idle_seconds:
            print(f"Visualization studio idle for {state.idle_seconds} seconds; shutting down.", flush=True)
            state.server.shutdown()
            return




GENERIC_PLOT_TYPES = {
    "de": ["Volcano", "Circos", "Genome region", "Scatter", "Violin + box", "Histogram"],
    "enrichment": ["Dot plot", "Bar", "Scatter", "Heatmap", "Network", "Histogram"],
    "network": ["Network", "Scatter", "Bar", "Violin + box", "Heatmap", "Line", "Histogram"],
    "combined": ["Network", "Dot plot", "Bar", "Scatter", "Heatmap", "Line", "Histogram"],
}


COMPANION_ANALYSES = {
    "enrichment": [
        ("go_dag_interactive.html", "GO DAG focus + context"),
        ("go_annotation_landscape_interactive.html", "GO annotation landscape"),
        ("go_semantic_similarity_interactive.html", "GO semantic-similarity clusters"),
        ("go_cellular_component_interactive.html", "Bacterial cellular-component map"),
        ("enrichment_rich_factor_interactive.html", "RichFactor enrichment"),
        ("enrichment_circos_interactive.html", "Enrichment Circos-style summary"),
        ("enrichment_bar_interactive.html", "Enrichment bar plot"),
        ("enrichment_dot_interactive.html", "Enrichment dot plot"),
        ("enrichment_network_interactive.html", "Term-overlap network"),
        ("gene_term_network_interactive.html", "Gene-term network"),
        ("gsea_term_profiles_interactive.html", "GSEA term profiles"),
        ("gsea_multi_term_running_score_interactive.html", "GSEA multi-term ES"),
        ("gsea_global_es_interactive.html", "GSEA global ES"),
        ("gsea_nes_significance_interactive.html", "GSEA NES vs significance"),
    ],
    "network": [
        ("gene_network_interactive.html", "Co-expression / regulatory network"),
        ("module_trait_interactive.html", "Module–trait associations"),
        ("module_expression_heatmap_interactive.html", "Module expression heatmap"),
        ("module_expression_trends_interactive.html", "Module expression trends"),
    ],
    "pathway": [
        ("kegg_pathway_maps_interactive.html", "KEGG pathway expression maps"),
        ("pathway_enrichment_bar_interactive.html", "Pathway enrichment bar plot"),
        ("pathway_enrichment_dot_interactive.html", "Pathway enrichment dot plot"),
        ("pathway_enrichment_network_interactive.html", "Pathway-overlap network"),
        ("pathway_gene_term_network_interactive.html", "Gene-pathway network"),
    ],
    "string": [
        ("string_ppi_gene_network_interactive.html", "STRING protein-association network"),
    ],
    "de": [
        ("ma_interactive.html", "MA plot"),
        ("pca_interactive.html", "Sample PCA · 2D"),
        ("sample_pca_3d_interactive.html", "Sample PCA · interactive 3D"),
        ("sample_expression_distributions_interactive.html", "Sample expression distributions"),
        ("sample_correlation_interactive.html", "Sample correlation heatmap"),
        ("sample_dendrogram_interactive.html", "Hierarchical sample clustering"),
        ("source_of_variation_interactive.html", "Source of variation / batch diagnostic"),
        ("de_pvalue_histogram_interactive.html", "Raw p-value diagnostic"),
        ("de_gene_rank_interactive.html", "Ranked differential-expression statistic"),
        ("top_variable_genes_heatmap_interactive.html", "Top-variable-gene heatmap"),
        ("single_gene_expression_interactive.html", "Single-gene expression explorer"),
        ("de_upset_interactive.html", "Multi-contrast UpSet"),
        ("de_venn_interactive.html", "Two-/three-contrast Venn"),
        ("fold_change_comparison_interactive.html", "Fold-change versus fold-change"),
        ("expression_trend_clusters_interactive.html", "Condition expression-pattern clusters"),
    ],
}


def _companion_analysis_html(module: str, output_dir: Path) -> str:
    """Build the analysis selector used by specialized report workspaces.

    Enrichment results is the only generic X/Y plotting table. Every other
    choice is a purpose-built specialized visualization shown in the main plot
    canvas, never inside the sidebar and never in a new browser page.
    """
    figures = output_dir / "Figures"
    options: list[tuple[str, str, str]] = []
    companion_groups = ("enrichment", "network", "pathway", "string") if module == "combined" else (("enrichment", "pathway") if module == "enrichment" else (module,))
    for companion_module in companion_groups:
        for filename, label in COMPANION_ANALYSES.get(companion_module, []):
            candidates = [
                figures / filename,
                figures / filename.replace("_", " "),
                output_dir / filename,
                output_dir / filename.replace("_", " "),
            ]
            path = next((candidate for candidate in candidates if candidate.is_file()), None)
            if path is None:
                continue
            try:
                relative = path.relative_to(output_dir).as_posix()
            except ValueError:
                relative = path.name
            display_label = (
                f"Functional enrichment · {label}" if module == "combined" and companion_module == "enrichment"
                else f"Co-expression · {label}" if module == "combined" and companion_module == "network"
                else f"Pathway database · {label}" if module == "combined" and companion_module == "pathway"
                else f"STRING PPI · {label}" if module == "combined" and companion_module == "string"
                else label
            )
            options.append((companion_module, display_label, urllib.parse.quote(relative, safe="/._-()")))
    if module not in {"de", "enrichment", "network", "combined"}:
        if not options:
            return ""
        links = ''.join(f'<a href="{href}" target="bra_specialized_analysis">{html.escape(label)}</a>' for _group, label, href in options)
        return '<section class="companion-analyses"><strong>Specialized analyses</strong><div class="companion-links">' + links + '</div></section>'

    option_html = ['<option value="" selected>Click to choose a plot or analysis…</option>']
    generic_options = ''.join(
        f'<option value="__generic__:{urllib.parse.quote(plot_type, safe="")}">{html.escape(plot_type)}</option>'
        for plot_type in GENERIC_PLOT_TYPES[module]
    )
    if generic_options:
        option_html.append('<optgroup label="Standard interactive plots">' + generic_options + '</optgroup>')
    group_labels = {
        "de": "Differential-expression analyses",
        "enrichment": "Functional enrichment / GO",
        "network": "Co-expression analyses",
        "pathway": "KEGG / pathway database analyses",
        "string": "STRING PPI analyses",
    }
    for companion_module in companion_groups:
        grouped = [(label, href) for group, label, href in options if group == companion_module]
        if grouped:
            option_html.append('<optgroup label="' + html.escape(group_labels.get(companion_module, companion_module.title())) + '">' + ''.join(
                f'<option value="{href}">{html.escape(label)}</option>' for label, href in grouped
            ) + '</optgroup>')
    initial_hint = (
        'Choose KEGG/pathway results under “KEGG / pathway database analyses”, '
        'or PPI results under “STRING PPI analyses”. Nothing is drawn until you choose.'
        if module == "combined"
        else 'Choose an analysis or visualization. Nothing is drawn until you choose.'
    )
    return (
        '<label for="analysisSelect">Analysis / visualization</label>'
        '<select id="analysisSelect">' + ''.join(option_html) + '</select>'
        '<p class="hint" id="analysisModeHint">' + html.escape(initial_hint) + '</p>'
    )


def _static_report_filename(module: str) -> str:
    return {
        "de": "Differential expression interactive.html",
        "enrichment": "GO enrichment interactive.html",
        "network": "Network analysis interactive.html",
        "combined": "Functional enrichment and co-expression interactive.html",
    }[module]



GENE_KEY_ALIASES = ("gene_id", "geneid", "gene", "locus_tag", "locus", "id")
ANNOTATION_COLUMNS = (
    "gene", "name", "locus_tag", "original_id", "product", "description",
    "protein_name", "gene_names", "matched_accession", "entry_name",
    "go_ids", "go_bp", "go_mf", "go_cc", "kegg", "pathway", "eggnog",
    "contig", "seqid", "start", "end", "strand", "feature_type",
)


def _gene_key_column(frame: pd.DataFrame) -> str | None:
    lowered = {str(column).strip().casefold(): str(column) for column in frame.columns}
    for alias in GENE_KEY_ALIASES:
        if alias in lowered:
            return lowered[alias]
    for column in frame.columns:
        text = str(column).strip().casefold()
        if "gene" in text and "id" in text:
            return str(column)
    return None


def _read_de_annotation_frames(output_dir: Path, sources: list[TableSource], max_rows: int) -> list[pd.DataFrame]:
    frames: list[pd.DataFrame] = []
    for source in sources:
        sheet = str(source.sheet_name or "").casefold()
        label = str(source.label or "").casefold()
        if "gene annotation" not in sheet and "gene annotation" not in label:
            continue
        try:
            frame = read_delimited(source.path, max_rows + 1, source.sheet_name)
        except Exception:
            continue
        if _gene_key_column(frame):
            frames.append(frame)

    config_candidates = [
        output_dir / "Intermediate files" / "de configuration.json",
        output_dir / "Intermediate files" / "de_config.json",
        output_dir / "de configuration.json",
        output_dir / "de_config.json",
    ]
    for config_path in config_candidates:
        try:
            config = json.loads(config_path.read_text(encoding="utf-8-sig"))
        except Exception:
            continue
        for key in ("annotation_file", "coordinate_file"):
            value = str(config.get(key, "") or "").strip()
            if not value:
                continue
            candidate = Path(value)
            if not candidate.is_file():
                continue
            try:
                frame = read_delimited(candidate, max_rows + 1)
            except Exception:
                continue
            if _gene_key_column(frame):
                frames.append(frame)
        break
    return frames


def _merge_de_annotations(frame: pd.DataFrame, annotation_frames: list[pd.DataFrame]) -> pd.DataFrame:
    """Merge biological annotation while repairing incomplete coordinate fields.

    Older/IGV-derived sheets may contain a strand column filled with ``.``.  A
    later canonical gene-coordinate/SAF table must be allowed to repair that
    column instead of being ignored merely because the column name already
    exists.  The same fill-only rule is used for missing coordinates and labels;
    valid values already present in the DE table are never overwritten.
    """
    left_key = _gene_key_column(frame)
    if not left_key or not annotation_frames:
        return frame
    result = frame.copy()
    result["__studio_gene_key__"] = result[left_key].astype("string").fillna("").str.strip()
    allowed = {name.casefold() for name in ANNOTATION_COLUMNS}

    def existing_column(name: str) -> str | None:
        folded = name.casefold()
        return next((str(column) for column in result.columns if str(column).casefold() == folded), None)

    def empty_mask(series: pd.Series) -> pd.Series:
        text = series.astype("string").fillna("").str.strip()
        return series.isna() | text.eq("") | text.str.casefold().isin({"nan", "na", "none", "null", ".", "?"})

    for ann_index, annotation in enumerate(annotation_frames, start=1):
        right_key = _gene_key_column(annotation)
        if not right_key:
            continue
        candidate_columns = [str(column) for column in annotation.columns if str(column) != right_key and str(column).casefold() in allowed]
        if not candidate_columns:
            continue
        right = annotation[[right_key, *candidate_columns]].copy()
        right["__studio_gene_key__"] = right[right_key].astype("string").fillna("").str.strip()
        right = right.loc[right["__studio_gene_key__"].ne("")].drop_duplicates("__studio_gene_key__", keep="first")
        right = right.drop(columns=[right_key])
        rename_map = {column: f"__ann_{ann_index}_{re.sub(r'[^A-Za-z0-9]+', '_', column)}" for column in candidate_columns}
        right = right.rename(columns=rename_map)
        result = result.merge(right, on="__studio_gene_key__", how="left", validate="many_to_one")

        for source_name, temp_name in rename_map.items():
            candidate = result[temp_name]
            target = existing_column(source_name)
            key = source_name.casefold()
            if target is None:
                result[source_name] = candidate
                continue
            if key == "strand":
                current_norm = _normalize_strand_series(result[target])
                candidate_norm = _normalize_strand_series(candidate)
                result[target] = current_norm.where(current_norm.isin(["+", "-"]), candidate_norm)
            elif key in {"start", "end", "chromstart", "chromend"}:
                current_num = pd.to_numeric(result[target], errors="coerce")
                candidate_num = pd.to_numeric(candidate, errors="coerce")
                good_current = current_num.notna()
                if key in {"start", "end"}:
                    good_current &= current_num.gt(0)
                result[target] = result[target].where(good_current, candidate_num)
            else:
                mask = empty_mask(result[target])
                result[target] = result[target].where(~mask, candidate)

        result = result.drop(columns=list(rename_map.values()), errors="ignore")

    result = result.drop(columns=["__studio_gene_key__"], errors="ignore")
    strand_name = existing_column("strand")
    if strand_name:
        result[strand_name] = _normalize_strand_series(result[strand_name])

    # Put the most useful biological annotation beside the gene identifier so
    # users do not have to scroll through every statistical column to find it.
    preferred = [
        left_key, "gene", "name", "locus_tag", "product", "protein_name",
        "gene_names", "description", "matched_accession", "go_ids", "go_bp",
        "go_mf", "go_cc", "kegg", "pathway", "eggnog", "contig", "seqid",
        "start", "end", "strand", "feature_type",
    ]
    front = []
    seen = set()
    for wanted in preferred:
        found = next((str(column) for column in result.columns if str(column).casefold() == str(wanted).casefold()), None)
        if found and found not in seen:
            front.append(found)
            seen.add(found)
    remainder = [str(column) for column in result.columns if str(column) not in seen]
    return result[front + remainder]


def build_static_report(module: str, output_dir: Path, destination: Path | None = None, max_rows: int = 50_000) -> Path:
    '''Build one offline interactive HTML report that needs no local server.'''
    output_dir = output_dir.resolve()
    if destination is None:
        destination = output_dir / _static_report_filename(module)
    destination = destination.resolve()
    destination.parent.mkdir(parents=True, exist_ok=True)
    print("STATIC_INTERACTIVE_STAGE\tDiscovering result tables", flush=True)
    state = StudioState(module, output_dir, 7200)

    # Prefer the user-facing Excel workbook. It already groups the scientifically
    # relevant result tables and avoids embedding duplicate technical TSV files.
    workbook_sources = [
        source for source in state.tables
        if source.origin == "result"
        and source.path.parent == output_dir
        and source.path.suffix.lower() in {".xlsx", ".xlsm"}
    ]
    sources = workbook_sources or [source for source in state.tables if source.origin == "result"]
    if module == "enrichment":
        enrichment_sheet = [s for s in sources if str(s.sheet_name or "").casefold() == "enrichment results"]
        if enrichment_sheet:
            sources = enrichment_sheet[:1]
    elif module == "combined" and workbook_sources:
        combined_sheets = {name.casefold() for name in PREFERRED_WORKBOOK_SHEETS["combined"]}
        selected = [s for s in sources if str(s.sheet_name or "").casefold() in combined_sheets]
        if selected:
            order = {name.casefold(): index for index, name in enumerate(PREFERRED_WORKBOOK_SHEETS["combined"])}
            sources = sorted(selected, key=lambda source: order.get(str(source.sheet_name or "").casefold(), len(order)))
    elif module == "network" and workbook_sources:
        network_sheets = {name.casefold() for name in PREFERRED_WORKBOOK_SHEETS["network"]}
        selected = [s for s in sources if str(s.sheet_name or "").casefold() in network_sheets]
        if selected:
            sources = selected

    print(f"STATIC_INTERACTIVE_STAGE\tPreparing shared annotation ({len(sources)} table source(s))", flush=True)
    de_annotation_frames = _read_de_annotation_frames(output_dir, sources, max_rows) if module == "de" else []

    meta: list[dict[str, Any]] = []
    tables: dict[str, dict[str, Any]] = {}
    for source_index, source in enumerate(sources, start=1):
        print(f"STATIC_INTERACTIVE_STAGE\tLoading table {source_index}/{len(sources)}: {source.sheet_name or source.path.name}", flush=True)
        try:
            # For DE, coordinates/strand are resolved once through annotation_frames
            # below. Do not rerun coordinate discovery for every Excel worksheet.
            frame = read_delimited(source.path, max_rows + 1, source.sheet_name, merge_coordinates=(module != "de"))
        except Exception as exc:
            print(f"STATIC REPORT WARNING: could not read {source.label}: {exc}", file=sys.stderr)
            continue
        truncated = len(frame) > max_rows
        if truncated:
            frame = frame.iloc[:max_rows].copy()
        if module == "de":
            sheet_key = str(source.sheet_name or "").casefold()
            if sheet_key in {"differential expression", "significant genes", "all contrasts", "all contrast rows"} or sheet_key.startswith("de "):
                frame = _merge_de_annotations(frame, de_annotation_frames)
        columns = []
        for column_name in frame.columns:
            series = frame[column_name]
            numeric_values = pd.to_numeric(series, errors="coerce")
            numeric_fraction = float(numeric_values.notna().mean()) if len(series) else 0.0
            columns.append({
                "name": str(column_name),
                "kind": "numeric" if numeric_fraction >= 0.75 else "categorical",
                "unique": int(series.nunique(dropna=True)),
            })
        rows = [
            {str(column_name): clean_json_value(value) for column_name, value in row.items()}
            for row in frame.to_dict(orient="records")
        ]
        entry = {
            "key": source.key,
            "label": source.label,
            "origin": source.origin,
            "filename": source.path.name,
            "sheet_name": source.sheet_name,
            "columns": columns,
            "rows": rows,
            "truncated": truncated,
        }
        meta.append({key: entry[key] for key in ("key", "label", "origin", "filename", "sheet_name", "columns")})
        tables[source.key] = entry

    if not meta:
        raise RuntimeError(
            f"No tabular result files were found in {output_dir}. "
            "The interactive HTML is built after the user-facing Excel workbook is finalized; "
            "check the result folder and re-run report generation."
        )

    analysis_source_dir = Path(__file__).resolve().parents[1] / "R"
    if module == "combined":
        analysis_source_parts = []
        for source_name in ("enrichment_analysis.R", "network_analysis.R"):
            try:
                analysis_source_parts.append((analysis_source_dir / source_name).read_text(encoding="utf-8-sig"))
            except Exception:
                continue
        analysis_source = "\n\n# ---- Co-expression analysis ----\n\n".join(analysis_source_parts)
    else:
        analysis_source_path = analysis_source_dir / {"de": "de_analysis.R", "enrichment": "enrichment_analysis.R", "network": "network_analysis.R"}[module]
        try:
            analysis_source = analysis_source_path.read_text(encoding="utf-8-sig")
        except Exception:
            analysis_source = ""
    print("STATIC_INTERACTIVE_STAGE\tSerializing interactive data", flush=True)
    payload = json.dumps({"meta": meta, "tables": tables, "analysis_source": analysis_source, "member_annotations": state.member_annotations}, ensure_ascii=False, separators=(",", ":"))
    # Avoid terminating the script element if a result string happens to contain it.
    payload = payload.replace("</", "<\\/")
    print("STATIC_INTERACTIVE_STAGE\tEmbedding Plotly runtime", flush=True)
    plotly_js = py_offline.get_plotlyjs()

    offline_bootstrap = f'''<script>
window.__OFFLINE_STUDIO_DATA__ = {payload};
window.fetch = async function(input, init) {{
  const url = String(input || '');
  const store = window.__OFFLINE_STUDIO_DATA__;
  if (url.startsWith('/api/meta')) {{
    return {{ok:true, status:200, json:async()=>({{tables:store.meta,member_annotations:store.member_annotations||{{}}}})}};
  }}
  if (url.startsWith('/api/table')) {{
    const query = url.includes('?') ? url.split('?',2)[1] : '';
    const params = new URLSearchParams(query);
    const key = params.get('key') || '';
    const requested = Math.max(1, Number(params.get('limit') || 50000));
    const source = store.tables[key];
    if (!source) return {{ok:false,status:404,json:async()=>({{error:'Table not found in this offline report.'}})}};
    const rows = source.rows.slice(0, requested);
    return {{ok:true,status:200,json:async()=>({{...source,rows,truncated:source.truncated || rows.length < source.rows.length}})}};
  }}
  if (url.startsWith('/api/export')) {{
    return {{ok:false,status:409,json:async()=>({{error:'This is an offline report. Use the Export control above the plot or the Publication-quality export panel. SVG is available for unlimited enlargement.'}})}};
  }}
  if (url.startsWith('/api/shutdown')) {{
    return {{ok:true,status:200,json:async()=>({{status:'offline'}})}};
  }}
  return {{ok:false,status:404,json:async()=>({{error:'Offline report resource not found.'}})}};
}};
window.addEventListener('DOMContentLoaded', () => {{
  const status = document.getElementById('serverStatus');
  if (status) status.remove();
  const stop = document.getElementById('stopServer');
  if (stop) stop.style.display = 'none';
  const pdfOption = document.querySelector('#exportFormat option[value="pdf"]');
  if (pdfOption) {{ pdfOption.textContent = 'PDF · publication page'; pdfOption.disabled = false; }}
  const exportStatus = document.getElementById('exportStatus');
  if (exportStatus) exportStatus.textContent = 'Offline export is enabled. PDF embeds a high-resolution plot on the selected page; SVG remains the unlimited-zoom vector format.';
}});
</script>'''

    companion = _companion_analysis_html(module, output_dir)
    body = HTML_TEMPLATE.replace("__MODULE__", module).replace("__TITLE__", "")
    specialized_workspace = module in {"de", "enrichment", "network", "combined"}
    body = body.replace("__SECTION_ONE_TITLE__", "1. Analysis / visualization" if specialized_workspace else "1. Data")
    body = body.replace("__SECTION_ONE_EXTRA__", companion if specialized_workspace else "")
    body = body.replace("__COMPANION_ANALYSES_TOP__", "" if specialized_workspace else companion)
    body = body.replace('Local and private', 'Offline interactive HTML')
    body = body.replace('<script src="/plotly.min.js"></script>', f'<script>{plotly_js}</script>\n{offline_bootstrap}')
    title = MODULE_TITLES[module]
    document = (
        '<!doctype html><html lang="en"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        f'<title>{title}</title></head><body>{body}</body></html>'
    )
    destination.parent.mkdir(parents=True, exist_ok=True)
    print(f"STATIC_INTERACTIVE_STAGE\tWriting HTML ({len(document) / 1_000_000:.1f} MB)", flush=True)
    destination.write_text(document, encoding="utf-8")
    print(f"STATIC_INTERACTIVE_REPORT\t{destination}")
    print(f"STATIC_INTERACTIVE_TABLES\t{len(meta)}")
    return destination


def build_combined_static_report(
    output_dir: Path,
    destination: Path | None = None,
    max_rows: int = 50_000,
) -> Path:
    """Build one unified studio for enrichment and co-expression results.

    The combined report uses one section-1 dropdown, one plot viewport and one
    linked spreadsheet.  It deliberately avoids nested full-report iframes and
    the former Functional-enrichment / Co-expression mode tabs.
    """
    print("COMBINED_INTERACTIVE_STAGE\tBuilding unified specialized-analysis workspace", flush=True)
    result = build_static_report("combined", output_dir, destination, max_rows=max_rows)
    print(f"COMBINED_STATIC_INTERACTIVE_REPORT\t{result}")
    return result

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build an offline interactive report or launch the legacy local visualization studio.")
    parser.add_argument("--module", choices=sorted(MODULE_TITLES), required=True)
    parser.add_argument("--output", required=True, help="Completed result directory.")
    parser.add_argument("--ready-file", help="Legacy server mode: file that receives the local URL after startup.")
    parser.add_argument("--build-static", nargs="?", const="AUTO", help="Build one self-contained offline HTML report and exit. Optional destination path.")
    parser.add_argument("--max-static-rows", type=int, default=50000, help="Maximum rows embedded per result table in the offline HTML.")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--idle-seconds", type=int, default=7200)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    output_dir = Path(args.output)
    if not output_dir.is_dir():
        print(f"ERROR: Result directory does not exist: {output_dir}", file=sys.stderr)
        return 2
    if args.build_static is not None:
        destination = None if args.build_static == "AUTO" else Path(args.build_static)
        max_rows = max(100, min(args.max_static_rows, MAX_ROWS_HARD))
        if args.module == "combined":
            build_combined_static_report(output_dir, destination, max_rows=max_rows)
        else:
            build_static_report(args.module, output_dir, destination, max_rows=max_rows)
        return 0
    if args.module == "combined":
        print("ERROR: The combined workspace is available as a self-contained offline HTML report only.", file=sys.stderr)
        return 2
    if not args.ready_file:
        print("ERROR: --ready-file is required in legacy server mode.", file=sys.stderr)
        return 2
    state = StudioState(args.module, output_dir, args.idle_seconds)

    # Keep startup logging compact. Earlier builds dumped this entire source
    # file before binding the local server, which could create very large logs
    # and trigger the Windows startup timeout on mounted drives.
    source_path = Path(__file__).resolve()
    print(f"Visualization studio source: {source_path}", flush=True)
    print(f"Visualization studio version: {APP_VERSION}", flush=True)
    print(f"Launch module: {args.module}", flush=True)
    print(f"Launch output: {output_dir.resolve()}", flush=True)

    server = ThreadingHTTPServer((args.host, args.port), StudioHandler)
    server.state = state  # type: ignore[attr-defined]
    state.server = server
    host, port = server.server_address[:2]
    url = f"http://{host}:{port}/"
    ready_path = Path(args.ready_file)
    ready_path.parent.mkdir(parents=True, exist_ok=True)
    ready_path.write_text(url, encoding="utf-8")
    print(f"Visualization studio {APP_VERSION}", flush=True)
    print(f"Module: {args.module}", flush=True)
    print(f"Results: {output_dir.resolve()}", flush=True)
    print(f"URL: {url}", flush=True)
    print(f"Tables: {len(state.tables)}", flush=True)
    threading.Thread(target=idle_watcher, args=(state,), daemon=True).start()

    def stop_handler(_signum: int, _frame: Any) -> None:
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop_handler)
    signal.signal(signal.SIGINT, stop_handler)
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        server.server_close()
        try:
            ready_path.unlink(missing_ok=True)
        except Exception:
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
