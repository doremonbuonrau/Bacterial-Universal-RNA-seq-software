#!/usr/bin/env bash
set -Eeuo pipefail

resolve_conda_root() {
  for candidate in /root/.local/share/prok-rnaseq/miniforge3 /root/miniforge3; do
    if [[ -x "$candidate/bin/conda" && -r "$candidate/etc/profile.d/conda.sh" ]]; then printf '%s\n' "$candidate"; return 0; fi
  done
  return 1
}

DESTINATION=${1:?Windows destination must be supplied as a WSL path}
PIPELINE_ROOT=/root/opdetect_pipeline
CONDA_ROOT=$(resolve_conda_root) || { echo "OpDetect could not find the shared/legacy Miniforge installation." >&2; exit 10; }
source "$CONDA_ROOT/etc/profile.d/conda.sh"
conda activate opdetect-pipeline

LATEST_PREDICTIONS=$(find /root/opdetect_runs -mindepth 3 -maxdepth 3 -type f -name '*.gene-pair-predictions.csv' \
  -printf '%T@\t%p\n' 2>/dev/null | sort -nr | head -n 1 | cut -f2-)
[[ -n "$LATEST_PREDICTIONS" ]] || { echo 'No completed OpDetect prediction table was found.' >&2; exit 1; }
RESULT_DIR=$(dirname "$LATEST_PREDICTIONS")
RUN_ROOT=$(dirname "$RESULT_DIR")
PROJECT_FILE=$(basename "$LATEST_PREDICTIONS")
PROJECT_ID=${PROJECT_FILE%.gene-pair-predictions.csv}
OPERONS="$RESULT_DIR/${PROJECT_ID}.predicted-operons.tsv"
ANNOTATION="$RUN_ROOT/opdetect_data/$PROJECT_ID/gene_annotation.bed"
LOG_DIR="$RUN_ROOT/logs"
BAM_DIR="$RUN_ROOT/work/bam"
IGV_INPUT_DIR="$RESULT_DIR/igv-inputs"
[[ -s "$OPERONS" ]] || { echo "Missing predicted-operon table: $OPERONS" >&2; exit 1; }
[[ -s "$ANNOTATION" ]] || { echo "Missing converted annotation: $ANNOTATION" >&2; exit 1; }

clean_stem() {
  printf '%s' "$1" | sed -E 's/[._-]+/ /g; s/[^A-Za-z0-9 ()]+/ /g; s/[[:space:]]+/ /g; s/^ //; s/ $//'
}
DISPLAY_PROJECT=$(clean_stem "$PROJECT_ID")
[[ -n "$DISPLAY_PROJECT" ]] || DISPLAY_PROJECT='OpDetect project'

mkdir -p "$RESULT_DIR"
PRED_XLSX="$RESULT_DIR/${PROJECT_ID}.gene-pair-predictions.xlsx"
OPERON_XLSX="$RESULT_DIR/${PROJECT_ID}.predicted-operons.xlsx"
OPERON_BEDGRAPH="$RESULT_DIR/${PROJECT_ID}.predicted-operons.bedgraph"
PEARSON_TSV="$RESULT_DIR/qc/replicate-pearson.tsv"
SPEARMAN_TSV="$RESULT_DIR/qc/replicate-spearman.tsv"
CORRELATIONS_XLSX="$RESULT_DIR/replicate-correlations.xlsx"
python "$PIPELINE_ROOT/scripts/table_to_xlsx.py" \
  --input "$LATEST_PREDICTIONS" --delimiter comma \
  --sheet-name 'Gene pair predictions' --output "$PRED_XLSX"
python "$PIPELINE_ROOT/scripts/table_to_xlsx.py" \
  --input "$OPERONS" --delimiter tab --sheet-name 'Predicted operons' \
  --drop-columns 'chromosome,topology,wraps_origin' --output "$OPERON_XLSX"
python "$PIPELINE_ROOT/scripts/operons_to_bedgraph.py" \
  --operons "$OPERONS" --annotation-bed "$ANNOTATION" --output "$OPERON_BEDGRAPH"
if [[ -s "$PEARSON_TSV" && -s "$SPEARMAN_TSV" ]]; then
  python "$PIPELINE_ROOT/scripts/correlations_to_xlsx.py" \
    --pearson "$PEARSON_TSV" --spearman "$SPEARMAN_TSV" \
    --output "$CORRELATIONS_XLSX"
fi

rm -rf "$DESTINATION"
mkdir -p "$DESTINATION/IGV"
cp -f "$PRED_XLSX" "$DESTINATION/$DISPLAY_PROJECT gene pair predictions.xlsx"
cp -f "$OPERON_XLSX" "$DESTINATION/$DISPLAY_PROJECT predicted operons.xlsx"
cp -f "$OPERON_BEDGRAPH" "$DESTINATION/IGV/$DISPLAY_PROJECT predicted operons.bedgraph"
if [[ -s "$CORRELATIONS_XLSX" ]]; then
  cp -f "$CORRELATIONS_XLSX" "$DESTINATION/Replicate correlations.xlsx"
