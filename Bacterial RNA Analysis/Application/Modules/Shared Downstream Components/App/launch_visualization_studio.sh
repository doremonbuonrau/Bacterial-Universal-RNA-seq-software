#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 5 ]]; then
  echo "Usage: launch_visualization_studio.sh <module> <studio.py> <output_dir> <ready_file> <log_file>" >&2
  exit 2
fi

MODULE="$1"
STUDIO_SCRIPT="$2"
OUTPUT_DIR="$3"
READY_FILE="$4"
LOG_FILE="$5"

mkdir -p "$(dirname "$LOG_FILE")"
: > "$LOG_FILE"
exec >>"$LOG_FILE" 2>&1

echo "Visualization studio launcher"
echo "Module: $MODULE"
echo "Results: $OUTPUT_DIR"
echo "Studio script: $STUDIO_SCRIPT"
echo "Ready file: $READY_FILE"

CORE_MINIFORGE="$HOME/.local/share/prok-rnaseq/miniforge3"
LEGACY_MINIFORGE="$HOME/miniforge3"
if [[ -x "$CORE_MINIFORGE/bin/conda" ]]; then
  MINIFORGE_DIR="$CORE_MINIFORGE"
elif [[ -x "$LEGACY_MINIFORGE/bin/conda" ]]; then
  MINIFORGE_DIR="$LEGACY_MINIFORGE"
else
  echo "ERROR: No supported Miniforge installation was found."
  exit 2
fi

if [[ ! -f "$STUDIO_SCRIPT" ]]; then
  echo "ERROR: Visualization studio script not found: $STUDIO_SCRIPT"
  exit 2
fi
if [[ ! -d "$OUTPUT_DIR" ]]; then
  echo "ERROR: Result directory not found: $OUTPUT_DIR"
  exit 2
fi

rm -f "$READY_FILE"
export PYTHONUNBUFFERED=1

echo "Miniforge: $MINIFORGE_DIR"
echo "Starting local visualization server..."
exec "$MINIFORGE_DIR/bin/conda" run --no-capture-output -n prok-rnaseq-downstream \
  python "$STUDIO_SCRIPT" \
  --module "$MODULE" \
  --output "$OUTPUT_DIR" \
  --ready-file "$READY_FILE"
