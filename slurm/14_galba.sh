#!/usr/bin/env bash
# Stage 14: run GALBA with the simplified masked genome and protein evidence.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="${1:-${CONFIG:-}}"

# shellcheck source=../scripts/lib/common.sh
source "$SCRIPT_DIR/../scripts/lib/common.sh"
source_config "$CONFIG_PATH"
ensure_base_dirs

sample_id="$ANNOTATION_SAMPLE_ID"
genome_fasta="$(annotation_simplified_genome "$sample_id")"
run_root="$(annotation_predictor_runs_dir galba)"
timestamp="$(date +'%Y%m%d_%H%M%S')"
run_dir="$run_root/galba_output_$timestamp"
augustus_dir="$ANNOTATION_AUGUSTUS_GALBA_DIR/$timestamp"
current_link="$(annotation_predictor_link galba)"

ensure_dir "$run_root"
ensure_dir "$run_dir"
ensure_dir "$ANNOTATION_AUGUSTUS_GALBA_DIR"
ensure_dir "$augustus_dir"

if smoke_mode; then
    log "Smoke mode: creating mock GALBA outputs"
    write_smoke_gtf "$run_dir/galba.gtf" "$(annotation_header_name_stem "$sample_id")1"
    write_smoke_hints "$run_dir/hintsfile.gff" "$(annotation_header_name_stem "$sample_id")1"
    ln -sfn "$run_dir" "$current_link"
    exit 0
fi

[[ -f "$GALBA_SIF" ]] || die "GALBA Singularity image not found: $GALBA_SIF"
[[ -f "$genome_fasta" ]] || die "Simplified annotation genome not found: $genome_fasta"
[[ -f "$GALBA_PROTEIN_FASTA" ]] || die "GALBA protein FASTA not found: $GALBA_PROTEIN_FASTA"
command -v "$SINGULARITY_BIN" >/dev/null 2>&1 || die "Singularity executable not found: $SINGULARITY_BIN"

log "Preparing writable AUGUSTUS config for GALBA"
"$SINGULARITY_BIN" exec "$GALBA_SIF" cp -r /opt/Augustus/config "$augustus_dir"
[[ -d "$augustus_dir/config" ]] || die "GALBA AUGUSTUS config was not created: $augustus_dir/config"

log "Running GALBA"
"$SINGULARITY_BIN" exec \
    -B "$PROJECT_ROOT:$PROJECT_ROOT" \
    -B "$augustus_dir/config:/opt/Augustus/config" \
    "$GALBA_SIF" \
    galba.pl \
        --species="$ANNOTATION_SPECIES" \
        --genome="$genome_fasta" \
        --prot_seq="$GALBA_PROTEIN_FASTA" \
        --workingdir="$run_dir" \
        --threads="${SLURM_CPUS_PER_TASK:-$GALBA_CPUS}" \
        --AUGUSTUS_CONFIG_PATH=/opt/Augustus/config

ln -sfn "$run_dir" "$current_link"
[[ -f "$(annotation_predictor_gtf galba)" ]] || die "GALBA GTF was not created: $(annotation_predictor_gtf galba)"
