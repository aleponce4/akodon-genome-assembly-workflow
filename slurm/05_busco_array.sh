#!/usr/bin/env bash
# Stage 05: run BUSCO on each filtered assembly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="${1:-${CONFIG:-}}"

# shellcheck source=../scripts/lib/common.sh
source "$SCRIPT_DIR/../scripts/lib/common.sh"
source_config "$CONFIG_PATH"
ensure_base_dirs

sample_index="${SLURM_ARRAY_TASK_ID:?SLURM_ARRAY_TASK_ID is required}"
sample_id="$(sample_id_by_index "$sample_index")"
input_fasta="$(filtered_fasta "$sample_id")"
output_name="$(assembly_stem "$sample_id")"
sample_output_dir="$(busco_sample_dir "$sample_id")"

if smoke_mode; then
    log "Smoke mode: creating mock BUSCO output"
    ensure_dir "$sample_output_dir"
    cat > "$sample_output_dir/short_summary.specific.glires_odb10.${output_name}.txt" <<EOF
# BUSCO version is: smoke
C:100.0%[S:100.0%,D:0.0%],F:0.0%,M:0.0%,n:10
EOF
    exit 0
fi

activate_conda_env "$BUSCO_ENV" "${BUSCO_ENV_PREFIX:-}"

[[ -f "$input_fasta" ]] || die "Filtered FASTA not found: $input_fasta"
[[ -d "$BUSCO_LINEAGE_DIR" ]] || die "BUSCO lineage directory not found: $BUSCO_LINEAGE_DIR"

log "Running BUSCO for sample $sample_id"
busco \
    -i "$input_fasta" \
    -o "$output_name" \
    -l "$BUSCO_LINEAGE_DIR" \
    -m genome \
    -c "${SLURM_CPUS_PER_TASK:-$BUSCO_CPUS}" \
    --out_path "$BUSCO_DIR" \
    -f

[[ -d "$sample_output_dir" ]] || die "BUSCO output directory was not created: $sample_output_dir"