fi

inputs_copied=0
if [[ -d "$IGV_INPUT_DIR" ]]; then
  shopt -s nullglob
  igv_inputs=("$IGV_INPUT_DIR"/*)
  if (( ${#igv_inputs[@]} > 0 )); then
    cp -f "${igv_inputs[@]}" "$DESTINATION/IGV/"
    inputs_copied=${#igv_inputs[@]}
  fi
  shopt -u nullglob
fi

# Older runs did not archive their original FASTA and annotation internally.
# Recover their recorded paths from the Word run report when the original files
# still exist on the Windows drive.
if (( inputs_copied == 0 )) && [[ -s "$RESULT_DIR/OpDetect Run Report.docx" ]]; then
  mapfile -t recorded_inputs < <(python - "$RESULT_DIR/OpDetect Run Report.docx" <<'PYINPUTS'
from docx import Document
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = "
".join(paragraph.text for paragraph in Document(path).paragraphs)
for line in text.splitlines():
    stripped = line.strip()
    for prefix in ("Reference FASTA:", "Annotation GFF3:", "Annotation GFF/GFF3/GTF:"):
        if stripped.startswith(prefix):
            value = stripped[len(prefix):].strip()
            if value:
                print(value)
PYINPUTS
  )
  for input_path in "${recorded_inputs[@]}"; do
    if [[ -s "$input_path" ]]; then
      cp -f "$input_path" "$DESTINATION/IGV/$(basename "$input_path")"
      inputs_copied=$((inputs_copied + 1))
    fi
  done
fi
if (( inputs_copied == 0 )); then
  echo 'WARNING: The original FASTA and annotation could not be located for this older run. Copy them into the IGV folder manually.' >&2
fi

if [[ -s "$RESULT_DIR/OpDetect Run Report.docx" ]]; then
  cp -f "$RESULT_DIR/OpDetect Run Report.docx" "$DESTINATION/OpDetect Run Report.docx"
else
  REPORT_TEXT="$RUN_ROOT/simplified-recovery-report.txt"
  {
    echo 'OpDetect Run Report'
    echo '===================' 
    echo 'Recovered from an earlier successful run.'
    echo "Project: $PROJECT_ID"
    echo "Linux run folder: $RUN_ROOT"
    echo ''
    echo '[IGV PREDICTED-OPERON BEDGRAPH]'
    echo 'The fourth column is signed mean OpDetect model probability: positive for forward strand and negative for reverse strand.'
    echo 'It is not a statistical p-value and does not guarantee biological correctness.'
    echo ''
    echo '[AVAILABLE LOGS]'
    find "$LOG_DIR" -maxdepth 1 -type f -printf '%f\t%s bytes\n' | sort || true
  } > "$REPORT_TEXT"
  python "$PIPELINE_ROOT/scripts/text_report_to_docx.py" \
    --input "$REPORT_TEXT" --output "$RESULT_DIR/OpDetect Run Report.docx" --title 'OpDetect Run Report'
  cp -f "$RESULT_DIR/OpDetect Run Report.docx" "$DESTINATION/OpDetect Run Report.docx"
fi

shopt -s nullglob
for html in "$LOG_DIR"/*.fastp.html; do
  sample=$(basename "$html" .fastp.html)
  display_sample=$(clean_stem "$sample")
  [[ -n "$display_sample" ]] || display_sample='sample'
  cp -f "$html" "$DESTINATION/$display_sample fastp.html"
done
for bam in "$BAM_DIR"/*.sorted.bam; do
  sample=$(basename "$bam" .sorted.bam)
  display_sample=$(clean_stem "$sample")
  [[ -n "$display_sample" ]] || display_sample='sample'
  cp -f "$bam" "$DESTINATION/IGV/$display_sample.bam"
  [[ -s "$bam.bai" ]] || { echo "Missing BAM index: $bam.bai" >&2; exit 1; }
  cp -f "$bam.bai" "$DESTINATION/IGV/$display_sample.bam.bai"
done
shopt -u nullglob

[[ -s "$DESTINATION/$DISPLAY_PROJECT gene pair predictions.xlsx" ]]
[[ -s "$DESTINATION/$DISPLAY_PROJECT predicted operons.xlsx" ]]
[[ -s "$DESTINATION/OpDetect Run Report.docx" ]]
[[ -s "$DESTINATION/IGV/$DISPLAY_PROJECT predicted operons.bedgraph" ]]
compgen -G "$DESTINATION/* fastp.html" >/dev/null
compgen -G "$DESTINATION/IGV/*.bam" >/dev/null
compgen -G "$DESTINATION/IGV/*.bam.bai" >/dev/null
printf 'PROJECT=%s\n' "$PROJECT_ID"
printf 'RUN_ROOT=%s\n' "$RUN_ROOT"
printf 'DESTINATION=%s\n' "$DESTINATION"
