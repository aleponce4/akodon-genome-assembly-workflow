#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="${1:-$SCRIPT_DIR/config/pipeline.env}"
CONFIG_DIR="$(cd "$(dirname "$CONFIG_PATH")" && pwd)"
CONFIG_PATH="$CONFIG_DIR/$(basename "$CONFIG_PATH")"

# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/scripts/lib/common.sh"
source_config "$CONFIG_PATH"
ensure_base_dirs

command -v sbatch >/dev/null 2>&1 || die "sbatch was not found on PATH."

chain_run_id="${PIPELINE_CHAIN_RUN_ID:-$(date '+%Y%m%d_%H%M%S')_chain_$$}"
[[ "$chain_run_id" =~ ^[A-Za-z0-9._-]+$ ]] || die "PIPELINE_CHAIN_RUN_ID may only contain letters, numbers, dot, underscore, and dash."

chunks="$PIPELINE_STAGE_CHUNKS"
if ! truthy "$ENABLE_ANNOTATION" && [[ "${PIPELINE_STAGE_CHUNKS:-}" == "00-03,04-10,11-13,14-16,17-20" ]]; then
    chunks="00-03,04-10"
fi

normalize_stage() {
    local stage="$1"
    [[ "$stage" =~ ^[0-9]{1,2}$ ]] || die "Invalid stage value: $stage"
    printf '%02d' "$((10#$stage))"
}

clip_chunks_to_stage_range() {
    local chunk_list="$1"
    local requested_start="$2"
    local requested_end="$3"
    local result=""
    local chunk
    local chunk_start
    local chunk_end
    local clipped_start
    local clipped_end

    IFS=',' read -r -a chunk_array <<< "$chunk_list"
    for chunk in "${chunk_array[@]}"; do
        [[ "$chunk" == *-* ]] || die "Invalid stage chunk: $chunk"
        chunk_start="$(normalize_stage "${chunk%-*}")"
        chunk_end="$(normalize_stage "${chunk#*-}")"

        if (( 10#$chunk_end < 10#$requested_start || 10#$chunk_start > 10#$requested_end )); then
            continue
        fi

        clipped_start="$chunk_start"
        clipped_end="$chunk_end"
        if (( 10#$clipped_start < 10#$requested_start )); then
            clipped_start="$requested_start"
        fi
        if (( 10#$clipped_end > 10#$requested_end )); then
            clipped_end="$requested_end"
        fi

        result="${result:+$result,}${clipped_start}-${clipped_end}"
    done

    [[ -n "$result" ]] || die "No stage chunks overlap requested range ${requested_start}-${requested_end}."
    printf '%s' "$result"
}

requested_start="$(normalize_stage "$PIPELINE_START_STAGE")"
requested_end="$(normalize_stage "$PIPELINE_END_STAGE")"
(( 10#$requested_start <= 10#$requested_end )) || die "PIPELINE_START_STAGE must be <= PIPELINE_END_STAGE."
chunks="$(clip_chunks_to_stage_range "$chunks" "$requested_start" "$requested_end")"

printf 'Submitting chained pipeline run.\n'
printf '  Config: %s\n' "$CONFIG_PATH"
printf '  Chain run id: %s\n' "$chain_run_id"
printf '  Requested stages: %s-%s\n' "$requested_start" "$requested_end"
printf '  Stage chunks: %s\n' "$chunks"

bash "$SCRIPT_DIR/scripts/submit_stage_chunk_and_chain.sh" "$CONFIG_PATH" "$chunks" 0 "$chain_run_id"
