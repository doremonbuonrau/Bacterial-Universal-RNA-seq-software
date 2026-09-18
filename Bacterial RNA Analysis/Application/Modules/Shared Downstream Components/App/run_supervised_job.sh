#!/usr/bin/env bash
set -u

if [[ $# -lt 2 ]]; then
  echo "ERROR: run_supervised_job.sh requires JOB_TOKEN and a command." >&2
  exit 2
fi

token=$1
shift
pidfile="/tmp/bra_job_${token}.pid"

# PowerShell -> WSL -> bash used to pass a quoted shell command through two
# nested `bash -lc` layers. Paths containing spaces then became fragile and
# could make setup_downstream.sh fail with an unmatched-quote error. The GUI
# now sends the original command as UTF-8 base64. Decode it here and give the
# exact command string to one (and only one) bash -lc instance.
if [[ "${1:-}" == "--bash64" ]]; then
  if [[ $# -ne 2 ]]; then
    echo "ERROR: --bash64 requires exactly one base64 payload." >&2
    exit 2
  fi
  if ! decoded_command=$(printf '%s' "$2" | base64 --decode 2>/dev/null); then
    echo "ERROR: managed job command payload could not be decoded." >&2
    exit 2
  fi
  set -- bash -lc "$decoded_command"
fi

cleanup_group() {
  local pgid=""
  if [[ -s "$pidfile" ]]; then
    pgid=$(tr -cd '0-9' < "$pidfile" 2>/dev/null || true)
  fi
  if [[ -n "$pgid" ]]; then
    kill -TERM -- "-$pgid" 2>/dev/null || kill -TERM "$pgid" 2>/dev/null || true
    for _ in $(seq 1 50); do
      if ! kill -0 -- "-$pgid" 2>/dev/null; then
        break
      fi
      sleep 0.2
    done
    if kill -0 -- "-$pgid" 2>/dev/null; then
      kill -KILL -- "-$pgid" 2>/dev/null || kill -KILL "$pgid" 2>/dev/null || true
    fi
  fi
  rm -f -- "$pidfile"
}

on_signal() {
  cleanup_group
  exit 130
}

trap on_signal TERM INT HUP
rm -f -- "$pidfile"

# setsid makes the actual analysis command the leader of its own Linux process
# group. The Windows GUI can therefore stop the complete tree (conda, Python,
# R, DIAMOND, download helpers, etc.) instead of only terminating wsl.exe.
setsid "$@" &
child=$!
printf '%s\n' "$child" > "$pidfile"
wait "$child"
code=$?
rm -f -- "$pidfile"
# A GUI-requested TERM/KILL of the managed group is a deliberate safe stop.
# Normalize common signal-derived exit codes so the Windows GUI reports
# "stopped safely" rather than a generic analysis failure.
if [[ "$code" -eq 143 || "$code" -eq 137 ]]; then code=130; fi
exit "$code"
