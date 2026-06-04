#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_PATH="${1:-}"
CHUNKS="${2:-}"
CHUNK_INDEX="${3:-}"
CHAIN_RUN_ID="${4:-}"

[[ -n "$CONFIG_PATH" ]] || { echo "Usage: $0 <config.env> <chunks> <chunk_index> <chain_run_id>" >&2; exit 1; }
[[ -n "$CHUNKS" ]] || { echo "Stage chunks were not provided." >&2; exit 1; }
[[ "$CHUNK_INDEX" =~ ^[0-9]+$ ]] || { echo "Invalid chunk index: $CHUNK_INDEX" >&2; exit 1; }
[[ -n "$CHAIN_RUN_ID" ]] || { echo "Chain run id was not provided." >&2; exit 1; }

# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/scripts/lib/common.sh"
source_config "$CONFIG_PATH"
ensure_base_dirs

command -v sbatch >/dev/null 2>&1 || die "sbatch was not found on PATH."

normalize_stage() {
    local stage="$1"
    [[ "$stage" =~ ^[0-9]{1,2}$ ]] || die "Invalid stage value: $stage"
    printf '%02d' "$((10#$stage))"
}

chunk_at_index() {
    local index="$1"
    awk -v chunks="$CHUNKS" -v index="$index" '
        BEGIN {
            count = split(chunks, parts, ",")
            if (index < 0 || index >= count) {
                exit 1
            }
            print parts[index + 1]
        }
    '
}

job_dependency_from_manifest() {
    local manifest="$1"
    awk -F '\t' 'NR > 1 && $3 != "" { ids = ids (ids ? ":" : "") $3 } END { print ids }' "$manifest"
}

chunk="$(chunk_at_index "$CHUNK_INDEX")" || die "No stage chunk found at index $CHUNK_INDEX in: $CHUNKS"
[[ "$chunk" == *-* ]] || die "Invalid stage chunk: $chunk"
start_stage="$(normalize_stage "${chunk%-*}")"
end_stage="$(normalize_stage "${chunk#*-}")"
chunk_run_id="${CHAIN_RUN_ID}_stage${start_stage}_${end_stage}"

printf 'Submitting stage chunk %s (%s), run id %s\n' "$CHUNK_INDEX" "$chunk" "$chunk_run_id"

PIPELINE_START_STAGE="$start_stage" \
PIPELINE_END_STAGE="$end_stage" \
PIPELINE_RUN_ID="$chunk_run_id" \
    bash "$SCRIPT_DIR/run_pipeline.sh" "$CONFIG_PATH"

manifest="$LOG_DIR/submissions/run_${chunk_run_id}_jobs.tsv"
[[ -f "$manifest" ]] || die "Expected chunk manifest was not created: $manifest"

dependency="$(job_dependency_from_manifest "$manifest")"
[[ -n "$dependency" ]] || die "No job IDs were found in chunk manifest: $manifest"

next_index="$((CHUNK_INDEX + 1))"
if next_chunk="$(chunk_at_index "$next_index")"; then
    next_start="$(normalize_stage "${next_chunk%-*}")"
    next_end="$(normalize_stage "${next_chunk#*-}")"
    submitter_log="$LOG_DIR/chained_submit_${CHAIN_RUN_ID}_stage${next_start}_${next_end}_%j.out"
    submitter_err="$LOG_DIR/chained_submit_${CHAIN_RUN_ID}_stage${next_start}_${next_end}_%j.err"

    submitter_job_id="$(sbatch \
        --parsable \
        --account="$SBATCH_ACCOUNT" \
        --dependency="afterok:$dependency" \
        --job-name="akodon_submit_${next_start}_${next_end}" \
        --partition="$CHAIN_SUBMIT_PARTITION" \
        --qos="$CHAIN_SUBMIT_QOS" \
        --time="$CHAIN_SUBMIT_TIME" \
        --cpus-per-task="$CHAIN_SUBMIT_CPUS" \
        --mem="$CHAIN_SUBMIT_MEM" \
        --output="$submitter_log" \
        --error="$submitter_err" \
        --export=ALL \
        "$SCRIPT_DIR/scripts/submit_stage_chunk_and_chain.sh" "$CONFIG_PATH" "$CHUNKS" "$next_index" "$CHAIN_RUN_ID")"

    printf '\nNext chunk submitter queued:\n'
    printf '  Chunk: %s\n' "$next_chunk"
    printf '  Job ID: %s\n' "$submitter_job_id"
    printf '  Dependency: afterok:%s\n' "$dependency"
    printf '  stdout: %s\n' "$submitter_log"
    printf '  stderr: %s\n' "$submitter_err"
else
    printf '\nNo more stage chunks remain for chain %s.\n' "$CHAIN_RUN_ID"
fi
