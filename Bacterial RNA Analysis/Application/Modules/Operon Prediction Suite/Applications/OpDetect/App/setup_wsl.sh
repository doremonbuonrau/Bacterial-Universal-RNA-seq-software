#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
echo "setup_wsl.sh is retained for compatibility; running setup_linux.sh."
exec bash "$SCRIPT_DIR/setup_linux.sh"
