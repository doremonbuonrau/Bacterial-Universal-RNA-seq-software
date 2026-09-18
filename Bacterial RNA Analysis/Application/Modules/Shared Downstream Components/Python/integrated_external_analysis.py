#!/usr/bin/env python3
"""Run pathway enrichment and STRING PPI inside the combined functional job.

The existing enrichment step creates the exact selected-gene and universe files
used here.  Each online analysis works in a technical subdirectory so its
generic filenames cannot overwrite the co-expression results.  Curated tables
and figures are copied back with unique names for the one workbook/report.
"""
from __future__ import annotations

import argparse
import csv
import importlib.util
import json
import re
import shutil
import sys
from pathlib import Path
from typing import Any


def load_config(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8-sig"))
    if not isinstance(value, dict):
        raise ValueError("The combined-analysis configuration must be a JSON object.")
    return value


def as_bool(value: object) -> bool:
    return value is True or str(value or "").strip().casefold() in {"1", "true", "yes", "on"}


def advanced_options(config: dict[str, Any], key: str) -> dict[str, Any]:
    """Return validated GUI overrides for one integrated online function."""
    container = config.get("advanced_package_options")
    if not isinstance(container, dict):
        return {}
    raw = container.get(key)
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, str) and raw.strip():
        try:
            parsed = json.loads(raw)
        except json.JSONDecodeError:
            return {}
        return parsed if isinstance(parsed, dict) else {}
    return {}


def wsl_compatible_path(value: object) -> str | None:
    """Accept either a native WSL path or a Windows drive path from the GUI."""
    text = str(value or "").strip()
    if not text:
        return None
    match = re.match(r"^([A-Za-z]):[\\/](.*)$", text)
    if match:
        tail = match.group(2).replace("\\", "/")
        return f"/mnt/{match.group(1).lower()}/{tail}"
    return text


