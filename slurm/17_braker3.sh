#!/usr/bin/env bash
# Stage 17: run BRAKER3 with RNA-seq BAM evidence and protein evidence.

set -euo pipefail

CONFIG_PATH="${1:-${CONFIG:-}}"
[[ -n "$CONFIG_PATH" ]] || { echo "ERROR: config path is required" >&2; exit 1; }
CONFIG_DIR="$(cd "$(dirname "$CONFIG_PATH")" && pwd)"
PIPELINE_ROOT="$(cd "$CONFIG_DIR/.." && pwd)"

# shellcheck source=scripts/lib/common.sh
source "$PIPELINE_ROOT/scripts/lib/common.sh"
source_config "$CONFIG_PATH"
ensure_base_dirs

sample_id="$(current_annotation_sample_id)"
genome_fasta="$(annotation_simplified_genome "$sample_id")"
run_root="$(annotation_predictor_runs_dir braker3 "$sample_id")"
timestamp="$(date +'%Y%m%d_%H%M%S')"
run_dir="$run_root/braker3_output_$timestamp"
augustus_dir="$ANNOTATION_AUGUSTUS_BRAKER3_DIR/$sample_id/$timestamp"
current_link="$(annotation_predictor_link braker3 "$sample_id")"

ensure_dir "$run_root"
ensure_dir "$run_dir"
ensure_dir "$ANNOTATION_AUGUSTUS_BRAKER3_DIR"
ensure_dir "$augustus_dir"

if smoke_mode; then
    log "Smoke mode: creating mock BRAKER3 outputs"
    write_smoke_gtf "$run_dir/$BRAKER_GTF_BASENAME" "$(annotation_header_name_stem "$sample_id")1"
    write_smoke_gtf "$run_dir/braker.gtf" "$(annotation_header_name_stem "$sample_id")1"
    write_smoke_hints "$run_dir/hintsfile.gff" "$(annotation_header_name_stem "$sample_id")1"
    ln -sfn "$run_dir" "$current_link"
    exit 0
fi

[[ -f "$BRAKER_SIF" ]] || die "BRAKER Singularity image not found: $BRAKER_SIF"
[[ -f "$genome_fasta" ]] || die "Simplified annotation genome not found: $genome_fasta"
[[ -f "$BRAKER3_PROTEIN_FASTA" ]] || die "BRAKER3 protein FASTA not found: $BRAKER3_PROTEIN_FASTA"
command -v "$SINGULARITY_BIN" >/dev/null 2>&1 || die "Singularity executable not found: $SINGULARITY_BIN"
assert_softmasked_fasta "$genome_fasta"

samtools_header() {
    local bam_file="$1"

    if command -v samtools >/dev/null 2>&1; then
        samtools view -H "$bam_file"
    else
        "$SINGULARITY_BIN" exec -B "$PROJECT_ROOT:$PROJECT_ROOT" "$BRAKER_SIF" samtools view -H "$bam_file"
    fi
}

validate_bam_references() {
    local bam_file="$1"
    local tmp_genome_refs
    local tmp_bam_refs
    local missing_refs

    tmp_genome_refs="$(mktemp)"
    tmp_bam_refs="$(mktemp)"

    awk '/^>/ { sub(/^>/, "", $1); print $1 }' "$genome_fasta" | sort -u > "$tmp_genome_refs"
    samtools_header "$bam_file" | awk -F '\t' '
        /^@SQ/ {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^SN:/) {
                    sub(/^SN:/, "", $i)
                    print $i
                }
            }
        }
    ' | sort -u > "$tmp_bam_refs"

    [[ -s "$tmp_bam_refs" ]] || {
        rm -f "$tmp_genome_refs" "$tmp_bam_refs"
        die "No reference sequence headers found in BAM: $bam_file"
    }

    missing_refs="$(comm -23 "$tmp_bam_refs" "$tmp_genome_refs" | head -n 5)"
    rm -f "$tmp_genome_refs" "$tmp_bam_refs"

    [[ -z "$missing_refs" ]] || die "BAM references do not match simplified genome for sample $sample_id. First unmatched BAM refs: $missing_refs"
}

declare -a bam_files=()
case "$BRAKER3_MODE" in
    all_samples)
        bam_glob="$(braker3_bam_glob_for_sample "$sample_id")"
        mapfile -t bam_files < <(compgen -G "$bam_glob" | sort || true)
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
for bam_file in "${bam_files[@]}"; do
    validate_bam_references "$bam_file"
done
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
    --softmasking
    --AUGUSTUS_CONFIG_PATH=/opt/Augustus/config
)

if truthy "$BRAKER3_USEEXISTING"; then
    braker_args+=(--useexisting)
fi

log "Running BRAKER3"
cd "$run_dir"
"$SINGULARITY_BIN" exec \
    -B "$PROJECT_ROOT:$PROJECT_ROOT" \
    -B "$augustus_dir/config:/opt/Augustus/config" \
    "$BRAKER_SIF" \
    braker.pl "${braker_args[@]}"

ln -sfn "$run_dir" "$current_link"
[[ -f "$(annotation_predictor_gtf braker3 "$sample_id")" ]] || die "BRAKER3 GTF was not created: $(annotation_predictor_gtf braker3 "$sample_id")"
