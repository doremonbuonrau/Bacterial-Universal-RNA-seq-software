#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "ERROR: OpDetect requires Linux." >&2
  echo "On Windows 11, close this terminal and run START_HERE.bat." >&2
  exit 2
fi

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) ;;
    *)
      echo "ERROR: the automatic dependency installer currently supports Ubuntu or Debian." >&2
      echo "Detected distribution: ${PRETTY_NAME:-unknown Linux}" >&2
      exit 2
      ;;
  esac
fi

if grep -qi microsoft /proc/version 2>/dev/null; then
  echo "WSL2/Linux environment detected."
else
  echo "Native Linux environment detected."
fi

if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
  APT_PREFIX=()
else
  command -v sudo >/dev/null 2>&1 || {
    echo "ERROR: sudo is required for system dependency installation." >&2
    exit 1
  }
  APT_PREFIX=(sudo)
fi

"${APT_PREFIX[@]}" apt-get update
"${APT_PREFIX[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y \
  build-essential ca-certificates curl git nano unzip wget

ARCH=$(uname -m)
case "$ARCH" in
  x86_64) MINIFORGE_ARCH=x86_64 ;;
  aarch64|arm64) MINIFORGE_ARCH=aarch64 ;;
  *) echo "Unsupported CPU architecture for this installer: $ARCH" >&2; exit 1 ;;
esac

SHARED_MINIFORGE="$HOME/.local/share/prok-rnaseq/miniforge3"
LEGACY_MINIFORGE="$HOME/miniforge3"
if [[ -x "$SHARED_MINIFORGE/bin/conda" ]]; then
  MINIFORGE_DIR="$SHARED_MINIFORGE"
elif [[ -x "$LEGACY_MINIFORGE/bin/conda" ]]; then
  MINIFORGE_DIR="$LEGACY_MINIFORGE"
else
  MINIFORGE_DIR="$SHARED_MINIFORGE"
fi
if [[ ! -x "$MINIFORGE_DIR/bin/conda" ]]; then
  INSTALLER="/tmp/Miniforge3-Linux-${MINIFORGE_ARCH}.sh"
  curl -fsSL \
    "https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-${MINIFORGE_ARCH}.sh" \
    -o "$INSTALLER"
  bash "$INSTALLER" -b -p "$MINIFORGE_DIR"
  rm -f "$INSTALLER"
fi

# shellcheck disable=SC1091
source "$MINIFORGE_DIR/etc/profile.d/conda.sh"
conda init bash >/dev/null
conda config --set auto_activate_base false

if conda env list | awk '{print $1}' | grep -qx 'opdetect-pipeline'; then
  conda env update -n opdetect-pipeline -f "$SCRIPT_DIR/environment.yml" --prune
else
  conda env create -f "$SCRIPT_DIR/environment.yml"
fi

conda activate opdetect-pipeline

# Existing installations may still contain TensorFlow/Keras 2.14 even after an
# interrupted Conda update. Repair the model runtime explicitly when needed.
if ! python - <<'PYMODEL' >/dev/null 2>&1
from packaging.version import Version
import tensorflow as tf
import keras
raise SystemExit(0 if Version(tf.__version__) >= Version("2.19.0") and Version(keras.__version__) >= Version("3.9.0") else 1)
PYMODEL
then
  echo "Updating the official-model runtime to TensorFlow 2.19 and Keras 3.9..."
  python -m pip install --upgrade --no-cache-dir     numpy==1.26.4 tensorflow==2.19.0 keras==3.9.0 scikit-learn==1.4.2 python-docx==1.1.2
fi

echo
echo "Linux dependency setup complete."
echo "Activate with: source ~/miniforge3/etc/profile.d/conda.sh && conda activate opdetect-pipeline"
echo "Verify with: bash check_wsl_environment.sh"