def load_backend():
    modules_root = Path(__file__).resolve().parents[2]
    backend_path = modules_root / "Scientific Expansion" / "Backend" / "scientific_expansion.py"
    if not backend_path.is_file():
        raise FileNotFoundError(f"Scientific expansion backend not found: {backend_path}")
    spec = importlib.util.spec_from_file_location("bra_integrated_scientific_expansion", backend_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Could not load {backend_path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def copy_if_present(source: Path, destination: Path) -> bool:
    if not source.is_file():
        return False
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
    return True


def copy_interactive_figures(source_root: Path, output_root: Path, prefix: str) -> list[str]:
    copied: list[str] = []
    seen: set[Path] = set()
    for folder in (source_root, source_root / "Figures"):
        if not folder.is_dir():
            continue
        for source in sorted(folder.glob("*_interactive.html")):
            resolved = source.resolve()
            if resolved in seen:
                continue
            seen.add(resolved)
            destination = output_root / f"{prefix}_{source.name}"
            shutil.copy2(source, destination)
            copied.append(destination.name)
    return copied


def status_row(module: str, enabled: bool, status: str, message: str, result: dict[str, object] | None = None) -> dict[str, object]:
    result = result or {}
    return {
        "module": module,
        "enabled": "yes" if enabled else "no",
        "status": status,
        "message": " ".join(str(message or "").splitlines()),
        "organism": result.get("organism", ""),
        "result_count": result.get("terms", result.get("STRING_edges", "")),
        "interactive_figures": "",
    }


def write_tsv(path: Path, rows: list[dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fields = list(dict.fromkeys(key for row in rows for key in row)) or ["module", "status", "message"]
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, delimiter="\t", extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def remove_standalone_products(root: Path) -> None:
    for pattern in ("*.xlsx", "* interactive.html", "*_interactive.html", "*.graphml"):
        for path in root.glob(pattern):
            if path.is_file():
                path.unlink()


def run(config_path: Path) -> dict[str, object]:
    config = load_config(config_path)
    output_root = Path(str(config["output_dir"])).resolve()
    output_root.mkdir(parents=True, exist_ok=True)
    selected = output_root / "selected_genes_used.tsv"
    universe = output_root / "gene_universe_used.tsv"
    if not selected.is_file() or not universe.is_file():
        raise FileNotFoundError(
            "Integrated pathway/STRING analysis requires selected_genes_used.tsv and "
            "gene_universe_used.tsv from the functional-enrichment stage."
        )

    technical_root = output_root / "Intermediate files" / "Integrated database runs"
    technical_root.mkdir(parents=True, exist_ok=True)
    statuses: list[dict[str, object]] = []

    if as_bool(config.get("kegg_map_enabled", False)):
        try:
            from kegg_pathway_maps import run as run_pathway_maps
            map_result = run_pathway_maps(config)
            available = len(map_result["pathways"])
            map_status = "complete" if available and not map_result["warnings"] else "complete_with_warnings" if available else "unavailable"
            statuses.append(status_row("KEGG expression maps", True, map_status,
                                       f"{available} native pathway diagrams; see KEGG map summary and mapping audit.",
                                       {"organism": config.get("integrated_kegg_organism", ""), "terms": available}))
            statuses[-1]["interactive_figures"] = "Figures/kegg_pathway_maps_interactive.html"
        except Exception as exc:
            # Do not let a previous successful figure masquerade as this run.
            (output_root / "Figures" / "kegg_pathway_maps_interactive.html").unlink(missing_ok=True)
            for filename in ("kegg_map_summary.tsv", "kegg_map_genes.tsv", "kegg_map_audit.tsv", "kegg_map_nodes.tsv"):
                (output_root / filename).unlink(missing_ok=True)
            statuses.append(status_row("KEGG expression maps", True, "failed", str(exc)))
            print(f"WARNING: KEGG expression mapping failed: {exc}", file=sys.stderr, flush=True)

    pathway_enabled = as_bool(config.get("integrated_pathway_enabled", False))
    string_enabled = as_bool(config.get("integrated_string_enabled", False))
    backend = None
    backend_error = ""
    if pathway_enabled or string_enabled:
        try:
            backend = load_backend()
        except Exception as exc:
            backend_error = f"Scientific Expansion backend could not be loaded: {exc}"
            print(f"WARNING: {backend_error}", file=sys.stderr, flush=True)

    pathway_root = technical_root / "Pathway"
    pathway_root.mkdir(parents=True, exist_ok=True)
    if pathway_enabled:
        options = advanced_options(config, "integrated_kegg_pathway")
        kegg_enabled = as_bool(config.get("integrated_kegg_enabled", bool(config.get("integrated_kegg_organism"))))
        query = str(options.get("organism", config.get("integrated_kegg_organism")) or "").strip() if kegg_enabled else ""
        term2gene = wsl_compatible_path(config.get("integrated_pathway_term2gene"))
        biocyc_mapping = wsl_compatible_path(config.get("integrated_pathway_biocyc_mapping"))
        metacyc_mapping = wsl_compatible_path(config.get("integrated_pathway_metacyc_mapping"))
        # The guided combined workflow permanently enables the acknowledgement
        # internally; there is no longer a user-facing checkbox that can block
        # the coordinated KEGG/STRING run.
        confirmed = True
        try:
            if backend is None:
                raise RuntimeError(backend_error or "Scientific Expansion backend is unavailable.")
            result = backend.pathway(argparse.Namespace(
                gene_list=str(selected), gene_column="gene_id",
                universe=str(universe), universe_column="gene_id",
                term2gene=term2gene, biocyc_mapping=biocyc_mapping, metacyc_mapping=metacyc_mapping,
                kegg_organism=query, kegg_confirmed=confirmed,
                output_dir=str(pathway_root), skip_standalone_report=True,
            ))
            figures = copy_interactive_figures(pathway_root, output_root, "pathway")
            copy_if_present(pathway_root / "enrichment_results.tsv", output_root / "pathway_enrichment_results.tsv")
            copy_if_present(pathway_root / "Intermediate files" / "Pathway annotation cache" / "TERM2GENE.tsv", output_root / "pathway_gene_mapping.tsv")
            sources = [name for name, value in (("KEGG", query), ("custom TERM2GENE", term2gene), ("BioCyc", biocyc_mapping), ("MetaCyc", metacyc_mapping)) if value]
            row = status_row("Pathway database enrichment", True, "complete", f"Completed with {', '.join(sources)}.", result)
            row["interactive_figures"] = "; ".join(figures)
            statuses.append(row)
            print(f"INTEGRATED PATHWAY\tcomplete\t{len(figures)} interactive figure(s)", flush=True)
        except Exception as exc:
            statuses.append(status_row("Pathway database enrichment", True, "error", str(exc)))
            print(f"WARNING: Integrated pathway analysis could not complete: {exc}", file=sys.stderr, flush=True)
    else:
        statuses.append(status_row("Pathway database enrichment", False, "not requested", "No KEGG, TERM2GENE, BioCyc, or MetaCyc source was requested."))
    remove_standalone_products(pathway_root)

    string_root = technical_root / "STRING PPI"
    string_root.mkdir(parents=True, exist_ok=True)
    if string_enabled:
        options = advanced_options(config, "integrated_string_network")
        taxid = int(options.get("taxid", config.get("integrated_string_taxid")) or 0)
        network_type = str(options.get("network_type", config.get("integrated_string_network_type")) or "physical").strip().casefold()
        required_score = int(options.get("required_score", config.get("integrated_string_required_score")) or 700)
        add_nodes = int(options.get("add_nodes", config.get("integrated_string_add_nodes")) or 0)
        alias_value = options["identifier_aliases"] if "identifier_aliases" in options else config.get("integrated_string_identifier_aliases")
        aliases = wsl_compatible_path(alias_value)
        try:
            if backend is None:
                raise RuntimeError(backend_error or "Scientific Expansion backend is unavailable.")
            expression_edges = output_root / "network_edges.tsv"
            result = backend.string_network(argparse.Namespace(
                gene_list=str(selected), gene_column="gene_id", identifier_aliases=aliases,
                expression_edges=str(expression_edges) if expression_edges.is_file() else None,
                taxid=taxid,
                network_type=network_type,
                required_score=required_score,
                add_nodes=add_nodes,
                output_dir=str(string_root), skip_standalone_report=True,
            ))
            figures = copy_interactive_figures(string_root, output_root, "string_ppi")
            copy_if_present(string_root / "network_edges.tsv", output_root / "string_ppi_edges.tsv")
            copy_if_present(string_root / "network_nodes.tsv", output_root / "string_ppi_nodes.tsv")
            copy_if_present(string_root / "Intermediate files" / "STRING identifier mapping.tsv", output_root / "string_identifier_mapping.tsv")
            copy_if_present(string_root / "Intermediate files" / "STRING unmapped identifiers.tsv", output_root / "string_unmapped_identifiers.tsv")
            row = status_row("STRING PPI", True, "complete", f"Completed for taxonomy ID {taxid}.", result)
            row["interactive_figures"] = "; ".join(figures)
            statuses.append(row)
            print(f"INTEGRATED STRING PPI\tcomplete\t{len(figures)} interactive figure(s)", flush=True)
        except Exception as exc:
            # Preserve mapping diagnostics even when no STRING protein resolves.
            copy_if_present(string_root / "Intermediate files" / "STRING identifier mapping.tsv", output_root / "string_identifier_mapping.tsv")
            copy_if_present(string_root / "Intermediate files" / "STRING unmapped identifiers.tsv", output_root / "string_unmapped_identifiers.tsv")
            statuses.append(status_row("STRING PPI", True, "error", str(exc)))
            print(f"WARNING: Integrated STRING PPI could not complete: {exc}", file=sys.stderr, flush=True)
    else:
        statuses.append(status_row("STRING PPI", False, "not requested", "Disabled in the combined-run settings."))
    remove_standalone_products(string_root)

    status_path = output_root / "integrated_database_status.tsv"
    write_tsv(status_path, statuses)
    summary = {
        "status": "complete" if all(row["status"] in {"complete", "not requested"} for row in statuses) else "complete_with_warnings",
        "modules": statuses,
    }
    (output_root / "integrated_external_summary.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description="Run pathway and STRING inside one combined functional analysis")
    parser.add_argument("config")
    args = parser.parse_args()
    result = run(Path(args.config).resolve())
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
