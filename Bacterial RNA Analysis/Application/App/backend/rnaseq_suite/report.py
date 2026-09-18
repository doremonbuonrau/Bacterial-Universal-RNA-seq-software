from __future__ import annotations

import base64
import html
import mimetypes
import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

from .parsers import sha256_file


def _escape(value: object) -> str:
    return html.escape(str(value), quote=True)


def _human_size(size: int) -> str:
    units = ["B", "KiB", "MiB", "GiB", "TiB"]
    value = float(size)
    for unit in units:
        if value < 1024 or unit == units[-1]:
            return f"{value:.1f} {unit}" if unit != "B" else f"{int(value)} B"
        value /= 1024
    return f"{size} B"


def write_checksums(analysis_ready: Path) -> Path:
    checksum_path = analysis_ready / "Intermediate files" / "Checksums.sha256"
    temporary = checksum_path.with_name(".Checksums.sha256.tmp")
    checksum_path.parent.mkdir(parents=True, exist_ok=True)
    files = sorted(
        path
        for path in analysis_ready.rglob("*")
        if path.is_file() and path not in {checksum_path, temporary}
    )
    with temporary.open("w", encoding="utf-8", newline="\n") as handle:
        for path in files:
            relative = path.relative_to(analysis_ready).as_posix()
            handle.write(f"{sha256_file(path)}  {relative}\n")
    os.replace(temporary, checksum_path)
    return checksum_path


def refresh_checksum_entries(analysis_ready: Path, paths: Iterable[Path]) -> Path:
    """Refresh selected entries without rehashing large unchanged BAM files."""

    checksum_path = analysis_ready / "Intermediate files" / "Checksums.sha256"
    if not checksum_path.is_file():
        raise RuntimeError(f"Checksum manifest is missing: {checksum_path}")
    checksum_path.parent.mkdir(parents=True, exist_ok=True)
    entries: dict[str, str] = {}
    for line in checksum_path.read_text(encoding="utf-8", errors="replace").splitlines():
        digest, separator, relative = line.partition("  ")
        if separator and digest and relative:
            entries[relative] = digest
    root = analysis_ready.resolve()
    for path in paths:
        resolved = path.resolve()
        try:
            relative = resolved.relative_to(root).as_posix()
        except ValueError as exc:
            raise RuntimeError(f"Refusing to checksum a path outside the export: {path}") from exc
        if not resolved.is_file():
            raise RuntimeError(f"Cannot refresh checksum for a missing file: {path}")
        entries[relative] = sha256_file(resolved)

    temporary = checksum_path.with_name(".Checksums.sha256.tmp")
    with temporary.open("w", encoding="utf-8", newline="\n") as handle:
        for relative in sorted(entries):
            handle.write(f"{entries[relative]}  {relative}\n")
    os.replace(temporary, checksum_path)
    return checksum_path



def _qc_safe_id(value: str) -> str:
    cleaned = "".join(ch if ch.isalnum() else "-" for ch in value.lower()).strip("-")
    return cleaned or "section"


def _qc_text_preview(path: Path, max_chars: int = 250_000) -> str:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        return f"Unable to read {path.name}: {exc}"
    if len(text) > max_chars:
        return text[:max_chars] + "\n\n[Preview truncated; the complete source is retained under intermediate/QC.]"
    return text


def _qc_data_uri(path: Path) -> str:
    mime = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
    encoded = base64.b64encode(path.read_bytes()).decode("ascii")
    return f"data:{mime};base64,{encoded}"


def _qc_embed_html(path: Path) -> str:
    try:
        source = path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        return f"<p class='error'>Unable to read {_escape(path.name)}: {_escape(exc)}</p>"
    return (
        "<iframe class='embedded-report' loading='lazy' sandbox='allow-scripts allow-same-origin' "
        f"srcdoc=\"{html.escape(source, quote=True)}\"></iframe>"
    )


