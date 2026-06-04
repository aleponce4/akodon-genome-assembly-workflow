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

printf 'Submitting chained pipeline run.\n'
printf '  Config: %s\n' "$CONFIG_PATH"
printf '  Chain run id: %s\n' "$chain_run_id"
printf '  Stage chunks: %s\n' "$chunks"

bash "$SCRIPT_DIR/scripts/submit_stage_chunk_and_chain.sh" "$CONFIG_PATH" "$chunks" 0 "$chain_run_id"
