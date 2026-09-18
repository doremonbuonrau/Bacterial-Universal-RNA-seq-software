#!/usr/bin/env bash
set -Eeuo pipefail
if [[ $# -ne 2 ]]; then
  echo "Usage: run_downstream.sh MODE CONFIG.json" >&2
  exit 2
fi
MODE=$1
CONFIG=$2
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
# Rscript can encode spaces in its synthetic --file= argument on some builds.
# Pass the real helper directory explicitly so installations such as
# "Bacterial RNA Analysis" work without reconstructing the script path in R.
export BACTERIAL_RNA_DOWNSTREAM_R_DIR="$ROOT_DIR/R"
ENV_NAME="prok-rnaseq-downstream"
CORE_MINIFORGE="$HOME/.local/share/prok-rnaseq/miniforge3"
OPDETECT_MINIFORGE="$HOME/miniforge3"
if [[ -x "$CORE_MINIFORGE/bin/conda" ]]; then
  MINIFORGE_DIR="$CORE_MINIFORGE"
elif [[ -x "$OPDETECT_MINIFORGE/bin/conda" ]]; then
  MINIFORGE_DIR="$OPDETECT_MINIFORGE"
else
  echo "ERROR: A supported Miniforge installation is missing from the shared Linux environment." >&2
  exit 2
fi
CONDA=("$MINIFORGE_DIR/bin/conda" run --no-capture-output -n "$ENV_NAME")

# A standalone pathway visualization uses existing DE results. It does not load
# R packages, run online GO annotation, or repeat enrichment/network analysis.
if [[ "$MODE" == "pathway_map" ]]; then
  exec "${CONDA[@]}" python "$ROOT_DIR/Python/kegg_pathway_maps.py" "$CONFIG" --standalone
fi

# GENIE3 parallel execution requires doRNG. Earlier downstream environments could
# contain GENIE3 without that transitive runtime dependency, which caused a late
# failure only after annotation had already completed. Repair this small dependency
# once, before starting an expensive Network job.
if [[ "$MODE" == "network" || "$MODE" == "combined" ]]; then
  if ! "${CONDA[@]}" Rscript -e 'quit(status=ifelse(requireNamespace("doRNG", quietly=TRUE),0,1))' >/dev/null 2>&1; then
    echo "One-time Network environment repair: installing missing R package doRNG..."
    if ! "$MINIFORGE_DIR/bin/conda" install --quiet -y -n "$ENV_NAME" -c conda-forge r-dorng; then
      echo "WARNING: doRNG could not be installed automatically. GENIE3 will fall back to one CPU core for this run instead of failing."
      echo "WARNING: Use Install or update later to restore parallel GENIE3 execution."
      export BRA_GENIE3_FORCE_SINGLE_CORE=1
    fi
  fi
fi

# The integrated KEGG/STRING coordinator imports the Scientific Expansion
# backend, which uses requests for its REST calls. Packages installed before
# this dependency was added may already be marked ready, so repair requests
# once at run time instead of allowing a long combined job to fail at the end.
if [[ "$MODE" == "combined" ]]; then
  if ! "${CONDA[@]}" python -c 'import requests' >/dev/null 2>&1; then
    echo "One-time combined-analysis environment repair: installing missing Python package requests..."
    if ! "$MINIFORGE_DIR/bin/conda" install --quiet -y -n "$ENV_NAME" -c conda-forge 'requests>=2.32'; then
      echo "WARNING: requests could not be installed automatically. Core enrichment and co-expression results will still be finalized; KEGG/STRING status will record the unavailable dependency." >&2
    fi
  fi
fi

OUTPUT_DIR=$("${CONDA[@]}" python - "$CONFIG" <<'PYOUTPUT'
import json
import sys
from pathlib import Path
with Path(sys.argv[1]).open(encoding='utf-8-sig') as handle:
    config = json.load(handle)
print(config['output_dir'])
PYOUTPUT
)
mkdir -p "$OUTPUT_DIR"
PROGRESS_FILE="$OUTPUT_DIR/Intermediate files/${MODE} progress.json"
mkdir -p "$(dirname "$PROGRESS_FILE")"
export BRA_PROGRESS_FILE="$PROGRESS_FILE"
export BRA_PROGRESS_MODE="$MODE"
write_progress() {
  local overall=$1 phase=$2 detail=${3:-} phase_percent=${4:-0} current=${5:-0} total=${6:-0} unit=${7:-}
  "${CONDA[@]}" python "$ROOT_DIR/Python/progress_status.py" "$PROGRESS_FILE" \
    --mode "$MODE" --status running --overall "$overall" --phase "$phase" \
    --phase-percent "$phase_percent" --current "$current" --total "$total" \
    --unit "$unit" --detail "$detail" >/dev/null 2>&1 || true
}
write_progress 1 "Starting analysis" "Preparing downstream job" 0 0 0 ""
# Optional online functional annotation is prepared before the R analysis so
# GO enrichment can use the generated mapping and network outputs can inherit
# gene functions. Sequence scans use a locally cached Swiss-Prot DIAMOND database.
ONLINE_ANNOTATION_ENABLED=$("${CONDA[@]}" python - "$CONFIG" <<'PYONLINEFLAG'
import json, sys
from pathlib import Path
with Path(sys.argv[1]).open(encoding="utf-8-sig") as handle:
    cfg = json.load(handle)
value = cfg.get("online_annotation_enabled", False)
print("yes" if (value is True or str(value).strip().lower() in {"1","true","yes","on"}) else "no")
PYONLINEFLAG
)
if [[ "$ONLINE_ANNOTATION_ENABLED" == "yes" && ( "$MODE" == "enrichment" || "$MODE" == "network" || "$MODE" == "combined" ) ]]; then
  if [[ "$MODE" == "enrichment" || "$MODE" == "combined" ]]; then
    echo "Preparing online gene-to-term mapping..."
  else
    echo "Preparing online functional annotation..."
  fi
  printf '$'; printf ' %q' "${CONDA[@]}" python "$ROOT_DIR/Python/online_annotation.py" "$MODE" "$CONFIG"; echo
  if [[ "$MODE" == "network" ]]; then
    # Functional annotation enriches network interpretation but is not required to
    # infer the co-expression/regulatory network itself. A transient UniProt/network
    # failure should therefore not discard a valid network analysis.
    if ! "${CONDA[@]}" python "$ROOT_DIR/Python/online_annotation.py" "$MODE" "$CONFIG"; then
      echo "WARNING: Online functional annotation could not be completed after automatic retries."
      echo "WARNING: Continuing the network analysis without online gene annotations; the core network results remain valid."
      echo "WARNING: Re-run later with online annotation enabled to add functions when the connection is stable."
    fi
  else
    # GO enrichment selected with online mapping requires a successful gene-to-term
    # map, so an unrecoverable annotation failure remains a hard stop for enrichment.
    "${CONDA[@]}" python "$ROOT_DIR/Python/online_annotation.py" "$MODE" "$CONFIG"
  fi
fi

if [[ "$MODE" == "enrichment" || "$MODE" == "network" || "$MODE" == "combined" ]]; then
  write_progress 62 "Recording software provenance" "Saving package versions and source identities to the run log" 0 0 0 ""
fi

R_SCRIPT=""
case "$MODE" in
  de) R_SCRIPT="$ROOT_DIR/R/de_analysis.R" ;;
  enrichment) R_SCRIPT="$ROOT_DIR/R/enrichment_analysis.R" ;;
  network) R_SCRIPT="$ROOT_DIR/R/network_analysis.R" ;;
  combined) ;;
  gene-range|gene_range|circular) ;;
  *) echo "ERROR: Unknown mode: $MODE" >&2; exit 2 ;;
