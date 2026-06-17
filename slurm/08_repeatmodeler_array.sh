#!/usr/bin/env bash
# Stage 08: build sample-specific repeat libraries with RepeatModeler.

set -euo pipefail

CONFIG_PATH="${1:-${CONFIG:-}}"
[[ -n "$CONFIG_PATH" ]] || { echo "ERROR: config path is required" >&2; exit 1; }
CONFIG_DIR="$(cd "$(dirname "$CONFIG_PATH")" && pwd)"
PIPELINE_ROOT="$(cd "$CONFIG_DIR/.." && pwd)"

# shellcheck source=scripts/lib/common.sh
source "$PIPELINE_ROOT/scripts/lib/common.sh"
source_config "$CONFIG_PATH"
ensure_base_dirs

sample_index="${SLURM_ARRAY_TASK_ID:?SLURM_ARRAY_TASK_ID is required}"
sample_id="$(sample_id_by_index "$sample_index")"
input_fasta="$(filtered_fasta "$sample_id")"
workdir="$(repeatmodeler_workdir "$sample_id")"
database_name="$(assembly_stem "$sample_id")"

ensure_dir "$workdir"
cd "$workdir"

if smoke_mode; then
    log "Smoke mode: creating mock RepeatModeler classified library"
    write_smoke_fasta "$workdir/consensi.fa.classified" "${database_name}_repeat1#DNA" "ATGCGTATGCGTATGCGTATGCGTATGCGT"
    exit 0
fi

[[ -f "$input_fasta" ]] || die "Filtered FASTA not found: $input_fasta"
[[ -f "$REPEATMODELER_IMAGE" ]] || die "RepeatModeler image not found: $REPEATMODELER_IMAGE"
command -v "$SINGULARITY_BIN" >/dev/null 2>&1 || die "Singularity executable not found: $SINGULARITY_BIN"

log "Building RepeatModeler database for sample $sample_id"
"$SINGULARITY_BIN" exec "$REPEATMODELER_IMAGE" BuildDatabase -name "$database_name" "$input_fasta"

log "Running RepeatModeler for sample $sample_id"
repeatmodeler_args=(
    -threads "${SLURM_CPUS_PER_TASK:-$REPEATMODELER_CPUS}"
    -engine ncbi
    -database "$database_name"
)

if truthy "$REPEATMODELER_LTRSTRUCT"; then
    repeatmodeler_args+=(-LTRStruct)
fi

"$SINGULARITY_BIN" exec "$REPEATMODELER_IMAGE" RepeatModeler \
    "${repeatmodeler_args[@]}" \
    2>&1 | tee "${database_name}_repeatmodeler.log"

find "$workdir" -type f \( -name 'consensi.fa.classified' -o -name '*classified-families.fa' -o -name '*-families.fa' \) | grep -q . \
    || die "RepeatModeler completed but no classified repeat library was found in: $workdir"
