#!/usr/bin/env bash
set -Eeuo pipefail

FAILED=0
printf 'System: '
uname -a

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "Unsupported operating system"
  FAILED=1
elif grep -qi microsoft /proc/version 2>/dev/null; then
  echo "WSL2/Linux detected"
else
  echo "Native Linux detected"
fi

for command in bash git python fastp hisat2 hisat2-build samtools bedtools; do
  if command -v "$command" >/dev/null 2>&1; then
    printf '%-14s %s\n' "$command" "$(command -v "$command")"
  else
    printf '%-14s MISSING\n' "$command"
    FAILED=1
  fi
done

python - <<'PY' || FAILED=1
from packaging.version import Version
import importlib
packages = ["numpy", "pandas", "scipy", "sklearn", "tensorflow", "keras", "docx"]
for package in packages:
    module = importlib.import_module(package)
    print(f"{package:14s} {getattr(module, '__version__', 'installed')}")
import tensorflow as tf
import keras
assert Version(tf.__version__) >= Version("2.19.0"), "TensorFlow 2.19 or newer is required"
assert Version(keras.__version__) >= Version("3.9.0"), "Keras 3.9 or newer is required"
PY

if [[ "${CONDA_DEFAULT_ENV:-}" != "opdetect-pipeline" ]]; then
  echo "Active Conda environment: ${CONDA_DEFAULT_ENV:-none}"
  echo "Activate it with: conda activate opdetect-pipeline"
  FAILED=1
else
  echo "Active Conda environment: opdetect-pipeline"
fi

if (( FAILED )); then
  echo "Environment check found one or more problems." >&2
  exit 1
fi

echo "Environment check passed."