esac

emit_source_identity() {
  local label=$1 path=$2
  local digest size
  digest=$(sha256sum "$path" | awk '{print $1}')
  size=$(wc -c < "$path" | tr -d '[:space:]')
  printf 'SOURCE	%s	path=%s	sha256=%s	bytes=%s\n' "$label" "$path" "$digest" "$size"
}

echo
echo "================================================================================================"
echo "APPLICATION SOURCE IDENTITIES"
echo "================================================================================================"
emit_source_identity "Downstream analysis runner" "$0"
emit_source_identity "Downstream Windows GUI and configuration builder" "$ROOT_DIR/App/downstream_gui.ps1"
emit_source_identity "Shared R helpers" "$ROOT_DIR/R/common.R"
if [[ -n "$R_SCRIPT" ]]; then emit_source_identity "$(basename "$R_SCRIPT")" "$R_SCRIPT"; fi
if [[ "$MODE" == "combined" ]]; then
  emit_source_identity "enrichment_analysis.R" "$ROOT_DIR/R/enrichment_analysis.R"
  emit_source_identity "network_analysis.R" "$ROOT_DIR/R/network_analysis.R"
fi
emit_source_identity "Analysis-time plot writer" "$ROOT_DIR/Python/interactive_plots.py"
emit_source_identity "Advanced DE diagnostics and comparison analyses" "$ROOT_DIR/Python/advanced_de_analysis.py"
emit_source_identity "Visualization studio" "$ROOT_DIR/Python/visualization_studio.py"
emit_source_identity "Excel result organizer" "$ROOT_DIR/Python/finalize_results.py"
emit_source_identity "Integrated pathway and STRING coordinator" "$ROOT_DIR/Python/integrated_external_analysis.py"
emit_source_identity "Online functional annotation" "$ROOT_DIR/Python/online_annotation.py"
emit_source_identity "Shared progress-state writer" "$ROOT_DIR/Python/progress_status.py"
emit_source_identity "Downstream environment specification" "$ROOT_DIR/App/environment-downstream.yml"

