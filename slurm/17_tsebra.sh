#!/usr/bin/env bash
# Stage 17: combine selected predictor outputs with TSEBRA.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="${1:-${CONFIG:-}}"

# shellcheck source=../scripts/lib/common.sh
source "$SCRIPT_DIR/../scripts/lib/common.sh"
source_config "$CONFIG_PATH"
ensure_base_dirs

sample_id="$ANNOTATION_SAMPLE_ID"
genome_fasta="$(annotation_simplified_genome "$sample_id")"
gtf1="$(annotation_predictor_gtf "$TSEBRA_GTF1_SOURCE")"
gtf2="$(annotation_predictor_gtf "$TSEBRA_GTF2_SOURCE")"
hints1="$(annotation_predictor_hints "$TSEBRA_GTF1_SOURCE")"
hints2="$(annotation_predictor_hints "$TSEBRA_GTF2_SOURCE")"
run_root="$(annotation_tsebra_runs_dir)"
timestamp="$(date +'%Y%m%d_%H%M%S')"
run_dir="$run_root/tsebra_$timestamp"
current_link="$(annotation_tsebra_current_dir)"

ensure_dir "$run_root"
ensure_dir "$run_dir"

if smoke_mode; then
    log "Smoke mode: creating mock TSEBRA outputs"
    mapfile -t config_files < <(compgen -G "$TSEBRA_CONFIG_GLOB" | sort || true)
    if (( ${#config_files[@]} == 0 )); then
        config_files=("smoke.cfg")
    fi

    for config_file in "${config_files[@]}"; do
        config_name="$(basename "$config_file" .cfg)"
        config_output_dir="$run_dir/$config_name"
        output_gtf="$config_output_dir/tsebra_${config_name}.gtf"
        output_prefix="$config_output_dir/tsebra_${config_name}"
        ensure_dir "$config_output_dir"
        write_smoke_gtf "$output_gtf" "$(annotation_header_name_stem "$sample_id")1"
        write_smoke_fasta "${output_prefix}.aa" "smoke_protein_${config_name}" "MPEPTIDESEQ"
    done
    ln -sfn "$run_dir" "$current_link"
    exit 0
fi

[[ -f "$BRAKER_SIF" ]] || die "BRAKER Singularity image not found: $BRAKER_SIF"
[[ -f "$genome_fasta" ]] || die "Simplified annotation genome not found: $genome_fasta"
[[ -f "$gtf1" ]] || die "First TSEBRA GTF not found: $gtf1"
[[ -f "$gtf2" ]] || die "Second TSEBRA GTF not found: $gtf2"
[[ -f "$hints1" ]] || die "First TSEBRA hints file not found: $hints1"
[[ -f "$hints2" ]] || die "Second TSEBRA hints file not found: $hints2"
command -v "$SINGULARITY_BIN" >/dev/null 2>&1 || die "Singularity executable not found: $SINGULARITY_BIN"

mapfile -t config_files < <(compgen -G "$TSEBRA_CONFIG_GLOB" | sort || true)
(( ${#config_files[@]} > 0 )) || die "No TSEBRA config files were found with glob: $TSEBRA_CONFIG_GLOB"

for config_file in "${config_files[@]}"; do
    config_name="$(basename "$config_file" .cfg)"
    config_output_dir="$run_dir/$config_name"
    output_gtf="$config_output_dir/tsebra_${config_name}.gtf"
    output_prefix="$config_output_dir/tsebra_${config_name}"

    ensure_dir "$config_output_dir"

    log "Running TSEBRA for config $config_name"
    "$SINGULARITY_BIN" exec -B "$PROJECT_ROOT:$PROJECT_ROOT" "$BRAKER_SIF" tsebra.py \
        -g "$gtf1,$gtf2" \
        -e "$hints1,$hints2" \
        -o "$output_gtf" \
        -c "$config_file"

    [[ -f "$output_gtf" ]] || die "TSEBRA GTF was not created: $output_gtf"

    "$SINGULARITY_BIN" exec -B "$PROJECT_ROOT:$PROJECT_ROOT" "$BRAKER_SIF" getAnnoFastaFromJoingenes.py \
        -g "$genome_fasta" \
        -o "$output_prefix" \
        -f "$output_gtf"
done

ln -sfn "$run_dir" "$current_link"
