#!/usr/bin/env bash
set -u

if [[ $# -ne 1 ]]; then
  echo "ERROR: stop_supervised_job.sh requires JOB_TOKEN." >&2
  exit 2
fi

token=$1
pidfile="/tmp/bra_job_${token}.pid"

if [[ ! -s "$pidfile" ]]; then
  rm -f -- "$pidfile"
  exit 0
fi

pgid=$(tr -cd '0-9' < "$pidfile" 2>/dev/null || true)
if [[ -z "$pgid" ]]; then
  rm -f -- "$pidfile"
  exit 0
fi

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
rm -f -- "$pidfile"
echo "Managed Linux process group $pgid stopped."
