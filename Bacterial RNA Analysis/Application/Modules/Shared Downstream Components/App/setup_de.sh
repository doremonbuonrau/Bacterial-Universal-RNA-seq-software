#!/usr/bin/env bash
set -Eeuo pipefail
export TERM=dumb
export NO_COLOR=1
export CONDA_NUMBER_CHANNEL_NOTICES=0
export CONDA_PROGRESS_BAR=off
export PYTHONUNBUFFERED=1
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ENV_NAME="prok-rnaseq-downstream"
CORE_MINIFORGE="$HOME/.local/share/prok-rnaseq/miniforge3"
ALT_MINIFORGE="$HOME/miniforge3"

if [[ -x "$CORE_MINIFORGE/bin/conda" ]]; then
  MINIFORGE_DIR="$CORE_MINIFORGE"
elif [[ -x "$ALT_MINIFORGE/bin/conda" ]]; then
  MINIFORGE_DIR="$ALT_MINIFORGE"
else
  echo "ERROR: No supported Miniforge installation was found." >&2
  echo "Run the main RNA Processing Install or repair once, then retry Differential Expression." >&2
  exit 2
fi
ENV_PREFIX="$MINIFORGE_DIR/envs/$ENV_NAME"

# Differential Expression must not disturb a working GO/Network environment.
# If the shared prefix does not exist yet, use the established full installer once.
if [[ ! -x "$ENV_PREFIX/bin/Rscript" ]]; then
  echo "The shared downstream environment does not exist yet; creating it once..."
  exec bash "$SCRIPT_DIR/setup_downstream.sh"
fi

check_de_packages() {
  "$ENV_PREFIX/bin/Rscript" -e 'pkgs <- c("DESeq2","edgeR","limma","jsonlite"); ok <- vapply(pkgs, function(p) suppressPackageStartupMessages(requireNamespace(p, quietly=TRUE)), logical(1)); miss <- pkgs[!ok]; if(length(miss)) {cat(paste(miss, collapse=",")); quit(status=3)}' 2>/dev/null
}

set +e
MISSING=$(check_de_packages)
CHECK_RC=$?
set -e
if [[ $CHECK_RC -eq 0 ]]; then
  echo "DESeq2, edgeR, limma, and jsonlite are already installed."
  echo "No Conda update is required; the working GO/Network environment was left unchanged."
  "$ENV_PREFIX/bin/python" -c 'import numpy, pandas, openpyxl, plotly; print("DE Python packages: OK")'
  echo "Differential Expression environment is ready."
  exit 0
fi

echo "Missing Differential Expression R package(s): ${MISSING:-unknown}"
echo "Performing a targeted DE-only repair. GO and Network packages will not be pruned or updated."

DE_CONDA_PKGS=(bioconductor-deseq2 bioconductor-edger bioconductor-limma r-jsonlite)
INSTALL_OK=0

# Prefer mamba when available; it avoids the Conda exception-formatting bug seen
# in some Python 3.13 base installations.
if [[ -x "$MINIFORGE_DIR/bin/mamba" ]]; then
  echo "Using mamba for the targeted DE package repair..."
  if "$MINIFORGE_DIR/bin/mamba" install -y -p "$ENV_PREFIX" --override-channels -c conda-forge -c bioconda "${DE_CONDA_PKGS[@]}"; then
    INSTALL_OK=1
  fi
fi

# If mamba is unavailable, try a small targeted Conda transaction rather than
# `conda env update --prune`. Suppress plugins/progress to avoid known noisy
# exception paths. Failure falls through to an R/Bioconductor repair.
if [[ $INSTALL_OK -eq 0 ]]; then
  echo "Trying a targeted Conda install without pruning the shared environment..."
  set +e
  CONDA_NO_PLUGINS=true "$MINIFORGE_DIR/bin/conda" install -y -p "$ENV_PREFIX" --solver=classic --override-channels -c conda-forge -c bioconda "${DE_CONDA_PKGS[@]}"
  CONDA_RC=$?
  set -e
  if [[ $CONDA_RC -eq 0 ]]; then INSTALL_OK=1; fi
fi

if [[ $INSTALL_OK -eq 0 ]]; then
  echo "Conda could not complete the targeted repair. Falling back to Bioconductor from the already-working R environment..."
  "$ENV_PREFIX/bin/Rscript" <<'RSCRIPT'
options(repos = c(CRAN = "https://cloud.r-project.org"))
if (!requireNamespace("BiocManager", quietly = TRUE)) install.packages("BiocManager")
need <- c("DESeq2", "edgeR", "limma")
missing <- need[!vapply(need, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing)) BiocManager::install(missing, ask = FALSE, update = FALSE)
if (!requireNamespace("jsonlite", quietly = TRUE)) install.packages("jsonlite")
RSCRIPT
fi

"$ENV_PREFIX/bin/Rscript" -e 'pkgs <- c("DESeq2","edgeR","limma","jsonlite"); ok <- vapply(pkgs, function(p) suppressPackageStartupMessages(requireNamespace(p, quietly=TRUE)), logical(1)); miss <- pkgs[!ok]; if(length(miss)) stop(paste("Still missing:", paste(miss, collapse=", "))); cat("DE R packages: OK\n")'
"$ENV_PREFIX/bin/python" -c 'import numpy, pandas, openpyxl, plotly; print("DE Python packages: OK")'
echo "Differential Expression environment is ready."
