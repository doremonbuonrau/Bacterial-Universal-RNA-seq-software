#!/usr/bin/env bash
set -Eeuo pipefail
trap 'status=$?; printf "ERROR: setup command failed at line %s with exit code %s: %s\n" "$LINENO" "$status" "$BASH_COMMAND" >&2; exit "$status"' ERR

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
APP_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
INSTALL_ROOT="$HOME/.local/share/prok-rnaseq"
MINIFORGE_DIR="$INSTALL_ROOT/miniforge3"
ENV_NAME="prok-rnaseq"

ANALYSIS_TYPE="both"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --analysis-type)
      ANALYSIS_TYPE="${2:-}"
      shift 2
      ;;
    *)
      echo "ERROR: unknown setup option: $1"
      exit 2
      ;;
  esac
done
case "$ANALYSIS_TYPE" in
  short|long|both) ;;
  *) echo "ERROR: analysis type must be short, long, or both."; exit 2 ;;
esac

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "ERROR: bioinformatics execution requires Linux."
  echo "On Windows, use Maintenance/Install or Repair.bat to configure WSL2 and Ubuntu."
  exit 2
fi

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) ;;
    *)
      echo "Automatic system-package installation supports Ubuntu and Debian."
      echo "Detected: ${PRETTY_NAME:-unknown}. Install build-essential, curl, git, unzip, wget, and zlib development files manually, then rerun."
      exit 2
      ;;
  esac
fi

if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
  APT=(apt-get)
else
  command -v sudo >/dev/null 2>&1 || {
    echo "ERROR: sudo is needed for Ubuntu or Debian system packages."
    exit 1
  }
  APT=(sudo apt-get)
fi

echo "Installing Linux prerequisites..."
"${APT[@]}" update
"${APT[@]}" install -y build-essential ca-certificates curl git libbz2-dev liblzma-dev libncurses-dev unzip wget zlib1g-dev

case "$(uname -m)" in
  x86_64) MF_ARCH=x86_64 ;;
  aarch64|arm64) MF_ARCH=aarch64 ;;
  *) echo "Unsupported architecture: $(uname -m)"; exit 1 ;;
esac

mkdir -p "$INSTALL_ROOT"
if [[ ! -x "$MINIFORGE_DIR/bin/conda" ]]; then
  # Miniforge checks that its own script name ends in .sh. A suffix-less
  # mktemp path makes a correctly executed installer report that it was
  # sourced. Remove any incomplete prefix and use a real .sh filename.
  if [[ -d "$MINIFORGE_DIR" ]]; then
    echo "Removing an incomplete core Miniforge installation..."
    rm -rf "$MINIFORGE_DIR"
  fi

  installer=$(mktemp "${TMPDIR:-/tmp}/Miniforge3-Linux-${MF_ARCH}.XXXXXX.sh")
  cleanup_installer() { rm -f "$installer"; }
  trap cleanup_installer EXIT

  echo "Downloading Miniforge..."
  curl --fail --show-error --location --retry 5 --retry-delay 2 \
    "https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-${MF_ARCH}.sh" \
    --output "$installer"

  if [[ ! -s "$installer" ]] || ! head -n 1 "$installer" | grep -Eq '^#!'; then
    echo "ERROR: the downloaded Miniforge installer is empty or invalid."
    exit 1
  fi

  echo "Installing Miniforge..."
  /bin/bash "$installer" -b -p "$MINIFORGE_DIR"
  [[ -x "$MINIFORGE_DIR/bin/conda" ]] || {
    echo "ERROR: Miniforge finished without creating $MINIFORGE_DIR/bin/conda."
    exit 1
  }
fi

# shellcheck disable=SC1091
source "$MINIFORGE_DIR/etc/profile.d/conda.sh"
conda config --set auto_activate_base false
if conda env list | awk '{print $1}' | grep -qx "$ENV_NAME"; then
  echo "Updating the existing core environment while preserving separately installed optional tools..."
  conda env update -n "$ENV_NAME" -f "$SCRIPT_DIR/environment-core.yml"
else
  conda env create -f "$SCRIPT_DIR/environment-core.yml"
fi

echo "Verifying the repaired core environment..."
conda run --no-capture-output -n "$ENV_NAME" python "$APP_DIR/backend/scripts/check_environment.py" --analysis-type "$ANALYSIS_TYPE"
printf '%s\n' "$MINIFORGE_DIR" > "$SCRIPT_DIR/.miniforge_location"

echo
echo "Core RNA-seq environment installed and checked for: $ANALYSIS_TYPE"
echo "Optional accuracy-audit tools FADU and LongQC can be added with:"
echo "  bash '$SCRIPT_DIR/install_optional_tools.sh'"
echo "Dorado is intentionally installed separately because the correct binary depends on GPU and platform."
echo "See Documentation/Dorado SUP setup.md."
