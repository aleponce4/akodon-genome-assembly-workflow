#!/usr/bin/env bash
# Stage 19: retain the longest isoform per model and export CDS/protein FASTA files.

set -euo pipefail

CONFIG_PATH="${1:-${CONFIG:-}}"
[[ -n "$CONFIG_PATH" ]] || { echo "ERROR: config path is required" >&2; exit 1; }
CONFIG_DIR="$(cd "$(dirname "$CONFIG_PATH")" && pwd)"
PIPELINE_ROOT="$(cd "$CONFIG_DIR/.." && pwd)"

# shellcheck source=scripts/lib/common.sh
source "$PIPELINE_ROOT/scripts/lib/common.sh"
source_config "$CONFIG_PATH"
ensure_base_dirs

sample_id="$(current_annotation_sample_id)"
genome_fasta="$(annotation_simplified_genome "$sample_id")"
manifest_file="$(annotation_isoform_root "$sample_id")/processed_models.tsv"

ensure_dir "$(annotation_isoform_root "$sample_id")"
printf 'model\tgtf\n' > "$manifest_file"

declare -a model_names=()
declare -a model_gtfs=()

for predictor in galba braker2 braker3; do
    enable_var="$(predictor_enable_var "$predictor")"
    truthy "${!enable_var:-0}" || continue
    gtf_path="$(annotation_predictor_gtf "$predictor" "$sample_id")"
    if [[ -f "$gtf_path" ]]; then
        model_names+=("$predictor")
        model_gtfs+=("$gtf_path")
    fi
done

if [[ -d "$(annotation_tsebra_current_dir "$sample_id")" ]]; then
    while IFS= read -r gtf_path; do
        config_name="$(basename "$(dirname "$gtf_path")")"
        model_names+=("$config_name")
        model_gtfs+=("$gtf_path")
        # -L is required: tsebra_current is a symlink (stage 18), and plain
        # `find` does not descend into a symlinked start point.
    done < <(find -L "$(annotation_tsebra_current_dir "$sample_id")" -type f -name 'tsebra_*.gtf' | sort)
fi

(( ${#model_names[@]} > 0 )) || die "No annotation GTF files were found for isoform filtering."

if smoke_mode; then
    log "Smoke mode: creating mock isoform-filtered outputs"
    for idx in "${!model_names[@]}"; do
        model_name="${model_names[$idx]}"
        input_gtf="${model_gtfs[$idx]}"
        output_dir="$(annotation_isoform_dir "$model_name" "$sample_id")"
        output_gtf="$(annotation_isoform_gtf "$model_name" "$sample_id")"

        ensure_dir "$output_dir"
        write_smoke_gtf "$output_gtf" "$(annotation_header_name_stem "$sample_id")1"
        write_smoke_fasta "$(annotation_isoform_aa "$model_name" "$sample_id")" "smoke_${model_name}" "MPEPTIDESEQ"
        printf '%s\t%s\n' "$model_name" "$input_gtf" >> "$manifest_file"
    done
    exit 0
fi

[[ -f "$BRAKER_SIF" ]] || die "BRAKER Singularity image not found: $BRAKER_SIF"
[[ -f "$ANNOTATION_LONGEST_ISOFORM_SCRIPT" ]] || die "Longest isoform script not found: $ANNOTATION_LONGEST_ISOFORM_SCRIPT"
[[ -f "$genome_fasta" ]] || die "Simplified annotation genome not found: $genome_fasta"
command -v "$SINGULARITY_BIN" >/dev/null 2>&1 || die "Singularity executable not found: $SINGULARITY_BIN"

# Discover TSEBRA's module directory inside the container rather than hardcoding
# it, so a container layout change fails here with a clear message instead of
# mid-loop with an ImportError. Honour an explicit override if given.
tsebra_python_dir="${TSEBRA_PYTHON_DIR:-}"
if [[ -z "$tsebra_python_dir" ]]; then
    tsebra_python_dir="$("$SINGULARITY_BIN" exec "$BRAKER_SIF" \
        bash -c 'dirname "$(readlink -f "$(command -v tsebra.py)")"' 2>/dev/null || true)"
fi
[[ -n "$tsebra_python_dir" ]] \
    || die "Could not locate TSEBRA's module directory inside $BRAKER_SIF. Set TSEBRA_PYTHON_DIR explicitly (it is /opt/TSEBRA/bin in the standard braker3 image)."
log "TSEBRA modules for get_longest_isoform.py: $tsebra_python_dir"

cd "$(annotation_isoform_root "$sample_id")"

for idx in "${!model_names[@]}"; do
    model_name="${model_names[$idx]}"
    input_gtf="${model_gtfs[$idx]}"
    output_dir="$(annotation_isoform_dir "$model_name" "$sample_id")"
    output_gtf="$(annotation_isoform_gtf "$model_name" "$sample_id")"
    output_prefix="$(annotation_isoform_prefix "$model_name" "$sample_id")"

    ensure_dir "$output_dir"

    log "Selecting longest isoforms for model $model_name"
    # get_longest_isoform.py is a TSEBRA utility and imports TSEBRA's own
    # modules (genome_anno). It lives OUTSIDE the container, so invoking it as
    # `python3 <host path>` makes sys.path[0] the host bin directory, where
    # genome_anno.py does not exist -- ModuleNotFoundError four seconds in,
    # after BRAKER3 has already spent ~40 h upstream. tsebra.py itself works
    # only because it runs from inside TSEBRA's own directory.
    "$SINGULARITY_BIN" exec -B "$PROJECT_ROOT:$PROJECT_ROOT" \
        --env "PYTHONPATH=${tsebra_python_dir}${PYTHONPATH:+:$PYTHONPATH}" \
        "$BRAKER_SIF" \
        python3 "$ANNOTATION_LONGEST_ISOFORM_SCRIPT" -g "$input_gtf" -o "$output_gtf"

    "$SINGULARITY_BIN" exec -B "$PROJECT_ROOT:$PROJECT_ROOT" "$BRAKER_SIF" \
        getAnnoFastaFromJoingenes.py -g "$genome_fasta" -o "$output_prefix" -f "$output_gtf"

    [[ -f "$(annotation_isoform_aa "$model_name" "$sample_id")" ]] || die "Isoform-filtered protein FASTA was not created: $(annotation_isoform_aa "$model_name" "$sample_id")"
    printf '%s\t%s\n' "$model_name" "$input_gtf" >> "$manifest_file"
done
