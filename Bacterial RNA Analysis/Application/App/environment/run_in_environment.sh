#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
APP_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
MINIFORGE_DIR="$HOME/.local/share/prok-rnaseq/miniforge3"

if [[ $# -lt 1 ]]; then
  echo "Usage: run_in_environment.sh PROJECT_CONFIG.json [--dry-run]" >&2
  exit 2
fi
if [[ ! -x "$MINIFORGE_DIR/bin/conda" ]]; then
  echo "ERROR: analysis environment is missing. Run setup_linux.sh first." >&2
  exit 2
fi

CONFIG=$1
shift
exec "$MINIFORGE_DIR/bin/conda" run --no-capture-output -n prok-rnaseq \
  python "$APP_DIR/backend/scripts/run_pipeline.py" --config "$CONFIG" "$@"
