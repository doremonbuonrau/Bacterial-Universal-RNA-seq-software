#!/usr/bin/env bash
set -Eeuo pipefail
trap 'status=$?; printf "ERROR: dependency repair failed at line %s with exit code %s: %s\n" "$LINENO" "$status" "$BASH_COMMAND" >&2; exit "$status"' ERR

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
APP_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
MINIFORGE_DIR="$HOME/.local/share/prok-rnaseq/miniforge3"
ENV_NAME="prok-rnaseq"

ANALYSIS_TYPE="both"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --analysis-type)
      ANALYSIS_TYPE="${2:-}"
      shift 2
      ;;
    *)
      echo "ERROR: unknown repair option: $1"
      exit 2
      ;;
  esac
done
case "$ANALYSIS_TYPE" in
  short|long|both) ;;
  *) echo "ERROR: analysis type must be short, long, or both."; exit 2 ;;
esac

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "ERROR: dependency repair must run in Linux or WSL2."
  exit 2
fi
if [[ ! -x "$MINIFORGE_DIR/bin/conda" || ! -x "$MINIFORGE_DIR/envs/$ENV_NAME/bin/python" ]]; then
  echo "ERROR: the core RNA-seq environment is not installed. Use Install or repair core instead."
  exit 2
fi

export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8

if "$MINIFORGE_DIR/bin/conda" run -n "$ENV_NAME" python -c 'import openpyxl; assert tuple(int(part) for part in openpyxl.__version__.split(".")[:2]) >= (3, 1)' >/dev/null 2>&1; then
  echo "OpenPyXL 3.1 or newer is already installed."
else
  echo "Adding OpenPyXL to the existing core environment..."
  "$MINIFORGE_DIR/bin/conda" install --yes --name "$ENV_NAME" --channel conda-forge --freeze-installed 'openpyxl>=3.1'
fi

"$MINIFORGE_DIR/bin/conda" run --no-capture-output -n "$ENV_NAME" \
  python -c 'import openpyxl; print(f"OpenPyXL {openpyxl.__version__} is ready.")'

echo "Checking the complete $ANALYSIS_TYPE-read tool family..."
exec "$MINIFORGE_DIR/bin/conda" run --no-capture-output -n "$ENV_NAME" \
  python "$APP_DIR/backend/scripts/check_environment.py" --analysis-type "$ANALYSIS_TYPE"
