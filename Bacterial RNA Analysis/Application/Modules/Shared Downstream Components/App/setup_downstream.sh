#!/usr/bin/env bash
set -Eeuo pipefail
export TERM=dumb
export NO_COLOR=1
# Conda documents quiet mode as disabling progress bars and other routine
# output. Set it both as a command option and an environment configuration so
# older Miniforge/Conda builds in the shared Linux environment behave consistently.
export CONDA_QUIET=true
export CONDA_NUMBER_CHANNEL_NOTICES=0
export CONDA_PROGRESS_BAR=off
export PYTHONUNBUFFERED=1
export PYTHONWARNINGS=ignore
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ENV_NAME="prok-rnaseq-downstream"
CORE_MINIFORGE="$HOME/.local/share/prok-rnaseq/miniforge3"
OPDETECT_MINIFORGE="$HOME/miniforge3"
if [[ -x "$CORE_MINIFORGE/bin/conda" ]]; then
  MINIFORGE_DIR="$CORE_MINIFORGE"
elif [[ -x "$OPDETECT_MINIFORGE/bin/conda" ]]; then
  MINIFORGE_DIR="$OPDETECT_MINIFORGE"
  echo "Using an existing shared Miniforge installation: $MINIFORGE_DIR"
else
  echo "ERROR: No supported Miniforge installation was found in the shared Linux environment." >&2
  echo "Run Application/Maintenance/Install or Repair.bat to prepare the shared Linux environment." >&2
  exit 2
fi
# shellcheck disable=SC1091
source "$MINIFORGE_DIR/etc/profile.d/conda.sh"
ENV_PREFIX="$MINIFORGE_DIR/envs/$ENV_NAME"

# A cancelled first installation can leave an incomplete prefix. Remove only
# that dedicated incomplete prefix; downloaded package archives remain cached
# and are reused on the next attempt.
if [[ -d "$ENV_PREFIX" && ! -d "$ENV_PREFIX/conda-meta" ]]; then
  echo "Removing an incomplete downstream environment prefix before resuming..."
  rm -rf -- "$ENV_PREFIX"
fi

if [[ -d "$ENV_PREFIX/conda-meta" ]]; then
  echo "Updating or resuming the shared analysis environment..."
  conda env update --quiet -p "$ENV_PREFIX" -f "$SCRIPT_DIR/environment-downstream.yml" --prune
else
  echo "Creating the shared analysis environment..."
  conda env create --quiet -p "$ENV_PREFIX" -f "$SCRIPT_DIR/environment-downstream.yml"
fi

echo "Checking required R and Python packages..."
conda run -p "$ENV_PREFIX" Rscript -e 'pkgs <- c("DESeq2","edgeR","limma","clusterProfiler","fgsea","topGO","WGCNA","CEMiTool","GENIE3","doRNG","jsonlite"); ok <- vapply(pkgs, function(p) suppressPackageStartupMessages(requireNamespace(p, quietly=TRUE)), logical(1)); miss <- pkgs[!ok]; if(length(miss)) stop(paste("Missing:", paste(miss, collapse=", "))); cat("R packages OK\n")'
conda run -p "$ENV_PREFIX" python -c 'import cairosvg, networkx, numpy, openpyxl, pandas, plotly, requests; from PIL import Image; print("Python packages OK")'
conda run -p "$ENV_PREFIX" diamond version
printf '%s\n' "ready" > "$SCRIPT_DIR/.downstream_ready"
echo "Shared analysis environment is ready."
