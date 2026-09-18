#!/usr/bin/env bash
set -Eeuo pipefail

PIPELINE_ROOT=/root/opdetect_pipeline
LATEST_OPERONS=$(find /root/opdetect_runs -mindepth 3 -maxdepth 3 -type f -name '*.predicted-operons.tsv' \
  -printf '%T@\t%p\n' 2>/dev/null | sort -nr | head -n 1 | cut -f2-)
[[ -n "$LATEST_OPERONS" ]] || { echo "No completed predicted-operons table was found under /root/opdetect_runs." >&2; exit 1; }
RESULT_DIR=$(dirname "$LATEST_OPERONS")
RUN_ROOT=$(dirname "$RESULT_DIR")
OPERON_NAME=$(basename "$LATEST_OPERONS")
PROJECT_ID=${OPERON_NAME%.predicted-operons.tsv}
PROJECT_DIR="$RUN_ROOT/opdetect_data/$PROJECT_ID"
ANNOTATION="$PROJECT_DIR/gene_annotation.bed"
TRACK_DIR="$RESULT_DIR/tracks"
BEDGRAPH_DIR="$TRACK_DIR/coverage"
mkdir -p "$BEDGRAPH_DIR"

[[ -s "$ANNOTATION" ]] || { echo "Annotation file is missing: $ANNOTATION" >&2; exit 1; }
FIRST_COVERAGE=$(find "$PROJECT_DIR" -maxdepth 1 -type f -name 'base_cov_*' | sort | head -n 1)
[[ -n "$FIRST_COVERAGE" ]] || { echo "No per-base coverage files were found in $PROJECT_DIR." >&2; exit 1; }

python "$PIPELINE_ROOT/scripts/coverage_to_bedgraph.py" \
  --coverage-dir "$PROJECT_DIR" \
  --coverage-prefix base_cov \
  --output-dir "$BEDGRAPH_DIR" \
  --mean-output "$BEDGRAPH_DIR/${PROJECT_ID}.mean-replicate-coverage.bedgraph" \
  --index-output "$TRACK_DIR/coverage-tracks.tsv"

python "$PIPELINE_ROOT/scripts/operons_to_bed.py" \
  --operons "$LATEST_OPERONS" \
  --annotation-bed "$ANNOTATION" \
  --coverage-file "$FIRST_COVERAGE" \
  --output "$TRACK_DIR/${PROJECT_ID}.predicted-operons.bed"

[[ -s "$TRACK_DIR/${PROJECT_ID}.predicted-operons.bed" ]]
[[ -s "$BEDGRAPH_DIR/${PROJECT_ID}.mean-replicate-coverage.bedgraph" ]]
printf 'TRACK_PROJECT=%s\n' "$PROJECT_ID"
printf 'TRACK_RESULTS=%s\n' "$RESULT_DIR"
