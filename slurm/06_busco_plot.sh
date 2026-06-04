#!/usr/bin/env bash
# Stage 06: optionally generate BUSCO summary plots after all BUSCO runs finish.

set -euo pipefail

CONFIG_PATH="${1:-${CONFIG:-}}"
[[ -n "$CONFIG_PATH" ]] || { echo "ERROR: config path is required" >&2; exit 1; }
CONFIG_DIR="$(cd "$(dirname "$CONFIG_PATH")" && pwd)"
PIPELINE_ROOT="$(cd "$CONFIG_DIR/.." && pwd)"

# shellcheck source=scripts/lib/common.sh
source "$PIPELINE_ROOT/scripts/lib/common.sh"
source_config "$CONFIG_PATH"
ensure_base_dirs

find "$BUSCO_SUMMARY_DIR" -type f -name 'short_summary*.txt' -delete
find "$BUSCO_DIR" -type f -name 'short_summary*.txt' ! -path "$BUSCO_SUMMARY_DIR/*" -exec cp -f {} "$BUSCO_SUMMARY_DIR" \;

if smoke_mode; then
    log "Smoke mode: creating mock BUSCO plot output"
    printf 'smoke busco plot\n' > "$BUSCO_SUMMARY_DIR/busco_plot_smoke.txt"
    exit 0
fi

activate_conda_env "$BUSCO_ENV" "${BUSCO_ENV_PREFIX:-}"
busco_plot_script="$BUSCO_PLOT_SCRIPT"
if [[ -n "${BUSCO_ENV_PREFIX:-}" && -f "${BUSCO_ENV_PREFIX:-}/bin/generate_plot.py" ]]; then
    busco_plot_script="$BUSCO_ENV_PREFIX/bin/generate_plot.py"
elif resolved_busco_plot_script="$(resolve_command_path "$BUSCO_PLOT_SCRIPT")"; then
    busco_plot_script="$resolved_busco_plot_script"
fi
[[ -f "$busco_plot_script" ]] || die "BUSCO plot script not found: $busco_plot_script"

log "Generating BUSCO summary plots"
cd "$BUSCO_SUMMARY_DIR"
python "$busco_plot_script" -wd "$BUSCO_SUMMARY_DIR"
