#!/usr/bin/env bash
# Stage 15: run BRAKER2 with protein evidence.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="${1:-${CONFIG:-}}"

# shellcheck source=../scripts/lib/common.sh
source "$SCRIPT_DIR/../scripts/lib/common.sh"
source_config "$CONFIG_PATH"
ensure_base_dirs

sample_id="$ANNOTATION_SAMPLE_ID"
genome_fasta="$(annotation_simplified_genome "$sample_id")"
run_root="$(annotation_predictor_runs_dir braker2)"
timestamp="$(date +'%Y%m%d_%H%M%S')"
run_dir="$run_root/braker2_output_$timestamp"
augustus_dir="$ANNOTATION_AUGUSTUS_BRAKER2_DIR/$timestamp"
current_link="$(annotation_predictor_link braker2)"

ensure_dir "$run_root"
ensure_dir "$run_dir"
ensure_dir "$ANNOTATION_AUGUSTUS_BRAKER2_DIR"
ensure_dir "$augustus_dir"

if smoke_mode; then
    log "Smoke mode: creating mock BRAKER2 outputs"
    write_smoke_gtf "$run_dir/braker.gtf" "$(annotation_header_name_stem "$sample_id")1"
    write_smoke_hints "$run_dir/hintsfile.gff" "$(annotation_header_name_stem "$sample_id")1"
    ln -sfn "$run_dir" "$current_link"
    exit 0
fi

[[ -f "$BRAKER_SIF" ]] || die "BRAKER Singularity image not found: $BRAKER_SIF"
[[ -f "$genome_fasta" ]] || die "Simplified annotation genome not found: $genome_fasta"
[[ -f "$BRAKER2_PROTEIN_FASTA" ]] || die "BRAKER2 protein FASTA not found: $BRAKER2_PROTEIN_FASTA"
command -v "$SINGULARITY_BIN" >/dev/null 2>&1 || die "Singularity executable not found: $SINGULARITY_BIN"

log "Preparing writable AUGUSTUS config for BRAKER2"
"$SINGULARITY_BIN" exec "$BRAKER_SIF" cp -r /opt/Augustus/config "$augustus_dir"
[[ -d "$augustus_dir/config" ]] || die "BRAKER2 AUGUSTUS config was not created: $augustus_dir/config"

log "Running BRAKER2"
"$SINGULARITY_BIN" exec \
    -B "$PROJECT_ROOT:$PROJECT_ROOT" \
    -B "$augustus_dir/config:/opt/Augustus/config" \
    "$BRAKER_SIF" \
    braker.pl \
        --species="$ANNOTATION_SPECIES" \
        --genome="$genome_fasta" \
        --prot_seq="$BRAKER2_PROTEIN_FASTA" \
        --workingdir="$run_dir" \
        --threads="${SLURM_CPUS_PER_TASK:-$BRAKER2_CPUS}" \
        --AUGUSTUS_CONFIG_PATH=/opt/Augustus/config

ln -sfn "$run_dir" "$current_link"
[[ -f "$(annotation_predictor_gtf braker2)" ]] || die "BRAKER2 GTF was not created: $(annotation_predictor_gtf braker2)"
