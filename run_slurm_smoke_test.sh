#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="${1:-$SCRIPT_DIR/config/slurm_toy.env}"

source "$SCRIPT_DIR/scripts/lib/common.sh"
source_config "$CONFIG_PATH"

bash "$SCRIPT_DIR/scripts/setup_smoke_test.sh" "$CONFIG_PATH"
bash "$SCRIPT_DIR/run_pipeline.sh" "$CONFIG_PATH"
