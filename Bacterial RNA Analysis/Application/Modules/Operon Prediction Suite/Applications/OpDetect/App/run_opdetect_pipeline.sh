#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "ERROR: OpDetect requires Linux." >&2
  echo "On Windows 11, extract the package and run START_HERE.bat to install or open WSL2." >&2
  exit 2
fi

usage() {
  echo "Usage: bash run_opdetect_pipeline.sh config.env" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage
CONFIG=$1
[[ -f "$CONFIG" ]] || { echo "Config file not found: $CONFIG" >&2; exit 1; }
# shellcheck disable=SC1090
source "$CONFIG"

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
STEP_TIMING_FILE=${OPDETECT_STEP_TIMING_FILE:-/tmp/opdetect_step_timings_$$.tsv}
declare -A STEP_START_EPOCH=()
declare -A STEP_START_ISO=()
declare -A STEP_START_MESSAGE=()

if [[ -n "$STEP_TIMING_FILE" ]]; then
  mkdir -p "$(dirname "$STEP_TIMING_FILE")"
  printf 'step\ttask\tstarted\tfinished\tduration_seconds\tstatus\n' > "$STEP_TIMING_FILE"
fi

progress() {
  local step=$1 percent=$2 state=$3 message=$4
  local line now_epoch now_iso start_epoch duration
  printf -v line 'OPDETECT_PROGRESS\t%s\t%s\t%s\t%s' "$step" "$percent" "$state" "$message"
  printf '%s\n' "$line"
  if [[ -n "${OPDETECT_PROGRESS_FILE:-}" ]]; then
    printf '%s\n' "$line" >> "$OPDETECT_PROGRESS_FILE"
  fi

  now_epoch=$(date +%s)
  now_iso=$(date --iso-8601=seconds)
  if [[ "$state" == "start" ]]; then
    STEP_START_EPOCH[$step]=$now_epoch
    STEP_START_ISO[$step]=$now_iso
    STEP_START_MESSAGE[$step]=$message
  elif [[ "$state" == "done" || "$state" == "failed" ]]; then
    start_epoch=${STEP_START_EPOCH[$step]:-$now_epoch}
    duration=$((now_epoch - start_epoch))
    if [[ -n "$STEP_TIMING_FILE" ]]; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$step" "${STEP_START_MESSAGE[$step]:-$message}" \
        "${STEP_START_ISO[$step]:-$now_iso}" "$now_iso" "$duration" "$state" \
        >> "$STEP_TIMING_FILE"
    fi
  fi
}

progress 1 1 start "Validating inputs and configuration"

: "${PROJECT_ID:?Set PROJECT_ID in the config}"
: "${REFERENCE_FA:?Set REFERENCE_FA in the config}"
: "${ANNOTATION_GFF:?Set ANNOTATION_GFF in the config}"
: "${SAMPLES_TSV:?Set SAMPLES_TSV in the config}"
: "${OUTDIR:?Set OUTDIR in the config}"
: "${OPDETECT_REPO:?Set OPDETECT_REPO in the config}"
THREADS=${THREADS:-8}
ANNOTATION_FEATURE=${ANNOTATION_FEATURE:-CDS}
HISAT2_EXTRA=${HISAT2_EXTRA:---no-spliced-alignment}
PREDICTION_THRESHOLD=${PREDICTION_THRESHOLD:-0.5}
MIN_REPLICATE_SUPPORT=${MIN_REPLICATE_SUPPORT:-0.60}
REPLICON_TOPOLOGY=${REPLICON_TOPOLOGY:-auto}

for command in git python fastp hisat2 hisat2-build samtools bedtools; do
  command -v "$command" >/dev/null 2>&1 || { echo "Required command not found: $command" >&2; exit 1; }
done
TF_CPP_MIN_LOG_LEVEL=3 CUDA_VISIBLE_DEVICES=-1 python - <<'PYMODEL'
from packaging.version import Version
import tensorflow as tf
import keras
if Version(tf.__version__) < Version("2.19.0") or Version(keras.__version__) < Version("3.9.0"):
    raise SystemExit(
        f"ERROR: model runtime is outdated (TensorFlow {tf.__version__}, Keras {keras.__version__}). "
        "Open the Windows GUI and click Install or repair before running OpDetect."
    )
print(f"Model runtime: TensorFlow {tf.__version__}; Keras {keras.__version__}; CPU mode")
PYMODEL
for file in "$REFERENCE_FA" "$ANNOTATION_GFF" "$SAMPLES_TSV"; do
  [[ -f "$file" ]] || { echo "Input file not found: $file" >&2; exit 1; }
done

FASTA_RECORDS=$(grep -c '^>' "$REFERENCE_FA" || true)
(( FASTA_RECORDS >= 1 )) || {
  echo "Reference FASTA does not contain any sequence records." >&2
  exit 1
}
progress 1 5 done "Inputs validated"
progress 2 6 start "Preparing directories and OpDetect software"

mkdir -p "$OUTDIR"
OUTDIR=$(cd "$OUTDIR" && pwd)
DATA_ROOT="$OUTDIR/opdetect_data"
ORG_DIR="$DATA_ROOT/$PROJECT_ID"
WORK_DIR="$OUTDIR/work"
RESULT_DIR="$OUTDIR/results"
LOG_DIR="$OUTDIR/logs"
QC_DIR="$RESULT_DIR/qc"
TRACK_DIR="$RESULT_DIR/tracks"
BEDGRAPH_DIR="$TRACK_DIR/coverage"
IGV_INPUT_DIR="$RESULT_DIR/igv-inputs"
mkdir -p "$ORG_DIR" "$WORK_DIR/qc" "$WORK_DIR/bam" "$WORK_DIR/index" "$RESULT_DIR" "$LOG_DIR" "$QC_DIR" "$BEDGRAPH_DIR" "$IGV_INPUT_DIR"

# Keep exact copies of the selected reference and annotation inside the Linux
# result area. The Windows export and recovery tools use these copies to build
# a self-contained IGV folder without relying on the original input location.
cp -f "$REFERENCE_FA" "$IGV_INPUT_DIR/$(basename "$REFERENCE_FA")"
cp -f "$ANNOTATION_GFF" "$IGV_INPUT_DIR/$(basename "$ANNOTATION_GFF")"

if [[ -z "$STEP_TIMING_FILE" ]]; then
  STEP_TIMING_FILE="$LOG_DIR/step-timings.tsv"
  printf 'step\ttask\tstarted\tfinished\tduration_seconds\tstatus\n' > "$STEP_TIMING_FILE"
fi

if [[ ! -d "$OPDETECT_REPO/.git" ]]; then
  if [[ -e "$OPDETECT_REPO" ]]; then
    echo "Removing an incomplete OpDetect checkout: $OPDETECT_REPO"
    rm -rf "$OPDETECT_REPO"
  fi
  echo "Cloning OpDetect into $OPDETECT_REPO"
  mkdir -p "$(dirname "$OPDETECT_REPO")"
  git clone https://github.com/BioinformaticsLabAtMUN/OpDetect.git "$OPDETECT_REPO"
fi
OPDETECT_REPO=$(cd "$OPDETECT_REPO" && pwd)

emit_source_file() {
  local language=$1 path=$2
  echo
  echo "================================================================================================"
  echo "$language CODE TRACE - EXACT SOURCE USED FOR THIS RUN"
  echo "FILE: $path"
  echo "================================================================================================"
  nl -ba -w5 -s' | ' "$path"
  echo "END $language CODE TRACE"
}

echo "Code retention: full console and persistent live_run.log only."
echo "No duplicate source-code folder is created."
emit_source_file "ENV CONFIGURATION" "$CONFIG"
emit_source_file "TSV SAMPLE SHEET" "$SAMPLES_TSV"
emit_source_file "SHELL" "$0"
for source_file in "$SCRIPT_DIR"/scripts/*.py; do
  emit_source_file "PYTHON" "$source_file"
done
if [[ -f "$OPDETECT_REPO/4_data_process/integrate.py" ]]; then
  emit_source_file "PYTHON - UPSTREAM OPDETECT" "$OPDETECT_REPO/4_data_process/integrate.py"
fi

echo
printf 'EXECUTION CONTINUES WITH: bash %q %q\n' "$0" "$CONFIG"
progress 2 12 done "OpDetect software is ready"
progress 3 13 start "Converting annotation and assigning replicon topology"

[[ -f "$OPDETECT_REPO/4_data_process/integrate.py" ]] || {
  echo "Invalid OpDetect checkout: integrate.py is missing" >&2
  exit 1
}
[[ -d "$OPDETECT_REPO/0_data/models/versions" ]] || {
  echo "Invalid OpDetect checkout: supplied models directory is missing" >&2
  exit 1
}

python "$SCRIPT_DIR/scripts/gff_to_opdetect_bed.py" \
  --gff "$ANNOTATION_GFF" \
  --feature "$ANNOTATION_FEATURE" \
  --output "$ORG_DIR/gene_annotation.bed"

TOPOLOGY_FILE="$RESULT_DIR/contig-topology.tsv"
python "$SCRIPT_DIR/scripts/build_topology.py" \
  --fasta "$REFERENCE_FA" \
  --mode "$REPLICON_TOPOLOGY" \
  --output "$TOPOLOGY_FILE" | tee "$LOG_DIR/topology.log"

mapfile -t REFERENCE_CONTIG_NAMES < <(awk '/^>/{sub(/^>/,""); split($0,a,/[[:space:]]+/); print a[1]}' "$REFERENCE_FA")
mapfile -t ANNOTATION_CONTIG_NAMES < <(cut -f1 "$ORG_DIR/gene_annotation.bed" | sort -u)

declare -A REFERENCE_CONTIG_SET=()
for contig in "${REFERENCE_CONTIG_NAMES[@]}"; do
  [[ -n "$contig" ]] || continue
  if [[ -n "${REFERENCE_CONTIG_SET[$contig]:-}" ]]; then
    echo "Duplicate FASTA sequence identifier: $contig" >&2
    exit 1
  fi
  REFERENCE_CONTIG_SET[$contig]=1
done
for contig in "${ANNOTATION_CONTIG_NAMES[@]}"; do
  [[ -n "${REFERENCE_CONTIG_SET[$contig]:-}" ]] || {
    echo "GFF sequence '$contig' is not present in the reference FASTA." >&2
    exit 1
  }
done
ANNOTATION_CONTIGS=${#ANNOTATION_CONTIG_NAMES[@]}
echo "Reference contains $FASTA_RECORDS sequence record(s); annotation contains genes on $ANNOTATION_CONTIGS contig(s)."
progress 3 20 done "Annotation converted for $ANNOTATION_CONTIGS contig(s)"

mapfile -t SAMPLE_LINES < <(awk -F '\t' 'NR>1 && $0 !~ /^#/ && NF>=2 && $1!="" {print}' "$SAMPLES_TSV")
SAMPLE_COUNT=${#SAMPLE_LINES[@]}
(( SAMPLE_COUNT >= 1 && SAMPLE_COUNT <= 6 )) || {
  echo "Provide 1 to 6 biological RNA-seq replicates; found $SAMPLE_COUNT." >&2
  echo "The supplied OpDetect neural network has six fixed input channels." >&2
  exit 1
}

DUPLICATE_SAMPLE=$(printf '%s\n' "${SAMPLE_LINES[@]}" | cut -f1 | sort | uniq -d | head -1 || true)
[[ -z "$DUPLICATE_SAMPLE" ]] || { echo "Duplicate replicate name: $DUPLICATE_SAMPLE" >&2; exit 1; }

echo "Biological replicate mode: $SAMPLE_COUNT real replicate(s) will remain separate."
if (( SAMPLE_COUNT == 1 )); then
  echo "WARNING: Replicate agreement cannot be assessed with one library."
else
  echo "Replicate-aware consensus will average balanced channel arrangements across all real replicates."
fi

progress 4 21 start "Building the HISAT2 reference index"
echo "Building HISAT2 index"
hisat2-build -p "$THREADS" "$REFERENCE_FA" "$WORK_DIR/index/genome" >"$LOG_DIR/hisat2-build.log" 2>&1
progress 4 32 done "HISAT2 index built"
progress 5 33 start "Processing $SAMPLE_COUNT biological replicate(s)"
SAMPLE_INDEX=0

for line in "${SAMPLE_LINES[@]}"; do
  SAMPLE_INDEX=$((SAMPLE_INDEX + 1))
  IFS=$'\t' read -r SAMPLE R1 R2 _REST <<< "$line"
  SAMPLE_START=$((33 + (SAMPLE_INDEX - 1) * 32 / SAMPLE_COUNT))
  SAMPLE_END=$((33 + SAMPLE_INDEX * 32 / SAMPLE_COUNT))
  SAMPLE_SPAN=$((SAMPLE_END - SAMPLE_START))
  QC_PERCENT=$((SAMPLE_START + SAMPLE_SPAN * 2 / 10))
  ALIGN_PERCENT=$((SAMPLE_START + SAMPLE_SPAN * 4 / 10))
  BAM_PERCENT=$((SAMPLE_START + SAMPLE_SPAN * 8 / 10))
  progress 5 "$SAMPLE_START" progress "Replicate $SAMPLE_INDEX of $SAMPLE_COUNT: validating $SAMPLE"
  [[ -n "$SAMPLE" && -n "$R1" ]] || { echo "Invalid replicate row: $line" >&2; exit 1; }
  [[ -f "$R1" ]] || { echo "R1 file not found for $SAMPLE: $R1" >&2; exit 1; }

  CLEAN_R1="$WORK_DIR/qc/${SAMPLE}_R1.fastq.gz"
  CLEAN_R2="$WORK_DIR/qc/${SAMPLE}_R2.fastq.gz"
  BAM="$WORK_DIR/bam/${SAMPLE}.sorted.bam"

  progress 5 "$QC_PERCENT" progress "Replicate $SAMPLE_INDEX of $SAMPLE_COUNT: quality control with fastp"
  if [[ -n "${R2:-}" && "${R2:-}" != "NA" && "${R2:-}" != "." ]]; then
    [[ -f "$R2" ]] || { echo "R2 file not found for $SAMPLE: $R2" >&2; exit 1; }
    echo "QC and alignment: $SAMPLE (paired-end biological replicate)"
    fastp -w "$THREADS" -i "$R1" -I "$R2" -o "$CLEAN_R1" -O "$CLEAN_R2" \
      --cut_front --cut_front_window_size 1 --cut_front_mean_quality 3 \
      --cut_right --cut_right_window_size 4 --cut_right_mean_quality 15 \
      --html "$LOG_DIR/${SAMPLE}.fastp.html" --json "$LOG_DIR/${SAMPLE}.fastp.json" \
      >"$LOG_DIR/${SAMPLE}.fastp.stdout.log" 2>"$LOG_DIR/${SAMPLE}.fastp.stderr.log"
    progress 5 "$ALIGN_PERCENT" progress "Replicate $SAMPLE_INDEX of $SAMPLE_COUNT: HISAT2 alignment and BAM sorting"
    # shellcheck disable=SC2086
    hisat2 -p "$THREADS" $HISAT2_EXTRA -x "$WORK_DIR/index/genome" \
      -1 "$CLEAN_R1" -2 "$CLEAN_R2" 2>"$LOG_DIR/${SAMPLE}.hisat2.log" |
      samtools sort -@ "$THREADS" -o "$BAM" -
  else
    echo "QC and alignment: $SAMPLE (single-end biological replicate)"
    fastp -w "$THREADS" -i "$R1" -o "$CLEAN_R1" \
      --cut_front --cut_front_window_size 1 --cut_front_mean_quality 3 \
      --cut_right --cut_right_window_size 4 --cut_right_mean_quality 15 \
      --html "$LOG_DIR/${SAMPLE}.fastp.html" --json "$LOG_DIR/${SAMPLE}.fastp.json" \
      >"$LOG_DIR/${SAMPLE}.fastp.stdout.log" 2>"$LOG_DIR/${SAMPLE}.fastp.stderr.log"
    progress 5 "$ALIGN_PERCENT" progress "Replicate $SAMPLE_INDEX of $SAMPLE_COUNT: HISAT2 alignment and BAM sorting"
    # shellcheck disable=SC2086
    hisat2 -p "$THREADS" $HISAT2_EXTRA -x "$WORK_DIR/index/genome" \
      -U "$CLEAN_R1" 2>"$LOG_DIR/${SAMPLE}.hisat2.log" |
      samtools sort -@ "$THREADS" -o "$BAM" -
  fi

  progress 5 "$BAM_PERCENT" progress "Replicate $SAMPLE_INDEX of $SAMPLE_COUNT: BAM QC and per-base coverage"
  samtools index -@ "$THREADS" "$BAM"
  samtools flagstat -@ "$THREADS" "$BAM" >"$LOG_DIR/${SAMPLE}.flagstat.log"
  samtools idxstats "$BAM" >"$LOG_DIR/${SAMPLE}.idxstats.tsv"
  bedtools genomecov -d -ibam "$BAM" >"$ORG_DIR/base_cov_${SAMPLE}"
  progress 5 "$SAMPLE_END" progress "Finished replicate $SAMPLE_INDEX of $SAMPLE_COUNT: $SAMPLE"
done

EXPECTED_BASES=$(awk 'BEGIN{n=0} !/^>/{gsub(/[[:space:]]/,""); n+=length($0)} END{print n}' "$REFERENCE_FA")
for coverage in "$ORG_DIR"/base_cov_*; do
  OBSERVED_BASES=$(wc -l < "$coverage" | tr -d ' ')
  [[ "$OBSERVED_BASES" -eq "$EXPECTED_BASES" ]] || {
    echo "Coverage length mismatch for $coverage: $OBSERVED_BASES rows, expected $EXPECTED_BASES." >&2
    exit 1
  }
done

python "$SCRIPT_DIR/scripts/summarize_replicate_qc.py" \
  --samples-tsv "$SAMPLES_TSV" \
  --log-dir "$LOG_DIR" \
  --coverage-dir "$ORG_DIR" \
  --output-dir "$QC_DIR" | tee "$LOG_DIR/replicate_qc.log"

progress 5 65 done "All biological replicates processed; fastp QC, BAM files, and coverage data created"

progress 6 66 start "Integrating per-base coverage across real replicates"
echo "Integrating per-base coverage"
python "$SCRIPT_DIR/scripts/integrate_multicontig.py" \
  --organism "$PROJECT_ID" \
  --data-root "$DATA_ROOT" \
  --annotation-name gene_annotation.bed \
  --coverage-prefix base_cov \
  --samples-tsv "$SAMPLES_TSV" \
  --topology-file "$TOPOLOGY_FILE" \
  --output "$DATA_ROOT/data_integrated.pkl" | tee "$LOG_DIR/integrate.log"
progress 6 72 done "Real replicate coverage integrated without averaging"

progress 7 73 start "Preparing replicate-aware neural-network input"
echo "Resampling and formatting separate replicate channels"
python "$SCRIPT_DIR/scripts/prepare_replicate_input.py" \
  --integrated "$DATA_ROOT/data_integrated.pkl" \
  --output "$DATA_ROOT/data_replicate_aware.npz" \
  --gene-pairs "$ORG_DIR/gene_pairs.csv" | tee "$LOG_DIR/process.log"
progress 7 78 done "Replicate-aware neural-network input prepared"

progress 8 79 start "Running the ten OpDetect models with replicate consensus"
echo "Running the ten supplied OpDetect models with balanced replicate arrangements"
TF_CPP_MIN_LOG_LEVEL=3 CUDA_VISIBLE_DEVICES=-1 python "$SCRIPT_DIR/scripts/predict_opdetect.py" \
  --repo "$OPDETECT_REPO" \
  --processed "$DATA_ROOT/data_replicate_aware.npz" \
  --gene-pairs "$ORG_DIR/gene_pairs.csv" \
  --threshold "$PREDICTION_THRESHOLD" \
  --min-support "$MIN_REPLICATE_SUPPORT" \
  --arrangement-map-output "$RESULT_DIR/replicate-channel-arrangements.tsv" \
  --output "$RESULT_DIR/${PROJECT_ID}.gene-pair-predictions.csv" \
  | tee "$LOG_DIR/predict.log"
progress 8 92 done "Replicate-consensus OpDetect predictions finished"

progress 9 93 start "Grouping robust positive gene pairs into operons"
python "$SCRIPT_DIR/scripts/pairs_to_operons.py" \
  --predictions "$RESULT_DIR/${PROJECT_ID}.gene-pair-predictions.csv" \
  --annotation-bed "$ORG_DIR/gene_annotation.bed" \
  --topology-file "$TOPOLOGY_FILE" \
  --threshold "$PREDICTION_THRESHOLD" \
  --min-support "$MIN_REPLICATE_SUPPORT" \
  --output "$RESULT_DIR/${PROJECT_ID}.predicted-operons.tsv" \
  | tee "$LOG_DIR/group_operons.log"

python "$SCRIPT_DIR/scripts/operons_to_bedgraph.py" \
  --operons "$RESULT_DIR/${PROJECT_ID}.predicted-operons.tsv" \
  --annotation-bed "$ORG_DIR/gene_annotation.bed" \
  --output "$RESULT_DIR/${PROJECT_ID}.predicted-operons.bedgraph" \
  | tee "$LOG_DIR/operon_bedgraph.log"
PREDICTIONS_FILE="$RESULT_DIR/${PROJECT_ID}.gene-pair-predictions.csv"
OPERONS_FILE="$RESULT_DIR/${PROJECT_ID}.predicted-operons.tsv"
OPERON_BEDGRAPH_FILE="$RESULT_DIR/${PROJECT_ID}.predicted-operons.bedgraph"
[[ -s "$PREDICTIONS_FILE" ]] || {
  echo "Expected prediction output was not created or is empty: $PREDICTIONS_FILE" >&2
  exit 1
}
[[ -s "$OPERONS_FILE" ]] || {
  echo "Expected operon output was not created or is empty: $OPERONS_FILE" >&2
  exit 1
}
[[ -s "$OPERON_BEDGRAPH_FILE" ]] || {
  echo "Expected predicted-operon bedGraph was not created or is empty: $OPERON_BEDGRAPH_FILE" >&2
  exit 1
}
progress 9 97 done "Robust candidate operons and the final IGV bedGraph generated"
cp -f "$STEP_TIMING_FILE" "$RESULT_DIR/step-timings.tsv" 2>/dev/null || true

echo
echo "Pipeline complete"
echo "Gene-pair probabilities: $PREDICTIONS_FILE"
echo "Candidate operon groups:  $OPERONS_FILE"
echo "Replicate QC:            $QC_DIR"
echo "Replicate arrangements:  $RESULT_DIR/replicate-channel-arrangements.tsv"
echo "Contig topology:          $TOPOLOGY_FILE"
echo "Predicted-operon bedGraph: $OPERON_BEDGRAPH_FILE"
echo "Logs:                     $LOG_DIR"
echo "Verified result files:"
ls -lh "$PREDICTIONS_FILE" "$OPERONS_FILE" "$OPERON_BEDGRAPH_FILE"
