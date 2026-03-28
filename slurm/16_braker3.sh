#!/usr/bin/env bash
# Stage 16: run BRAKER3 with RNA-seq BAM evidence and protein evidence.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="${1:-${CONFIG:-}}"

# shellcheck source=../scripts/lib/common.sh
source "$SCRIPT_DIR/../scripts/lib/common.sh"
source_config "$CONFIG_PATH"
ensure_base_dirs

sample_id="$ANNOTATION_SAMPLE_ID"
genome_fasta="$(annotation_simplified_genome "$sample_id")"
run_root="$(annotation_predictor_runs_dir braker3)"
timestamp="$(date +'%Y%m%d_%H%M%S')"
run_dir="$run_root/braker3_output_$timestamp"
augustus_dir="$ANNOTATION_AUGUSTUS_BRAKER3_DIR/$timestamp"
current_link="$(annotation_predictor_link braker3)"

ensure_dir "$run_root"
ensure_dir "$run_dir"
ensure_dir "$ANNOTATION_AUGUSTUS_BRAKER3_DIR"
ensure_dir "$augustus_dir"

if smoke_mode; then
    log "Smoke mode: creating mock BRAKER3 outputs"
    write_smoke_gtf "$run_dir/braker.gtf" "$(annotation_header_name_stem "$sample_id")1"
    write_smoke_hints "$run_dir/hintsfile.gff" "$(annotation_header_name_stem "$sample_id")1"
    ln -sfn "$run_dir" "$current_link"
    exit 0
fi

[[ -f "$BRAKER_SIF" ]] || die "BRAKER Singularity image not found: $BRAKER_SIF"
[[ -f "$genome_fasta" ]] || die "Simplified annotation genome not found: $genome_fasta"
[[ -f "$BRAKER3_PROTEIN_FASTA" ]] || die "BRAKER3 protein FASTA not found: $BRAKER3_PROTEIN_FASTA"
command -v "$SINGULARITY_BIN" >/dev/null 2>&1 || die "Singularity executable not found: $SINGULARITY_BIN"

declare -a bam_files=()
case "$BRAKER3_MODE" in
    all_samples)
        mapfile -t bam_files < <(compgen -G "$BRAKER3_BAM_GLOB" | sort || true)
        ;;
    single_bam)
        [[ -f "$BRAKER3_SINGLE_BAM" ]] || die "BRAKER3 single BAM not found: $BRAKER3_SINGLE_BAM"
        bam_files=("$BRAKER3_SINGLE_BAM")
        ;;
    *)
        die "Unsupported BRAKER3_MODE: $BRAKER3_MODE"
        ;;
esac

(( ${#bam_files[@]} > 0 )) || die "No BAM files were found for BRAKER3."
bam_argument="$(IFS=,; printf '%s' "${bam_files[*]}")"

log "Preparing writable AUGUSTUS config for BRAKER3"
"$SINGULARITY_BIN" exec "$BRAKER_SIF" cp -r /opt/Augustus/config "$augustus_dir"
[[ -d "$augustus_dir/config" ]] || die "BRAKER3 AUGUSTUS config was not created: $augustus_dir/config"

declare -a braker_args=(
    --species="$ANNOTATION_SPECIES"
    --genome="$genome_fasta"
    --prot_seq="$BRAKER3_PROTEIN_FASTA"
    --bam="$bam_argument"
    --workingdir="$run_dir"
    --threads="${SLURM_CPUS_PER_TASK:-$BRAKER3_CPUS}"
    --AUGUSTUS_CONFIG_PATH=/opt/Augustus/config
)

if truthy "$BRAKER3_USEEXISTING"; then
    braker_args+=(--useexisting)
fi

log "Running BRAKER3"
"$SINGULARITY_BIN" exec \
    -B "$PROJECT_ROOT:$PROJECT_ROOT" \
    -B "$augustus_dir/config:/opt/Augustus/config" \
    "$BRAKER_SIF" \
    braker.pl "${braker_args[@]}"

ln -sfn "$run_dir" "$current_link"
[[ -f "$(annotation_predictor_gtf braker3)" ]] || die "BRAKER3 GTF was not created: $(annotation_predictor_gtf braker3)"