echo
echo "================================================================================================"
echo "THIRD-PARTY SOFTWARE AND PACKAGE PROVENANCE"
echo "================================================================================================"
echo "Compiled executables cannot expose original source lines at runtime. Exact executable hashes, package builds, channels, licenses, and upstream package URLs are recorded instead."
"${CONDA[@]}" python - <<'PYPROVENANCE'
import hashlib
import importlib.metadata
import os
import sys
from pathlib import Path

def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()

executable = Path(sys.executable).resolve()
print(f"PYTHON EXECUTABLE\tpath={executable}\tsha256={digest(executable)}\tversion={sys.version.replace(os.linesep, ' ')}")
for distribution in sorted(importlib.metadata.distributions(), key=lambda item: (item.metadata.get("Name") or "").casefold()):
    metadata = distribution.metadata
    name = metadata.get("Name") or distribution.name
    version = distribution.version
    license_text = (metadata.get("License") or "").replace("\t", " ").replace("\n", " ")
    home_page = metadata.get("Home-page") or ""
    project_urls = "; ".join(metadata.get_all("Project-URL") or [])
    print(f"PYTHON PACKAGE\t{name}\tversion={version}\tlicense={license_text}\thome={home_page}\tproject_urls={project_urls}")
PYPROVENANCE
"${CONDA[@]}" Rscript -e 'ip <- as.data.frame(installed.packages(), stringsAsFactors=FALSE); keep <- intersect(c("Package","Version","License","Built","LibPath"), colnames(ip)); write.table(ip[,keep,drop=FALSE], row.names=FALSE, sep="\t", quote=FALSE); sessionInfo()' 2>&1 || true
"$MINIFORGE_DIR/bin/conda" list -n "$ENV_NAME" --explicit 2>&1 || true
ENV_PREFIX="$MINIFORGE_DIR/envs/$ENV_NAME"
if [[ -d "$ENV_PREFIX/conda-meta" ]]; then
  "${CONDA[@]}" python - "$ENV_PREFIX/conda-meta" <<'PYCONDAPROVENANCE'
import hashlib
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
fields = (
    "package", "version", "build", "build_number", "subdir", "channel",
    "license", "license_family", "package_url", "package_sha256", "package_md5",
    "requested_spec", "dependencies", "upstream_urls", "metadata_file",
    "metadata_sha256", "metadata_status",
)

def clean(value):
    if value is None:
        return ""
    if isinstance(value, (list, tuple)):
        value = "; ".join(str(item) for item in value)
    elif isinstance(value, dict):
        value = json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    return " ".join(str(value).replace("\t", " ").splitlines()).strip()

