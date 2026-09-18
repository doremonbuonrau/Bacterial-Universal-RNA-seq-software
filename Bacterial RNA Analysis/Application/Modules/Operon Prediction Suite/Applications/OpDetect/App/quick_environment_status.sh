#!/usr/bin/env bash

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
set +e

emit() {
  local key="$1"
  local ready="$2"
  local detail="$3"
  printf '%s\t%s\t%s\n' "$key" "$ready" "$detail"
}

kernel="$(uname -r 2>/dev/null)"
if [[ -n "$kernel" ]] && [[ "$kernel" =~ [Ww][Ss][Ll]2|microsoft-standard ]]; then
  emit Linux 1 "The selected Bacterial RNA Analysis WSL2 distribution is running ($kernel)"
else
  emit Linux 0 "The WSL2 Linux kernel could not be confirmed"
fi

conda_root=$(resolve_conda_root) || conda_root=""
env_root=""
if [[ -n "$conda_root" ]]; then env_root=$(resolve_env_root "$conda_root") || env_root=""; fi

if [[ -n "$conda_root" && -x "$conda_root/bin/conda" && -n "$env_root" && -x "$env_root/bin/python" ]]; then
  emit Conda 1 "opdetect-pipeline environment ($env_root)"
else
  emit Conda 0 "Miniforge or opdetect-pipeline is missing"
fi

check_tool() {
  local key="$1"
  local tool="$2"
  local display="$3"
  local path=""
  if [[ -x "$env_root/bin/$tool" ]]; then
    path="$env_root/bin/$tool"
  elif command -v "$tool" >/dev/null 2>&1; then
    path="$(command -v "$tool")"
  fi
  if [[ -n "$path" ]]; then emit "$key" 1 "$path"; else emit "$key" 0 "$display is missing"; fi
}

check_tool Git git git
check_tool Fastp fastp fastp
check_tool Hisat2 hisat2 HISAT2
check_tool Samtools samtools SAMtools
check_tool Bedtools bedtools BEDtools

python_bin="${env_root:+$env_root/bin/python}"
python_detail=""
if [[ -x "$python_bin" ]]; then
  python_detail="$(timeout 12 "$python_bin" - <<'PY' 2>/dev/null
from packaging.version import Version
import importlib.util
modules = ("numpy", "pandas", "matplotlib", "PIL", "scipy", "tensorflow", "keras", "sklearn", "docx")
if not all(importlib.util.find_spec(name) is not None for name in modules):
    raise SystemExit(1)
import tensorflow as tf
import keras
if Version(tf.__version__) < Version("2.19.0") or Version(keras.__version__) < Version("3.9.0"):
    raise SystemExit(2)
print(f"Python ready; TensorFlow {tf.__version__}; Keras {keras.__version__}; official Keras 3 checkpoints supported")
PY
)"
  status=$?
else
  status=1
fi

if [[ $status -eq 0 && -n "$python_detail" ]]; then
  emit Python 1 "$python_detail"
elif [[ $status -eq 2 ]]; then
  emit Python 0 "Model runtime is outdated; click Install or repair for TensorFlow 2.19 and Keras 3.9"
else
  emit Python 0 "Python or one or more required libraries are missing"
fi

exit 0
