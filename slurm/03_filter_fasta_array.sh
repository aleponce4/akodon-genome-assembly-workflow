#!/usr/bin/env bash
# Stage 03: filter the canonical pseudohap FASTA before QC and repeat analysis.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="${1:-${CONFIG:-}}"

# shellcheck source=../scripts/lib/common.sh
source "$SCRIPT_DIR/../scripts/lib/common.sh"
source_config "$CONFIG_PATH"
ensure_base_dirs

sample_index="${SLURM_ARRAY_TASK_ID:?SLURM_ARRAY_TASK_ID is required}"
sample_id="$(sample_id_by_index "$sample_index")"
input_fasta="$(canonical_pseudohap "$sample_id")"
output_fasta="$(filtered_fasta "$sample_id")"

[[ -f "$input_fasta" ]] || die "Input assembly not found: $input_fasta"

if smoke_mode; then
    log "Smoke mode: creating filtered FASTA from mock pseudohap"
    gzip -cd "$input_fasta" > "$output_fasta"
    [[ -s "$output_fasta" ]] || die "Filtered FASTA is missing or empty: $output_fasta"
    exit 0
fi

activate_conda_env "$FILTER_ENV" "${FILTER_ENV_PREFIX:-}"

log "Filtering scaffolds shorter than $MIN_SCAFFOLD_BP bp for sample $sample_id"
seqkit seq -m "$MIN_SCAFFOLD_BP" "$input_fasta" > "$output_fasta"
[[ -s "$output_fasta" ]] || die "Filtered FASTA is missing or empty: $output_fasta"
