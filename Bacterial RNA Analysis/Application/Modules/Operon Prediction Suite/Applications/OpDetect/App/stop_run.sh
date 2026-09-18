#!/usr/bin/env bash
set -u
run_dir=${1:-}
[[ -n "$run_dir" ]] || exit 2
pid_file="$run_dir/pipeline.pid"
pid=""
[[ -s "$pid_file" ]] && pid=$(tr -cd '0-9' < "$pid_file")
if [[ "$pid" =~ ^[0-9]+$ ]]; then
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 30); do
    kill -0 "$pid" 2>/dev/null || exit 0
    sleep 0.25
  done
  kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
fi
pkill -TERM -f "$run_dir/launch_run.sh" 2>/dev/null || true
sleep 1
pkill -KILL -f "$run_dir/launch_run.sh" 2>/dev/null || true
exit 0
