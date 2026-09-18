#!/usr/bin/env bash
set -Eeuo pipefail

resolve_conda_root() {
  for candidate in /root/.local/share/prok-rnaseq/miniforge3 /root/miniforge3; do
    if [[ -x "$candidate/bin/conda" && -r "$candidate/etc/profile.d/conda.sh" ]]; then printf '%s\n' "$candidate"; return 0; fi
  done
  return 1
}

THRESHOLD=${1:-0.5}
MIN_SUPPORT=${2:-0.60}
CONDA_ROOT=$(resolve_conda_root) || exit 10
PIPELINE_ROOT=/root/opdetect_pipeline
OPDETECT_REPO=/root/tools/OpDetect

source "$CONDA_ROOT/etc/profile.d/conda.sh"
conda activate opdetect-pipeline
export TF_CPP_MIN_LOG_LEVEL=3
export CUDA_VISIBLE_DEVICES=-1

python - <<'PYMODEL'
from packaging.version import Version
import tensorflow as tf
import keras
if Version(tf.__version__) < Version("2.19.0") or Version(keras.__version__) < Version("3.9.0"):
    raise SystemExit(
        f"Model runtime is outdated: TensorFlow {tf.__version__}, Keras {keras.__version__}. "
        "Run Install or repair first."
    )
print(f"Model runtime: TensorFlow {tf.__version__}; Keras {keras.__version__}; CPU mode")
PYMODEL

LATEST_PROCESSED=$(find /root/opdetect_runs -mindepth 3 -maxdepth 3 -type f -name data_replicate_aware.npz \
  -printf '%T@\t%p\n' 2>/dev/null | sort -nr | head -n 1 | cut -f2-)
[[ -n "$LATEST_PROCESSED" ]] || { echo "No replicate-aware processed OpDetect run was found under /root/opdetect_runs." >&2; exit 1; }
DATA_ROOT=$(dirname "$LATEST_PROCESSED")
RUN_ROOT=$(dirname "$DATA_ROOT")
PROJECT_DIR=$(find "$DATA_ROOT" -mindepth 1 -maxdepth 1 -type d -print | head -n 1)
[[ -n "$PROJECT_DIR" ]] || { echo "Could not identify the project directory in $DATA_ROOT." >&2; exit 1; }
PROJECT_ID=$(basename "$PROJECT_DIR")
GENE_PAIRS="$PROJECT_DIR/gene_pairs.csv"
ANNOTATION="$PROJECT_DIR/gene_annotation.bed"
TOPOLOGY="$RUN_ROOT/results/contig-topology.tsv"
RESULT_DIR="$RUN_ROOT/results"
LOG_DIR="$RUN_ROOT/logs"
TRACK_DIR="$RESULT_DIR/tracks"
BEDGRAPH_DIR="$TRACK_DIR/coverage"
mkdir -p "$RESULT_DIR" "$LOG_DIR" "$BEDGRAPH_DIR"

for file in "$GENE_PAIRS" "$ANNOTATION" "$LATEST_PROCESSED" "$TOPOLOGY"; do
  [[ -s "$file" ]] || { echo "Required recovery input is missing: $file" >&2; exit 1; }
done

echo "Resuming the latest replicate-aware processed run: $RUN_ROOT"
echo "Project: $PROJECT_ID"
python "$PIPELINE_ROOT/scripts/predict_opdetect.py" \
  --repo "$OPDETECT_REPO" \
  --processed "$LATEST_PROCESSED" \
  --gene-pairs "$GENE_PAIRS" \
  --threshold "$THRESHOLD" \
  --min-support "$MIN_SUPPORT" \
  --arrangement-map-output "$RESULT_DIR/replicate-channel-arrangements.tsv" \
  --output "$RESULT_DIR/${PROJECT_ID}.gene-pair-predictions.csv" \
  | tee "$LOG_DIR/resume_predict.log"

python "$PIPELINE_ROOT/scripts/pairs_to_operons.py" \
  --predictions "$RESULT_DIR/${PROJECT_ID}.gene-pair-predictions.csv" \
  --annotation-bed "$ANNOTATION" \
  --topology-file "$TOPOLOGY" \
  --threshold "$THRESHOLD" \
  --min-support "$MIN_SUPPORT" \
  --output "$RESULT_DIR/${PROJECT_ID}.predicted-operons.tsv" \
  | tee "$LOG_DIR/resume_group_operons.log"

python "$PIPELINE_ROOT/scripts/operons_to_bedgraph.py" \
  --operons "$RESULT_DIR/${PROJECT_ID}.predicted-operons.tsv" \
  --annotation-bed "$ANNOTATION" \
  --output "$RESULT_DIR/${PROJECT_ID}.predicted-operons.bedgraph" \
  | tee "$LOG_DIR/resume_operon_bedgraph.log"
python "$PIPELINE_ROOT/scripts/table_to_xlsx.py" \
  --input "$RESULT_DIR/${PROJECT_ID}.gene-pair-predictions.csv" --delimiter comma \
  --sheet-name "Gene pair predictions" --output "$RESULT_DIR/${PROJECT_ID}.gene-pair-predictions.xlsx"
python "$PIPELINE_ROOT/scripts/table_to_xlsx.py" \
  --input "$RESULT_DIR/${PROJECT_ID}.predicted-operons.tsv" --delimiter tab \
  --sheet-name "Predicted operons" --drop-columns "chromosome,topology,wraps_origin" \
  --output "$RESULT_DIR/${PROJECT_ID}.predicted-operons.xlsx"
if [[ -s "$RESULT_DIR/qc/replicate-pearson.tsv" && -s "$RESULT_DIR/qc/replicate-spearman.tsv" ]]; then
  python "$PIPELINE_ROOT/scripts/correlations_to_xlsx.py" \
    --pearson "$RESULT_DIR/qc/replicate-pearson.tsv" \
    --spearman "$RESULT_DIR/qc/replicate-spearman.tsv" \
    --output "$RESULT_DIR/replicate-correlations.xlsx"
fi

[[ -s "$RESULT_DIR/${PROJECT_ID}.gene-pair-predictions.xlsx" ]]
[[ -s "$RESULT_DIR/${PROJECT_ID}.predicted-operons.xlsx" ]]
[[ -s "$RESULT_DIR/${PROJECT_ID}.predicted-operons.bedgraph" ]]
printf 'RESUME_PROJECT=%s\n' "$PROJECT_ID"
printf 'RESUME_RESULTS=%s\n' "$RESULT_DIR"
