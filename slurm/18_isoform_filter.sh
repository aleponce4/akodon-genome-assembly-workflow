#!/usr/bin/env bash
# Stage 18: retain the longest isoform per model and export CDS/protein FASTA files.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="${1:-${CONFIG:-}}"

# shellcheck source=../scripts/lib/common.sh
source "$SCRIPT_DIR/../scripts/lib/common.sh"
source_config "$CONFIG_PATH"
ensure_base_dirs

sample_id="$ANNOTATION_SAMPLE_ID"
genome_fasta="$(annotation_simplified_genome "$sample_id")"
manifest_file="$(annotation_isoform_root)/processed_models.tsv"

ensure_dir "$(annotation_isoform_root)"
printf 'model\tgtf\n' > "$manifest_file"

declare -a model_names=()
declare -a model_gtfs=()

for predictor in galba braker2 braker3; do
    gtf_path="$(annotation_predictor_gtf "$predictor")"
    if [[ -f "$gtf_path" ]]; then
        model_names+=("$predictor")
        model_gtfs+=("$gtf_path")
    fi
done

if [[ -d "$(annotation_tsebra_current_dir)" ]]; then
    while IFS= read -r gtf_path; do
        config_name="$(basename "$(dirname "$gtf_path")")"
        model_names+=("$config_name")
        model_gtfs+=("$gtf_path")
    done < <(find "$(annotation_tsebra_current_dir)" -type f -name 'tsebra_*.gtf' | sort)
fi

(( ${#model_names[@]} > 0 )) || die "No annotation GTF files were found for isoform filtering."

if smoke_mode; then
    log "Smoke mode: creating mock isoform-filtered outputs"
    for idx in "${!model_names[@]}"; do
        model_name="${model_names[$idx]}"
        input_gtf="${model_gtfs[$idx]}"
        output_dir="$(annotation_isoform_dir "$model_name")"
        output_gtf="$(annotation_isoform_gtf "$model_name")"

        ensure_dir "$output_dir"
        write_smoke_gtf "$output_gtf" "$(annotation_header_name_stem "$sample_id")1"
        write_smoke_fasta "$(annotation_isoform_aa "$model_name")" "smoke_${model_name}" "MPEPTIDESEQ"
        printf '%s\t%s\n' "$model_name" "$input_gtf" >> "$manifest_file"
    done
    exit 0
fi

[[ -f "$BRAKER_SIF" ]] || die "BRAKER Singularity image not found: $BRAKER_SIF"
[[ -f "$ANNOTATION_LONGEST_ISOFORM_SCRIPT" ]] || die "Longest isoform script not found: $ANNOTATION_LONGEST_ISOFORM_SCRIPT"
[[ -f "$genome_fasta" ]] || die "Simplified annotation genome not found: $genome_fasta"
command -v "$SINGULARITY_BIN" >/dev/null 2>&1 || die "Singularity executable not found: $SINGULARITY_BIN"

for idx in "${!model_names[@]}"; do
    model_name="${model_names[$idx]}"
    input_gtf="${model_gtfs[$idx]}"
    output_dir="$(annotation_isoform_dir "$model_name")"
    output_gtf="$(annotation_isoform_gtf "$model_name")"
    output_prefix="$(annotation_isoform_prefix "$model_name")"

    ensure_dir "$output_dir"

    log "Selecting longest isoforms for model $model_name"
    "$SINGULARITY_BIN" exec -B "$PROJECT_ROOT:$PROJECT_ROOT" "$BRAKER_SIF" \
        python3 "$ANNOTATION_LONGEST_ISOFORM_SCRIPT" -g "$input_gtf" -o "$output_gtf"

    "$SINGULARITY_BIN" exec -B "$PROJECT_ROOT:$PROJECT_ROOT" "$BRAKER_SIF" \
        getAnnoFastaFromJoingenes.py -g "$genome_fasta" -o "$output_prefix" -f "$output_gtf"

    [[ -f "$(annotation_isoform_aa "$model_name")" ]] || die "Isoform-filtered protein FASTA was not created: $(annotation_isoform_aa "$model_name")"
    printf '%s\t%s\n' "$model_name" "$input_gtf" >> "$manifest_file"
done
