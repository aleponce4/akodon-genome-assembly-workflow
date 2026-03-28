#!/usr/bin/env bash
# Stage 20: run InterProScan on the chosen protein FASTA.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="${1:-${CONFIG:-}}"

# shellcheck source=../scripts/lib/common.sh
source "$SCRIPT_DIR/../scripts/lib/common.sh"
source_config "$CONFIG_PATH"
ensure_base_dirs

run_dir="$(annotation_interproscan_run_dir)"
input_fasta="$INTERPROSCAN_INPUT_FASTA"

if [[ -z "$input_fasta" ]]; then
    input_fasta="$(annotation_isoform_aa "$ANNOTATION_FINAL_MODEL")"
fi

ensure_dir "$run_dir"
ensure_dir "$ANNOTATION_FUNCTIONAL_TEMP_DIR"

if smoke_mode; then
    log "Smoke mode: creating mock InterProScan output"
    cat > "$run_dir/${INTERPROSCAN_RUN_NAME}.tsv" <<EOF
smoke_protein	Pfam	PF00000	SmokeDomain
EOF
    exit 0
fi

[[ -f "$INTERPROSCAN_SIF" ]] || die "InterProScan Singularity image not found: $INTERPROSCAN_SIF"
[[ -d "$INTERPROSCAN_DATA_DIR/data" ]] || die "InterProScan data directory not found: $INTERPROSCAN_DATA_DIR/data"
[[ -f "$input_fasta" ]] || die "InterProScan input FASTA not found: $input_fasta"
command -v "$SINGULARITY_BIN" >/dev/null 2>&1 || die "Singularity executable not found: $SINGULARITY_BIN"

log "Running InterProScan for model $INTERPROSCAN_RUN_NAME"
"$SINGULARITY_BIN" exec \
    -B "$INTERPROSCAN_DATA_DIR/data:/opt/interproscan/data" \
    -B "$PROJECT_ROOT:$PROJECT_ROOT" \
    -B "$ANNOTATION_FUNCTIONAL_TEMP_DIR:/temp" \
    -B "$run_dir:/output" \
    "$INTERPROSCAN_SIF" \
    /opt/interproscan/interproscan.sh \
    --input "$input_fasta" \
    --output-dir /output \
    --tempdir /temp \
    --cpu "${SLURM_CPUS_PER_TASK:-$INTERPROSCAN_CPUS}" \
    --disable-precalc \
    --formats "$INTERPROSCAN_FORMATS" \
    --applications "$INTERPROSCAN_APPLICATIONS" \
    --goterms \
    --verbose

find "$run_dir" -type f | grep -q . || die "InterProScan did not create any output files in $run_dir"