def _qc_render_file(path: Path, qc_root: Path) -> str:
    relative = path.relative_to(qc_root).as_posix()
    suffix = path.suffix.lower()
    title = _escape(relative)
    size = _human_size(path.stat().st_size)
    if suffix in {".html", ".htm"}:
        return f"<section class='report-item'><h3>{title}</h3><p class='meta'>{size}</p>{_qc_embed_html(path)}</section>"
    if suffix in {".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp"}:
        try:
            uri = _qc_data_uri(path)
            return f"<section class='report-item'><h3>{title}</h3><p class='meta'>{size}</p><img class='qc-image' src='{uri}' alt='{title}'></section>"
        except OSError as exc:
            return f"<section class='report-item'><h3>{title}</h3><p class='error'>{_escape(exc)}</p></section>"
    if suffix == ".pdf":
        try:
            uri = _qc_data_uri(path)
            return f"<section class='report-item'><h3>{title}</h3><p class='meta'>{size}</p><embed class='qc-pdf' type='application/pdf' src='{uri}'></section>"
        except OSError as exc:
            return f"<section class='report-item'><h3>{title}</h3><p class='error'>{_escape(exc)}</p></section>"
    if suffix in {".txt", ".tsv", ".csv", ".json", ".yaml", ".yml", ".log"}:
        preview = _escape(_qc_text_preview(path))
        return (
            f"<details class='source-detail'><summary>{title} <span class='meta'>{size}</span></summary>"
            f"<pre>{preview}</pre></details>"
        )
    return ""


def generate_qc_report(
    qc_root: Path,
    report_path: Path,
    *,
    project_name: str,
    analysis_type: str,
    alignment_summary: list[dict[str, object]],
    strand_summary: list[dict[str, object]],
    warnings: Iterable[str],
) -> Path:
    """Create one standalone QC dashboard containing all generated QC reports."""
    qc_root.mkdir(parents=True, exist_ok=True)
    report_path.parent.mkdir(parents=True, exist_ok=True)

    alignment_rows = "".join(
        "<tr>"
        f"<td>{_escape(row.get('sample_id', ''))}</td>"
        f"<td>{_escape(row.get('modality', ''))}</td>"
        f"<td>{_escape(row.get('role', ''))}</td>"
        f"<td>{_escape(row.get('aligner', ''))}</td>"
        f"<td>{_escape(row.get('primary_records', ''))}</td>"
        f"<td>{_escape(row.get('mapped_primary_records', ''))}</td>"
        f"<td>{_escape(row.get('mapped_percent', ''))}</td>"
        "</tr>" for row in alignment_summary
    ) or "<tr><td colspan='7'>No alignment summary was available.</td></tr>"
    strand_rows = "".join(
        "<tr>"
        f"<td>{_escape(row.get('sample_id', ''))}</td>"
        f"<td>{_escape(row.get('modality', ''))}</td>"
        f"<td>{_escape(row.get('declared', ''))}</td>"
        f"<td>{_escape(row.get('inferred', ''))}</td>"
        f"<td>{_escape(row.get('effective', ''))}</td>"
        f"<td>{_escape(row.get('forward_assigned', ''))}</td>"
        f"<td>{_escape(row.get('reverse_assigned', ''))}</td>"
        f"<td>{_escape(row.get('status', ''))}</td>"
        "</tr>" for row in strand_summary
    ) or "<tr><td colspan='8'>No strand audit summary was available.</td></tr>"
    warning_items = "".join(f"<li>{_escape(item)}</li>" for item in warnings) or "<li>No pipeline warnings were recorded.</li>"

    friendly = {
        "multiqc": "MultiQC",
        "short": "Short Read QC",
        "fastp": "fastp",
        "long": "Long Read QC",
        "alignment": "Alignment QC",
        "strand_audit": "Strand Audit",
    }
    preferred = ["multiqc", "short", "fastp", "long", "alignment", "strand_audit"]
    children = {item.name: item for item in qc_root.iterdir() if item.is_dir()}
    order = [name for name in preferred if name in children]
    order.extend(sorted(name for name in children if name not in order))
    supported = {".html", ".htm", ".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp", ".pdf", ".txt", ".tsv", ".csv", ".json", ".yaml", ".yml", ".log"}
    nav: list[str] = []
    sections: list[str] = []
    for name in order:
        directory = children[name]
        rendered = []
        for path in sorted(directory.rglob("*")):
            if path.is_file() and not path.name.startswith(".") and path.suffix.lower() in supported:
                value = _qc_render_file(path, qc_root)
                if value:
                    rendered.append(value)
        if not rendered:
            continue
        title = friendly.get(name, name.replace("_", " ").title())
        section_id = _qc_safe_id(title)
        nav.append(f"<a href='#{section_id}'>{_escape(title)}</a>")
        sections.append(f"<section class='card tool-section' id='{section_id}'><h2>{_escape(title)}</h2>{''.join(rendered)}</section>")
    if not sections:
        sections.append("<section class='card'><h2>QC source reports</h2><p>No QC source reports were generated for this run.</p></section>")

    created = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    document = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>{_escape(project_name)} - QC Analysis</title>
