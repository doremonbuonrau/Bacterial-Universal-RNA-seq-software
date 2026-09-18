#!/usr/bin/env bash
set -Eeuo pipefail

# This script runs entirely inside Linux after the Windows package has been
# copied into /root/opdetect_pipeline. Keeping globbing here avoids Windows
# PowerShell/wsl.exe changing quoted find patterns before Bash receives them.
shopt -s nullglob
files=(
  /root/opdetect_pipeline/*.sh
  /root/opdetect_pipeline/scripts/*.py
)

for file in "${files[@]}"; do
  sed -i 's/\r$//' "$file"
done
