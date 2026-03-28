#!/usr/bin/env bash
# Stage 04: run QUAST on the filtered assemblies.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="${1:-${CONFIG:-}}"

# shellcheck source=../scripts/lib/common.sh
source "$SCRIPT_DIR/../scripts/lib/common.sh"
source_config "$CONFIG_PATH"
ensure_base_dirs

declare -a quast_inputs=()
sample_total="$(sample_count)"

for ((idx = 0; idx < sample_total; idx++)); do
    sample_id="$(sample_id_by_index "$idx")"
    fasta_path="$(filtered_fasta "$sample_id")"
    [[ -f "$fasta_path" ]] || die "Filtered FASTA not found: $fasta_path"
    quast_inputs+=("$fasta_path")
done

declare -a quast_args=(
    -o "$QUAST_DIR"
    --threads "${SLURM_CPUS_PER_TASK:-$QUAST_CPUS}"
    --large
    --eukaryote
    --fragmented
    --split-scaffolds
    --circos
)

if truthy "$ENABLE_QUAST_REFERENCE"; then
    [[ -f "$QUAST_REFERENCE" ]] || die "QUAST reference not found: $QUAST_REFERENCE"
    quast_args+=(-r "$QUAST_REFERENCE")
fi

if smoke_mode; then
    log "Smoke mode: creating mock QUAST report"
    cat > "$(quast_report_tsv)" <<EOF
Assembly	# contigs	Total length
smoke	1	32
EOF
    exit 0
fi

activate_quast_env

log "Running QUAST on ${#quast_inputs[@]} filtered assemblies"
"$QUAST_BIN" "${quast_args[@]}" "${quast_inputs[@]}"
[[ -s "$(quast_report_tsv)" ]] || die "QUAST report was not created: $(quast_report_tsv)"