<style>
:root{{--green:#417a4b;--dark:#2a5534;--soft:#e6f2e8;--ink:#1e2a22;--muted:#58655d;--border:#cddad0;--blue:#377497}}
*{{box-sizing:border-box}}html{{scroll-behavior:smooth}}body{{margin:0;background:#f5f8f6;color:var(--ink);font:15px/1.5 "Segoe UI",Arial,sans-serif}}
header{{background:white;border-bottom:1px solid var(--border);padding:26px 5vw 20px}}header h1{{margin:0;color:var(--dark)}}header p{{margin:6px 0;color:var(--muted)}}
nav{{position:sticky;top:0;z-index:20;background:#fffffff2;border-bottom:1px solid var(--border);padding:10px 5vw;display:flex;gap:9px;flex-wrap:wrap}}nav a{{text-decoration:none;color:var(--dark);background:var(--soft);padding:6px 10px;border-radius:999px;font-weight:600}}
main{{max-width:1320px;margin:22px auto;padding:0 20px 50px}}.grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(310px,1fr));gap:16px}}.card{{background:white;border:1px solid var(--border);border-radius:12px;padding:18px;margin-bottom:18px;box-shadow:0 3px 14px #1f2b240c}}
h2{{color:var(--dark);margin:0 0 12px;font-size:21px}}h3{{margin:18px 0 6px;font-size:16px}}table{{width:100%;border-collapse:collapse;font-size:13px}}th,td{{border-bottom:1px solid #e8eeea;text-align:left;padding:7px;vertical-align:top}}th{{background:#f2f7f3;color:var(--dark)}}.scroll{{overflow:auto;max-height:430px;border:1px solid var(--border);border-radius:8px}}
.meta{{color:var(--muted);font-size:12px}}.note{{border-left:4px solid var(--blue);padding:10px 14px;background:#e8f2f8}}.error{{color:#9b2c2c}}.report-item{{border-top:1px solid #edf1ee;padding-top:10px;margin-top:16px}}.embedded-report{{width:100%;height:760px;border:1px solid var(--border);border-radius:8px;background:white}}.qc-image{{display:block;max-width:100%;height:auto;margin:8px auto;border:1px solid #edf1ee;border-radius:8px}}.qc-pdf{{width:100%;height:760px;border:1px solid var(--border)}}details.source-detail{{border:1px solid var(--border);border-radius:8px;padding:9px 12px;margin:10px 0;background:#fbfdfb}}details summary{{cursor:pointer;font-weight:600;color:var(--dark)}}pre{{white-space:pre-wrap;overflow:auto;max-height:520px;background:#f4f7f5;border-radius:6px;padding:10px;font:12px/1.45 Consolas,monospace}}footer{{text-align:center;color:var(--muted);padding:20px}}
</style></head><body>
<header><h1>QC Analysis</h1><p>{_escape(project_name)} · {_escape(analysis_type)} reads · generated {created}</p><p>FastQC, cleaning/basecalling QC, alignment QC, strand audit and MultiQC are combined here. Original machine-readable files are retained under <code>intermediate/QC/</code>.</p></header>
<nav><a href='#overview'>Overview</a>{''.join(nav)}</nav><main>
<section class='card' id='overview'><h2>QC overview</h2><div class='grid'><div><h3>Alignment</h3><div class='scroll'><table><thead><tr><th>Sample</th><th>Read type</th><th>Role</th><th>Aligner</th><th>Primary</th><th>Mapped</th><th>Mapped %</th></tr></thead><tbody>{alignment_rows}</tbody></table></div></div><div><h3>Strand audit</h3><div class='scroll'><table><thead><tr><th>Sample</th><th>Read type</th><th>Declared</th><th>Inferred</th><th>Effective</th><th>Forward</th><th>Reverse</th><th>Status</th></tr></thead><tbody>{strand_rows}</tbody></table></div></div></div><h3>Warnings and interpretation notes</h3><ul>{warning_items}</ul><p class='note'>This file is the user-facing QC dashboard. The original QC source files remain available for reproducibility but are intentionally kept out of the result root.</p></section>
{''.join(sections)}</main><footer>Bacterial RNA Analysis · combined QC dashboard</footer></body></html>"""
    report_path.write_text(document, encoding="utf-8")
    return report_path

def generate_html_report(
    analysis_ready: Path,
    config: dict[str, Any],
    *,
    warnings: Iterable[str],
    annotation_summary: dict[str, object] | None,
    alignment_summary: list[dict[str, object]],
    strand_summary: list[dict[str, object]],
    status: str = "complete",
) -> Path:
    report_path = analysis_ready / "Intermediate files" / "Analysis Ready Report.html"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    project = config.get("project", {})
    methods = config.get("methods", {})
    samples = [sample for sample in config.get("samples", []) if sample.get("include", True)]

    sample_rows = "".join(
        "<tr>"
        f"<td>{_escape(sample.get('sample_id', ''))}</td>"
        f"<td>{_escape(sample.get('condition', ''))}</td>"
        f"<td>{_escape(sample.get('replicate', ''))}</td>"
        f"<td>{'Yes' if sample.get('short_r1') else 'No'}</td>"
        f"<td>{'Yes' if sample.get('long_reads') or sample.get('pod5_dir') else 'No'}</td>"
        "</tr>"
        for sample in samples
    )

    method_rows = "".join(
        f"<tr><td>{_escape(key.replace('_', ' ').title())}</td><td>{_escape(value)}</td></tr>"
        for key, value in sorted(methods.items())
        if not key.startswith("adapter_")
    )

    alignment_rows = "".join(
        "<tr>"
        f"<td>{_escape(row.get('sample_id', ''))}</td>"
        f"<td>{_escape(row.get('modality', ''))}</td>"
        f"<td>{_escape(row.get('role', ''))}</td>"
        f"<td>{_escape(row.get('aligner', ''))}</td>"
        f"<td>{_escape(row.get('primary_records', ''))}</td>"
        f"<td>{_escape(row.get('mapped_primary_records', ''))}</td>"
        f"<td>{_escape(row.get('mapped_percent', ''))}</td>"
        "</tr>"
        for row in alignment_summary
    ) or "<tr><td colspan='7'>Alignment summary is available after a real run.</td></tr>"

    strand_rows = "".join(
        "<tr>"
        f"<td>{_escape(row.get('sample_id', ''))}</td>"
        f"<td>{_escape(row.get('modality', ''))}</td>"
        f"<td>{_escape(row.get('declared', ''))}</td>"
        f"<td>{_escape(row.get('inferred', ''))}</td>"
        f"<td>{_escape(row.get('forward_assigned', ''))}</td>"
        f"<td>{_escape(row.get('reverse_assigned', ''))}</td>"
        f"<td>{_escape(row.get('status', ''))}</td>"
        "</tr>"
        for row in strand_summary
    ) or "<tr><td colspan='7'>Strand audit is available after a real run.</td></tr>"

    warning_items = "".join(f"<li>{_escape(item)}</li>" for item in warnings)
    if not warning_items:
        warning_items = "<li>No configuration warnings were recorded.</li>"

    annotation_text = "Not generated"
    if annotation_summary:
        annotation_text = (
            f"{_escape(annotation_summary.get('unique_gene_ids', 0))} unique gene IDs from "
            f"{_escape(annotation_summary.get('feature_rows', 0))} "
            f"{_escape(annotation_summary.get('feature_type', 'feature'))} rows; identifier field "
            f"{_escape(annotation_summary.get('id_attribute', 'unknown'))}."
        )

    inventory_rows = []
    for path in sorted(analysis_ready.rglob("*")):
        if not path.is_file() or path == report_path:
            continue
        relative = path.relative_to(analysis_ready).as_posix()
        inventory_rows.append(
            f"<tr><td>{_escape(relative)}</td><td>{_human_size(path.stat().st_size)}</td></tr>"
        )

    created = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    status_badge = "Command plan only" if status == "dry_run" else "Preprocessing complete"
    status_text = (
        "No bioinformatics command was executed. Review the command plan, then start a real run."
        if status == "dry_run"
        else "The workflow intentionally stops before differential expression, enrichment, operon prediction, variant calling, or transcript discovery."
    )
    document = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{_escape(project.get('name', 'Project'))} - Analysis Ready Report</title>
<style>
:root{{--green:#4a8453;--green-dark:#33663e;--soft:#e7f3e9;--blue:#417b9a;--ink:#1f2b24;--muted:#5b6961;--border:#d2ded6;}}
*{{box-sizing:border-box}} body{{margin:0;background:#f6f9f7;color:var(--ink);font:15px/1.5 "Segoe UI",Arial,sans-serif}}
header{{background:white;border-bottom:1px solid var(--border);padding:28px 6vw}} header h1{{margin:0;color:var(--green-dark)}} header p{{margin:6px 0 0;color:var(--muted)}}
main{{max-width:1180px;margin:24px auto;padding:0 22px 50px}} .grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:16px}}
.card{{background:white;border:1px solid var(--border);border-radius:12px;padding:18px;margin-bottom:16px;box-shadow:0 3px 14px #1f2b240c}}
h2{{font-size:20px;color:var(--green-dark);margin:0 0 12px}} h3{{font-size:16px;margin:18px 0 8px}} .badge{{display:inline-block;background:var(--soft);color:var(--green-dark);padding:5px 9px;border-radius:999px;font-weight:600}}
table{{width:100%;border-collapse:collapse;font-size:14px}} th,td{{border-bottom:1px solid #e8eeea;text-align:left;padding:8px;vertical-align:top}} th{{background:#f2f7f3;color:var(--green-dark);position:sticky;top:0}}
.scroll{{overflow:auto;max-height:520px;border:1px solid var(--border);border-radius:8px}} code{{background:#eef4f0;padding:2px 5px;border-radius:4px}} ul{{margin:8px 0;padding-left:22px}}
.note{{border-left:4px solid var(--blue);padding:10px 14px;background:#e8f2f8}} footer{{color:var(--muted);text-align:center;padding:24px}}
</style>
</head>
<body>
<header><h1>Analysis Ready Export</h1><p>{_escape(project.get('name', 'Project'))} · {_escape(project.get('analysis_type', ''))} reads · generated {created}</p></header>
<main>
<div class="grid">
  <section class="card"><h2>Run status</h2><span class="badge">{status_badge}</span><p>{status_text}</p></section>
  <section class="card"><h2>Reference normalization</h2><p>{annotation_text}</p></section>
</div>
<section class="card"><h2>Which files to use next</h2>
<div class="grid">
<div><h3>Counts and annotation</h3><p>The final Results folder publishes <code>Counts &amp; Annotation.xlsx</code>, with raw integer counts beside portable gene annotation plus separate annotation and sample-metadata sheets.</p></div>
<div><h3>Alignment and IGV</h3><p>The final <code>BAM-BAI-IGV/</code> folder contains the flattened BAM/BAI files and an IGV session. Reference and coverage resources are retained under <code>intermediate/</code>.</p></div>
<div><h3>QC</h3><p>The final <code>QC Analysis.html</code> combines the useful FastQC, cleaning/basecalling, alignment, strand-audit and MultiQC information. Original machine-readable QC sources remain under <code>intermediate/QC/</code>.</p></div>
<div><h3>Transcript / operon analysis</h3><p>Transcript Discovery and TU Architecture reuse the retained reference, coverage, metadata and strand evidence under <code>intermediate/</code> without changing the raw gene-count matrix.</p></div>
</div>
<p class="note">FPKM and TPM are not used as input for later differential-expression significance testing. The exported raw integer matrix is the correct starting point.</p>
<p class="note">During processing the pipeline may use an internal <code>analysis_ready</code> staging folder. After a successful verified run it is published into the minimal Results-folder layout; failed or stopped runs keep their checkpoints for safe resume.</p>
</section>
<section class="card"><h2>Samples</h2><div class="scroll"><table><thead><tr><th>Sample</th><th>Condition</th><th>Replicate</th><th>Short</th><th>Long</th></tr></thead><tbody>{sample_rows}</tbody></table></div></section>
<section class="card"><h2>Selected methods</h2><div class="scroll"><table><thead><tr><th>Stage</th><th>Selection</th></tr></thead><tbody>{method_rows}</tbody></table></div></section>
<section class="card"><h2>Alignment summary</h2><div class="scroll"><table><thead><tr><th>Sample</th><th>Modality</th><th>Role</th><th>Aligner</th><th>Primary records</th><th>Mapped</th><th>Mapped %</th></tr></thead><tbody>{alignment_rows}</tbody></table></div></section>
<section class="card"><h2>Strand audit</h2><div class="scroll"><table><thead><tr><th>Sample</th><th>Read type</th><th>Declared</th><th>Inferred</th><th>Forward assigned</th><th>Reverse assigned</th><th>Status</th></tr></thead><tbody>{strand_rows}</tbody></table></div></section>
<section class="card"><h2>Warnings and interpretation notes</h2><ul>{warning_items}</ul></section>
<section class="card"><h2>Exported file inventory</h2><div class="scroll"><table><thead><tr><th>Relative path</th><th>Size</th></tr></thead><tbody>{''.join(inventory_rows)}</tbody></table></div></section>
</main>
<footer>Bacterial RNA Analysis · preprocessing and analysis-ready export</footer>
</body></html>
"""
    report_path.write_text(document, encoding="utf-8")
    return report_path


def write_run_manifest(
    path: Path,
    config: dict[str, Any],
    *,
    status: str,
    warnings: Iterable[str],
    outputs: Iterable[Path],
) -> None:
    payload = {
        "schema_version": 1,
        "status": status,
        "updated_at": datetime.now(timezone.utc).isoformat(),
        "project": config.get("project", {}),
        "methods": config.get("methods", {}),
        "warnings": list(warnings),
        "outputs": [os.fspath(item) for item in outputs],
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    os.replace(temp, path)
