#!/usr/bin/env bash
set -Eeuo pipefail
ENV_NAME="prok-rnaseq-downstream"
echo "Checking Differential Expression environment in WSL distro: ${WSL_DISTRO_NAME:-unknown}"
CORE_MINIFORGE="$HOME/.local/share/prok-rnaseq/miniforge3"
ALT_MINIFORGE="$HOME/miniforge3"
if [[ -x "$CORE_MINIFORGE/bin/conda" ]]; then
  MINIFORGE_DIR="$CORE_MINIFORGE"
elif [[ -x "$ALT_MINIFORGE/bin/conda" ]]; then
  MINIFORGE_DIR="$ALT_MINIFORGE"
else
  echo "MISSING: supported Miniforge installation in the shared Linux environment"
  exit 2
fi
ENV_PREFIX="$MINIFORGE_DIR/envs/$ENV_NAME"
if [[ ! -x "$ENV_PREFIX/bin/Rscript" ]]; then
  echo "MISSING: downstream conda environment or R runtime"
  exit 2
fi

"$ENV_PREFIX/bin/Rscript" -e 'pkgs <- c("DESeq2","edgeR","limma","jsonlite"); ok <- vapply(pkgs, function(p) suppressPackageStartupMessages(requireNamespace(p, quietly=TRUE)), logical(1)); miss <- pkgs[!ok]; if(length(miss)) {cat("MISSING_DE_PACKAGES:", paste(miss, collapse=","), "\n"); quit(status=2)}; cat("DE R packages: OK\n")'

if [[ ! -x "$ENV_PREFIX/bin/python" ]]; then
  echo "MISSING: downstream Python runtime"
  exit 2
fi
"$ENV_PREFIX/bin/python" -c 'import numpy, pandas, openpyxl, plotly; print("DE Python packages: OK")'
echo "READY: Differential Expression environment"
