#!/usr/bin/env bash
set -Eeuo pipefail
SRC=${1:?source package path required}
DST=${2:-/root/opdetect_pipeline}
mkdir -p "$DST/scripts"
cp "$SRC/run_opdetect_pipeline.sh" "$DST/run_opdetect_pipeline.sh"
cp "$SRC/environment_ready.sh" "$DST/environment_ready.sh"
cp "$SRC/quick_environment_status.sh" "$DST/quick_environment_status.sh"
cp "$SRC/check_wsl_environment.sh" "$DST/check_wsl_environment.sh"
cp "$SRC/stop_run.sh" "$DST/stop_run.sh"
if [[ -f "$SRC/resume_last_model_step.sh" ]]; then cp "$SRC/resume_last_model_step.sh" "$DST/resume_last_model_step.sh"; fi
if [[ -f "$SRC/generate_tracks_for_last_run.sh" ]]; then cp "$SRC/generate_tracks_for_last_run.sh" "$DST/generate_tracks_for_last_run.sh"; fi
if [[ -f "$SRC/export_simplified_last_run.sh" ]]; then cp "$SRC/export_simplified_last_run.sh" "$DST/export_simplified_last_run.sh"; fi
cp "$SRC/scripts/gff_to_opdetect_bed.py" "$DST/scripts/gff_to_opdetect_bed.py"
cp "$SRC/scripts/integrate_multicontig.py" "$DST/scripts/integrate_multicontig.py"
cp "$SRC/scripts/prepare_replicate_input.py" "$DST/scripts/prepare_replicate_input.py"
cp "$SRC/scripts/summarize_replicate_qc.py" "$DST/scripts/summarize_replicate_qc.py"
cp "$SRC/scripts/build_topology.py" "$DST/scripts/build_topology.py"
cp "$SRC/scripts/predict_opdetect.py" "$DST/scripts/predict_opdetect.py"
cp "$SRC/scripts/pairs_to_operons.py" "$DST/scripts/pairs_to_operons.py"
cp "$SRC/scripts/coverage_to_bedgraph.py" "$DST/scripts/coverage_to_bedgraph.py"
cp "$SRC/scripts/operons_to_bed.py" "$DST/scripts/operons_to_bed.py"
cp "$SRC/scripts/operons_to_bedgraph.py" "$DST/scripts/operons_to_bedgraph.py"
cp "$SRC/scripts/table_to_xlsx.py" "$DST/scripts/table_to_xlsx.py"
cp "$SRC/scripts/correlations_to_xlsx.py" "$DST/scripts/correlations_to_xlsx.py"
cp "$SRC/scripts/text_report_to_docx.py" "$DST/scripts/text_report_to_docx.py"
sed -i 's/\r$//' "$DST/run_opdetect_pipeline.sh" "$DST/environment_ready.sh" "$DST/quick_environment_status.sh" "$DST/check_wsl_environment.sh" "$DST/stop_run.sh"
chmod +x "$DST/run_opdetect_pipeline.sh" "$DST/environment_ready.sh" "$DST/quick_environment_status.sh" "$DST/check_wsl_environment.sh" "$DST/stop_run.sh"
if [[ -f "$DST/resume_last_model_step.sh" ]]; then sed -i 's/\r$//' "$DST/resume_last_model_step.sh"; chmod +x "$DST/resume_last_model_step.sh"; fi
if [[ -f "$DST/generate_tracks_for_last_run.sh" ]]; then sed -i 's/\r$//' "$DST/generate_tracks_for_last_run.sh"; chmod +x "$DST/generate_tracks_for_last_run.sh"; fi
if [[ -f "$DST/export_simplified_last_run.sh" ]]; then sed -i 's/\r$//' "$DST/export_simplified_last_run.sh"; chmod +x "$DST/export_simplified_last_run.sh"; fi
