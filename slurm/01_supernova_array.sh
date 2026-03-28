#!/usr/bin/env bash
# Stage 01: run Supernova assembly for each sample.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="${1:-${CONFIG:-}}"

# shellcheck source=../scripts/lib/common.sh
source "$SCRIPT_DIR/../scripts/lib/common.sh"
source_config "$CONFIG_PATH"
ensure_base_dirs

require_var DATA_DIR
require_var SUPERNOVA_BIN

sample_index="${SLURM_ARRAY_TASK_ID:?SLURM_ARRAY_TASK_ID is required}"
sample_id="$(sample_id_by_index "$sample_index")"
fastq_sample="$(fastq_sample_by_index "$sample_index")"
run_id="$(supernova_run_id "$fastq_sample")"
run_dir="$(supernova_run_dir "$fastq_sample")"
assembly_dir="$(supernova_asmdir "$fastq_sample")"
local_cores="${SLURM_CPUS_PER_TASK:-$SUPERNOVA_LOCALCORES}"

if smoke_mode; then
    log "Smoke mode: creating mock Supernova assembly directories"
    ensure_dir "$run_dir"
    ensure_dir "$assembly_dir"
    exit 0
fi

[[ -x "$SUPERNOVA_BIN" ]] || die "Supernova executable not found: $SUPERNOVA_BIN"
[[ -d "$DATA_DIR" ]] || die "FASTQ directory not found: $DATA_DIR"

log "Running Supernova for sample $sample_id ($fastq_sample)"
cd "$SUPERNOVA_RUN_DIR"
"$SUPERNOVA_BIN" run \
    --id="$run_id" \
    --fastqs="$DATA_DIR" \
    --sample="$fastq_sample" \
    --localcores="$local_cores" \
    --localmem="$SUPERNOVA_LOCALMEM" \
    --maxreads="$SUPERNOVA_MAXREADS"

[[ -d "$run_dir" ]] || die "Supernova run directory was not created: $run_dir"
[[ -d "$assembly_dir" ]] || die "Supernova assembly directory was not created: $assembly_dir"
