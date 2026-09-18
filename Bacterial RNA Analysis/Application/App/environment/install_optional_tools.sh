#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
APP_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
TOOLS_DIR="$APP_DIR/tools"
MINIFORGE_DIR="$HOME/.local/share/prok-rnaseq/miniforge3"
ENV_NAME="prok-rnaseq"

ANALYSIS_TYPE="both"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --analysis-type) ANALYSIS_TYPE="${2:-}"; shift 2 ;;
    *) echo "ERROR: unknown optional-tool option: $1"; exit 2 ;;
  esac
done
case "$ANALYSIS_TYPE" in
  short|long|both) ;;
  *) echo "ERROR: analysis type must be short, long, or both."; exit 2 ;;
esac

if [[ ! -x "$MINIFORGE_DIR/bin/conda" ]]; then
  echo "ERROR: core environment not found. Run setup_linux.sh first."
  exit 2
fi

# shellcheck disable=SC1091
source "$MINIFORGE_DIR/etc/profile.d/conda.sh"
mkdir -p "$TOOLS_DIR"

if [[ "$ANALYSIS_TYPE" == "short" || "$ANALYSIS_TYPE" == "both" ]]; then
  echo "Installing Julia for the optional FADU bacterial audit..."
  conda install -n "$ENV_NAME" -y -c conda-forge 'julia>=1.10,<1.12'
  if [[ ! -f "$TOOLS_DIR/FADU/fadu.jl" ]]; then
    git clone --depth 1 https://github.com/IGS/FADU.git "$TOOLS_DIR/FADU"
  fi
  conda run -n "$ENV_NAME" julia -e 'using Pkg; Pkg.add(["ArgParse","BGZFStreams","GenomicFeatures","GFF3","Indexes","StructArrays","XAM","BED"])'
fi

if [[ "$ANALYSIS_TYPE" == "long" || "$ANALYSIS_TYPE" == "both" ]]; then
  echo "Installing LongQC and its modified minimap2..."
  if [[ ! -f "$TOOLS_DIR/LongQC/longQC.py" ]]; then
    git clone --depth 1 https://github.com/yfukasawa/LongQC.git "$TOOLS_DIR/LongQC"
  fi
  make -C "$TOOLS_DIR/LongQC/minimap2-coverage"
fi

echo
echo "Optional tools installed for: $ANALYSIS_TYPE. Re-run the environment check from the GUI."
