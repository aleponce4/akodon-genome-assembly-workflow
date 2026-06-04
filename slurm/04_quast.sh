#!/usr/bin/env bash
# Stage 04: run QUAST on the filtered assemblies.

set -euo pipefail

CONFIG_PATH="${1:-${CONFIG:-}}"
[[ -n "$CONFIG_PATH" ]] || { echo "ERROR: config path is required" >&2; exit 1; }
CONFIG_DIR="$(cd "$(dirname "$CONFIG_PATH")" && pwd)"
PIPELINE_ROOT="$(cd "$CONFIG_DIR/.." && pwd)"

# shellcheck source=scripts/lib/common.sh
source "$PIPELINE_ROOT/scripts/lib/common.sh"
source_config "$CONFIG_PATH"
ensure_base_dirs

declare -a quast_inputs=()
declare -a quast_labels=()
sample_total="$(sample_count)"

for ((idx = 0; idx < sample_total; idx++)); do
    sample_id="$(sample_id_by_index "$idx")"
    fasta_path="$(filtered_fasta "$sample_id")"
    [[ -f "$fasta_path" ]] || die "Filtered FASTA not found: $fasta_path"
    quast_inputs+=("$fasta_path")
    quast_labels+=("$(basename "$fasta_path" .fasta)")
done

declare -a quast_args=(
    -o "$QUAST_DIR"
    --threads "${SLURM_CPUS_PER_TASK:-$QUAST_CPUS}"
    --large
    --eukaryote
    --fragmented
    --split-scaffolds
    --circos
    -l "$(IFS=,; printf '%s' "${quast_labels[*]}")"
)

if truthy "$ENABLE_QUAST_REFERENCE"; then
    [[ -f "$QUAST_REFERENCE" ]] || die "QUAST reference not found: $QUAST_REFERENCE"
    quast_args+=(-r "$QUAST_REFERENCE")
fi

if smoke_mode; then
    log "Smoke mode: creating mock QUAST report"
    {
        printf 'Assembly'
        for label in "${quast_labels[@]}"; do
            printf '\t%s' "$label"
        done
        printf '\n'

        printf '# contigs'
        for label in "${quast_labels[@]}"; do
            printf '\t1'
        done
        printf '\n'

        printf 'Total length'
        for label in "${quast_labels[@]}"; do
            printf '\t32'
        done
        printf '\n'

        printf 'N50'
        for label in "${quast_labels[@]}"; do
            printf '\t32'
        done
        printf '\n'
    } > "$(quast_report_tsv)"
    exit 0
fi

activate_quast_env

log "Running QUAST on ${#quast_inputs[@]} filtered assemblies"
cd "$QUAST_DIR"
"$QUAST_BIN" "${quast_args[@]}" "${quast_inputs[@]}"
[[ -s "$(quast_report_tsv)" ]] || die "QUAST report was not created: $(quast_report_tsv)"