print("CONDA PACKAGE FIELDS\t" + "\t".join(fields))
count = 0
for path in sorted(root.glob("*.json")):
    raw = path.read_bytes()
    metadata_sha256 = hashlib.sha256(raw).hexdigest()
    try:
        payload = json.loads(raw.decode("utf-8", errors="replace"))
        repodata = payload.get("repodata_record")
        if not isinstance(repodata, dict):
            repodata = {}
        channel = payload.get("channel", repodata.get("channel", ""))
        if isinstance(channel, dict):
            channel = channel.get("canonical_name") or channel.get("name") or channel.get("url") or channel
        urls = [payload.get(key) for key in ("source_url", "dev_url", "doc_url", "home", "homepage")]
        record = {
            "package": clean(payload.get("name") or repodata.get("name") or path.stem),
            "version": clean(payload.get("version") or repodata.get("version")),
            "build": clean(payload.get("build") or repodata.get("build")),
            "build_number": clean(payload.get("build_number", repodata.get("build_number", ""))),
            "subdir": clean(payload.get("subdir") or repodata.get("subdir")),
            "channel": clean(channel),
            "license": clean(payload.get("license") or repodata.get("license")),
            "license_family": clean(payload.get("license_family") or repodata.get("license_family")),
            "package_url": clean(payload.get("url") or repodata.get("url")),
            "package_sha256": clean(payload.get("sha256") or repodata.get("sha256")),
            "package_md5": clean(payload.get("md5") or repodata.get("md5")),
            "requested_spec": clean(payload.get("requested_spec")),
            "dependencies": clean(payload.get("depends") or repodata.get("depends") or []),
            "upstream_urls": "; ".join(dict.fromkeys(clean(item) for item in urls if item)),
            "metadata_file": path.name,
            "metadata_sha256": metadata_sha256,
            "metadata_status": "ok",
        }
    except Exception as exc:
        record = {field: "" for field in fields}
        record.update({
            "package": path.stem,
            "metadata_file": path.name,
            "metadata_sha256": metadata_sha256,
            "metadata_status": clean(f"unreadable: {exc}"),
        })
    print("CONDA PACKAGE\t" + "\t".join(record[field] for field in fields))
    count += 1
print(f"CONDA PACKAGE COUNT\t{count}")
print("Conda files and paths_data.paths inventories were omitted because they are installation manifests, not executable source or generated analysis code; metadata_sha256 fingerprints each complete original record.")
PYCONDAPROVENANCE
fi
echo "END THIRD-PARTY SOFTWARE AND PACKAGE PROVENANCE"
echo
echo "ACTIVE ANALYSIS CONFIGURATION"
sed 's/^/CONFIG | /' "$CONFIG"

