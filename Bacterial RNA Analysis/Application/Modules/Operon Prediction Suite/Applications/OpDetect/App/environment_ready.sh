#!/usr/bin/env bash
set -Eeuo pipefail

resolve_conda_root() {
  for candidate in \
    /root/.local/share/prok-rnaseq/miniforge3 \
    /root/miniforge3 \
    /opt/conda \
    /opt/miniforge3 \
    /home/*/.local/share/prok-rnaseq/miniforge3 \
    /home/*/miniforge3; do
    if [[ -x "$candidate/bin/conda" && -r "$candidate/etc/profile.d/conda.sh" ]]; then printf '%s\n' "$candidate"; return 0; fi
  done
  return 1
}

resolve_env_root() {
  local conda_root="$1" candidate
  for candidate in \
    "$conda_root/envs/opdetect-pipeline" \
    /root/.local/share/prok-rnaseq/miniforge3/envs/opdetect-pipeline \
    /root/miniforge3/envs/opdetect-pipeline \
    /opt/conda/envs/opdetect-pipeline \
    /opt/miniforge3/envs/opdetect-pipeline \
    /home/*/.local/share/prok-rnaseq/miniforge3/envs/opdetect-pipeline \
    /home/*/miniforge3/envs/opdetect-pipeline; do
    if [[ -x "$candidate/bin/python" ]]; then printf '%s\n' "$candidate"; return 0; fi
  done
  while IFS= read -r candidate; do
    candidate="${candidate%/}"
    if [[ "${candidate##*/}" == "opdetect-pipeline" && -x "$candidate/bin/python" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <("$conda_root/bin/conda" env list 2>/dev/null | awk 'NF && $1 !~ /^#/ {print $NF}')
  return 1
}

CONDA_ROOT=$(resolve_conda_root) || exit 10
ENV_ROOT=$(resolve_env_root "$CONDA_ROOT") || exit 12

[[ -x "$CONDA_ROOT/bin/conda" ]] || exit 10
[[ -r "$CONDA_ROOT/etc/profile.d/conda.sh" ]] || exit 11
export PATH="$ENV_ROOT/bin:$PATH"
for tool in git python fastp hisat2 hisat2-build samtools bedtools; do
  command -v "$tool" >/dev/null 2>&1 || exit 20
done
if ! "$ENV_ROOT/bin/python" - <<'PY'
import importlib
from packaging.version import Version
for package in ("numpy", "pandas", "scipy", "sklearn", "tensorflow", "keras", "docx"):
    importlib.import_module(package)
import tensorflow as tf
import keras
if Version(tf.__version__) < Version("2.19.0"):
    raise SystemExit(f"TensorFlow {tf.__version__} is too old")
if Version(keras.__version__) < Version("3.9.0"):
    raise SystemExit(f"Keras {keras.__version__} is too old")
PY
then
  exit 13
fi

exit 0
