#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
APP_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
MINIFORGE_DIR="$HOME/.local/share/prok-rnaseq/miniforge3"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "ERROR: this check must run in Linux or WSL2."
  exit 2
fi
if [[ ! -x "$MINIFORGE_DIR/bin/conda" ]]; then
  echo "Core environment is not installed."
  echo "Run: bash '$SCRIPT_DIR/setup_linux.sh'"
  exit 1
fi

CHECK_ARGS=()
# Backward compatibility: an unflagged first argument is treated as a project JSON.
if [[ $# -gt 0 && "${1:-}" != --* ]]; then
  CHECK_ARGS+=(--config "$1")
  shift
fi
CHECK_ARGS+=("$@")
export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8
exec "$MINIFORGE_DIR/bin/conda" run --no-capture-output -n prok-rnaseq python "$APP_DIR/backend/scripts/check_environment.py" "${CHECK_ARGS[@]}"