echo
echo "================================================================================================"
echo "EXECUTION COMMANDS"
echo "================================================================================================"
case "$MODE" in
  de)
    printf '$'; printf ' %q' "${CONDA[@]}" Rscript "$ROOT_DIR/R/de_analysis.R" "$CONFIG"; echo
    "${CONDA[@]}" Rscript "$ROOT_DIR/R/de_analysis.R" "$CONFIG"
    printf '$'; printf ' %q' "${CONDA[@]}" python "$ROOT_DIR/Python/advanced_de_analysis.py" "$CONFIG"; echo
    "${CONDA[@]}" python "$ROOT_DIR/Python/advanced_de_analysis.py" "$CONFIG"
    printf '$'; printf ' %q' "${CONDA[@]}" python "$ROOT_DIR/Python/interactive_plots.py" de "$CONFIG"; echo
    "${CONDA[@]}" python "$ROOT_DIR/Python/interactive_plots.py" de "$CONFIG"
    printf '$'; printf ' %q' "${CONDA[@]}" python "$ROOT_DIR/Python/finalize_results.py" de "$CONFIG"; echo
    "${CONDA[@]}" python "$ROOT_DIR/Python/finalize_results.py" de "$CONFIG"
    echo "Building offline interactive HTML report..."
    if ! "${CONDA[@]}" python "$ROOT_DIR/Python/visualization_studio.py" --module de --output "$OUTPUT_DIR" --build-static "$OUTPUT_DIR/Differential expression interactive.html"; then
      echo "WARNING: Differential-expression analysis completed, but the offline interactive HTML report could not be generated." >&2
    fi
    rmdir "$OUTPUT_DIR/Interactive" 2>/dev/null || true
    ;;
  enrichment)
    write_progress 64 "GO enrichment statistics" "Running selected enrichment method" 0 0 0 ""
    printf '$'; printf ' %q' "${CONDA[@]}" Rscript "$ROOT_DIR/R/enrichment_analysis.R" "$CONFIG"; echo
    "${CONDA[@]}" Rscript "$ROOT_DIR/R/enrichment_analysis.R" "$CONFIG"
    write_progress 80 "GO enrichment statistics" "Statistical enrichment complete" 100 1 1 "stage"
    write_progress 82 "Creating analysis plots" "Generating enrichment figures" 0 0 0 ""
    printf '$'; printf ' %q' "${CONDA[@]}" python "$ROOT_DIR/Python/interactive_plots.py" enrichment "$CONFIG"; echo
    "${CONDA[@]}" python "$ROOT_DIR/Python/interactive_plots.py" enrichment "$CONFIG"
    write_progress 88 "Creating analysis plots" "Enrichment figures complete" 100 1 1 "stage"
    write_progress 90 "Organizing results" "Writing Excel and final result files" 0 0 0 ""
    printf '$'; printf ' %q' "${CONDA[@]}" python "$ROOT_DIR/Python/finalize_results.py" enrichment "$CONFIG"; echo
    "${CONDA[@]}" python "$ROOT_DIR/Python/finalize_results.py" enrichment "$CONFIG"
    write_progress 95 "Organizing results" "Result files complete" 100 1 1 "stage"
    write_progress 96 "Building interactive report" "Creating offline GO enrichment HTML" 0 0 0 ""
    echo "Building offline interactive HTML report..."
    if ! "${CONDA[@]}" python "$ROOT_DIR/Python/visualization_studio.py" --module enrichment --output "$OUTPUT_DIR" --build-static "$OUTPUT_DIR/GO enrichment interactive.html"; then
      echo "WARNING: Enrichment analysis completed, but the offline interactive HTML report could not be generated." >&2
    fi
    write_progress 100 "Completed" "GO enrichment analysis finished" 100 1 1 "stage"
    ;;
  network)
    write_progress 64 "Network inference" "Running selected co-expression/network method" 0 0 0 ""
    printf '$'; printf ' %q' "${CONDA[@]}" Rscript "$ROOT_DIR/R/network_analysis.R" "$CONFIG"; echo
    "${CONDA[@]}" Rscript "$ROOT_DIR/R/network_analysis.R" "$CONFIG"
    write_progress 80 "Network inference" "Network inference complete" 100 1 1 "stage"
    write_progress 82 "Creating network plots" "Generating network figures" 0 0 0 ""
    printf '$'; printf ' %q' "${CONDA[@]}" python "$ROOT_DIR/Python/interactive_plots.py" network "$CONFIG"; echo
    "${CONDA[@]}" python "$ROOT_DIR/Python/interactive_plots.py" network "$CONFIG"
    write_progress 88 "Creating network plots" "Network figures complete" 100 1 1 "stage"
    write_progress 90 "Organizing results" "Writing Excel and final result files" 0 0 0 ""
    printf '$'; printf ' %q' "${CONDA[@]}" python "$ROOT_DIR/Python/finalize_results.py" network "$CONFIG"; echo
    "${CONDA[@]}" python "$ROOT_DIR/Python/finalize_results.py" network "$CONFIG"
    write_progress 95 "Organizing results" "Result files complete" 100 1 1 "stage"
    write_progress 96 "Building interactive report" "Creating offline network HTML" 0 0 0 ""
    echo "Building offline interactive HTML report..."
    if ! "${CONDA[@]}" python "$ROOT_DIR/Python/visualization_studio.py" --module network --output "$OUTPUT_DIR" --build-static "$OUTPUT_DIR/Network analysis interactive.html"; then
      echo "WARNING: Network analysis completed, but the offline interactive HTML report could not be generated." >&2
    fi
    write_progress 100 "Completed" "Network analysis finished" 100 1 1 "stage"
    ;;
  combined)
    write_progress 63 "Functional enrichment" "Running the selected enrichment method" 0 0 0 ""
    printf '$'; printf ' %q' "${CONDA[@]}" Rscript "$ROOT_DIR/R/enrichment_analysis.R" "$CONFIG"; echo
    "${CONDA[@]}" Rscript "$ROOT_DIR/R/enrichment_analysis.R" "$CONFIG"
    write_progress 73 "Functional enrichment" "Enrichment statistics complete" 100 1 1 "stage"

    write_progress 74 "Co-expression and network inference" "Running the selected network method" 0 0 0 ""
    printf '$'; printf ' %q' "${CONDA[@]}" Rscript "$ROOT_DIR/R/network_analysis.R" "$CONFIG"; echo
    "${CONDA[@]}" Rscript "$ROOT_DIR/R/network_analysis.R" "$CONFIG"
    write_progress 84 "Co-expression and network inference" "Network inference complete" 100 1 1 "stage"

    write_progress 85 "Creating all plots" "Generating enrichment figures" 0 0 0 ""
    printf '$'; printf ' %q' "${CONDA[@]}" python "$ROOT_DIR/Python/interactive_plots.py" enrichment "$CONFIG"; echo
    "${CONDA[@]}" python "$ROOT_DIR/Python/interactive_plots.py" enrichment "$CONFIG"
    write_progress 89 "Creating all plots" "Generating co-expression and network figures" 50 1 2 "modules"
    printf '$'; printf ' %q' "${CONDA[@]}" python "$ROOT_DIR/Python/interactive_plots.py" network "$CONFIG"; echo
    "${CONDA[@]}" python "$ROOT_DIR/Python/interactive_plots.py" network "$CONFIG"
    write_progress 88 "Creating all plots" "Core enrichment and co-expression figures complete" 100 2 4 "modules"

    write_progress 89 "Pathway and protein-association analysis" "Running online KEGG and STRING from the same selected genes" 50 2 4 "modules"
    printf '$'; printf ' %q' "${CONDA[@]}" python "$ROOT_DIR/Python/integrated_external_analysis.py" "$CONFIG"; echo
    "${CONDA[@]}" python "$ROOT_DIR/Python/integrated_external_analysis.py" "$CONFIG"
    write_progress 93 "Pathway and protein-association analysis" "Integrated database analyses finished; any unavailable service is recorded in the result workbook" 100 4 4 "modules"

    write_progress 94 "Organizing combined results" "Writing one Excel workbook for enrichment, co-expression, pathway, and STRING results" 0 0 0 ""
    printf '$'; printf ' %q' "${CONDA[@]}" python "$ROOT_DIR/Python/finalize_results.py" combined "$CONFIG"; echo
    "${CONDA[@]}" python "$ROOT_DIR/Python/finalize_results.py" combined "$CONFIG"
    write_progress 97 "Building combined interactive report" "Embedding all functional and network workspaces into one HTML file" 0 0 0 ""
    echo "Building one offline interactive HTML report for enrichment, co-expression, pathway, and STRING PPI..."
    if ! "${CONDA[@]}" python "$ROOT_DIR/Python/visualization_studio.py" --module combined --output "$OUTPUT_DIR" --build-static "$OUTPUT_DIR/Functional enrichment and co-expression interactive.html"; then
      echo "WARNING: The analyses completed, but the combined offline interactive HTML report could not be generated." >&2
    fi
    write_progress 100 "Completed" "Unified enrichment, co-expression, pathway, and STRING analysis finished" 100 4 4 "modules"
    ;;
  gene-range|gene_range|circular)
    printf '$'; printf ' %q' "${CONDA[@]}" python "$ROOT_DIR/Python/interactive_plots.py" "$MODE" "$CONFIG"; echo
    "${CONDA[@]}" python "$ROOT_DIR/Python/interactive_plots.py" "$MODE" "$CONFIG"
    ;;
esac
