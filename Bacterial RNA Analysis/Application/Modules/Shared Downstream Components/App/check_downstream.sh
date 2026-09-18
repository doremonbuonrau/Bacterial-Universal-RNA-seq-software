#!/usr/bin/env bash
set -Eeuo pipefail
ENV_NAME="prok-rnaseq-downstream"
CORE_MINIFORGE="$HOME/.local/share/prok-rnaseq/miniforge3"
OPDETECT_MINIFORGE="$HOME/miniforge3"
if [[ -x "$CORE_MINIFORGE/bin/conda" ]]; then
  MINIFORGE_DIR="$CORE_MINIFORGE"
elif [[ -x "$OPDETECT_MINIFORGE/bin/conda" ]]; then
  MINIFORGE_DIR="$OPDETECT_MINIFORGE"
  echo "Miniforge source: existing shared installation"
else
  echo "MISSING: supported Miniforge installation in the shared Linux environment"
  exit 2
fi
if ! "$MINIFORGE_DIR/bin/conda" env list | awk '{print $1}' | grep -qx "$ENV_NAME"; then
  echo "MISSING: downstream conda environment"
  exit 2
fi

# One environment supports the complete functional workflow from annotation and
# enrichment through module detection and regulatory-network inference.
if ! "$MINIFORGE_DIR/bin/conda" run -n "$ENV_NAME" Rscript -e '
core <- c("DESeq2","edgeR","limma","clusterProfiler","fgsea","topGO","WGCNA","CEMiTool","GENIE3","doRNG","jsonlite")
ok <- vapply(core, function(p) suppressPackageStartupMessages(requireNamespace(p, quietly=TRUE)), logical(1))
miss <- core[!ok]
if(length(miss)) { cat("MISSING_R_PACKAGES:", paste(miss, collapse=", "), "\n"); quit(status=2) }
cat("Combined enrichment/network R packages: OK\n")
' ; then
  echo "MISSING: required downstream R package(s). Click Install or update to repair them."
  exit 2
fi

if ! "$MINIFORGE_DIR/bin/conda" run -n "$ENV_NAME" python -c 'import cairosvg,networkx,numpy,openpyxl,pandas,plotly,requests; from PIL import Image; print("Python packages: OK")'; then
  echo "MISSING: required downstream Python package(s). Click Install or update to repair them."
  exit 2
fi
if ! "$MINIFORGE_DIR/bin/conda" run -n "$ENV_NAME" diamond version; then
  echo "MISSING: DIAMOND. Click Install or update to repair the downstream environment."
  exit 2
fi
echo "READY: one combined functional enrichment and co-expression environment"
