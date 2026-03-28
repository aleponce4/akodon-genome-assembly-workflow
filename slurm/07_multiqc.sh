#!/usr/bin/env bash
# Stage 07: aggregate QUAST and BUSCO outputs with MultiQC.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="${1:-${CONFIG:-}}"

# shellcheck source=../scripts/lib/common.sh
source "$SCRIPT_DIR/../scripts/lib/common.sh"
source_config "$CONFIG_PATH"
ensure_base_dirs

if smoke_mode; then
    log "Smoke mode: creating mock MultiQC report"
    write_smoke_html "$MULTIQC_DIR/multiqc_report.html"
    exit 0
fi

activate_conda_env "$MULTIQC_ENV" "${MULTIQC_ENV_PREFIX:-}"

log "Running MultiQC across BUSCO and QUAST outputs"
multiqc "$BUSCO_DIR" "$QUAST_DIR" -o "$MULTIQC_DIR"
[[ -s "$MULTIQC_DIR/multiqc_report.html" ]] || die "MultiQC report was not created: $MULTIQC_DIR/multiqc_report.html"
