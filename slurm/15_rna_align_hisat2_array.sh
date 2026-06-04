#!/usr/bin/env bash
# Stage 15: align RNA-seq reads to each simplified assembly for BRAKER3 evidence.

set -euo pipefail

CONFIG_PATH="${1:-${CONFIG:-}}"
[[ -n "$CONFIG_PATH" ]] || { echo "ERROR: config path is required" >&2; exit 1; }
CONFIG_DIR="$(cd "$(dirname "$CONFIG_PATH")" && pwd)"
PIPELINE_ROOT="$(cd "$CONFIG_DIR/.." && pwd)"

# shellcheck source=scripts/lib/common.sh
source "$PIPELINE_ROOT/scripts/lib/common.sh"
source_config "$CONFIG_PATH"
ensure_base_dirs

export OMP_NUM_THREADS="${SLURM_CPUS_PER_TASK:-$RNA_ALIGN_CPUS}"

sample_id="$(current_annotation_sample_id)"
genome_fasta="$(annotation_simplified_genome "$sample_id")"
bam_dir="$(rna_align_sample_bam_dir "$sample_id")"
log_dir="$(rna_align_sample_log_dir "$sample_id")"
tmp_dir="$(rna_align_sample_tmp_dir "$sample_id")"
index_dir="$(rna_align_sample_index_dir "$sample_id")"
index_prefix="$(rna_align_index_prefix "$sample_id")"
threads="${SLURM_CPUS_PER_TASK:-$RNA_ALIGN_CPUS}"

if (( threads >= 8 )); then
    hisat2_threads="$((threads - 4))"
    sort_threads=4
elif (( threads > 1 )); then
    hisat2_threads="$((threads - 1))"
    sort_threads=1
else
    hisat2_threads=1
    sort_threads=1
fi

cleanup_tmp() {
    if [[ -n "${tmp_dir:-}" && "$tmp_dir" == "$RNA_ALIGN_TMP_DIR/"* ]]; then
        rm -rf "$tmp_dir"
    fi
}
trap cleanup_tmp EXIT

ensure_dir "$bam_dir"
ensure_dir "$log_dir"
ensure_dir "$tmp_dir"
ensure_dir "$index_dir"

if smoke_mode; then
    log "Smoke mode: creating mock RNA BAM outputs for sample $sample_id"
    for library_id in $RNA_ALIGN_LIBRARY_IDS; do
        bam_file="$(rna_align_bam "$sample_id" "$library_id")"
        bai_file="$bam_file.bai"
        hisat2_log="$(rna_align_hisat2_log "$sample_id" "$library_id")"
        flagstat_file="$(rna_align_flagstat "$sample_id" "$library_id")"

        write_smoke_fasta "$bam_file" "placeholder" "NOT_A_REAL_BAM"
        printf 'index\n' > "$bai_file"
        printf 'Smoke HISAT2 log for %s %s\n' "$sample_id" "$library_id" > "$hisat2_log"
        printf 'Smoke flagstat for %s %s\n' "$sample_id" "$library_id" > "$flagstat_file"
    done
    exit 0
fi

needs_alignment=0
for library_id in $RNA_ALIGN_LIBRARY_IDS; do
    bam_file="$(rna_align_bam "$sample_id" "$library_id")"
    bai_file="$bam_file.bai"

    if [[ ! -s "$bam_file" || ! -s "$bai_file" ]] || truthy "$RNA_ALIGN_OVERWRITE"; then
        needs_alignment=1
        break
    fi
done

if (( ! needs_alignment )); then
    log "All RNA BAMs already exist for sample $sample_id; skipping HISAT2 index and alignment"
    exit 0
fi

[[ -f "$genome_fasta" ]] || die "Simplified annotation genome not found for RNA alignment: $genome_fasta"

if ! command -v hisat2 >/dev/null 2>&1 || ! command -v hisat2-build >/dev/null 2>&1; then
    load_module_if_available "$HISAT2_MODULE"
fi
if ! command -v samtools >/dev/null 2>&1; then
    load_module_if_available "$SAMTOOLS_MODULE"
fi

command -v hisat2 >/dev/null 2>&1 || die "hisat2 not found after loading module: $HISAT2_MODULE"
command -v hisat2-build >/dev/null 2>&1 || die "hisat2-build not found after loading module: $HISAT2_MODULE"
command -v samtools >/dev/null 2>&1 || die "samtools not found after loading module: $SAMTOOLS_MODULE"

index_ready=0
if [[ -f "${index_prefix}.1.ht2" || -f "${index_prefix}.1.ht2l" ]]; then
    index_ready=1
fi

if (( ! index_ready )); then
    log "Building HISAT2 index for sample $sample_id"
    hisat2-build -p "$threads" "$genome_fasta" "$index_prefix"
fi

for library_id in $RNA_ALIGN_LIBRARY_IDS; do
    r1_file="$(rna_align_fastq_r1 "$library_id")"
    r2_file="$(rna_align_fastq_r2 "$library_id")"
    bam_file="$(rna_align_bam "$sample_id" "$library_id")"
    bai_file="$bam_file.bai"
    hisat2_log="$(rna_align_hisat2_log "$sample_id" "$library_id")"
    flagstat_file="$(rna_align_flagstat "$sample_id" "$library_id")"
    bam_tmp="$tmp_dir/${library_id}_aligned_sorted.bam"
    flagstat_tmp="$tmp_dir/${library_id}_alignment_stats.txt"

    [[ -f "$r1_file" ]] || die "RNA R1 FASTQ not found: $r1_file"
    [[ -f "$r2_file" ]] || die "RNA R2 FASTQ not found: $r2_file"

    if [[ -s "$bam_file" && -s "$bai_file" ]] && ! truthy "$RNA_ALIGN_OVERWRITE"; then
        log "Skipping existing RNA BAM for sample $sample_id library $library_id"
        continue
    fi

    rm -f "$bam_tmp" "$bam_tmp.bai" "$flagstat_tmp"

    log "Aligning RNA library $library_id to sample $sample_id"
    if ! hisat2 \
        --dta \
        -p "$hisat2_threads" \
        -x "$index_prefix" \
        -1 "$r1_file" \
        -2 "$r2_file" \
        2> "$hisat2_log" \
        | samtools sort -@ "$sort_threads" -T "$tmp_dir/${library_id}.sort" -o "$bam_tmp" -; then
        rm -f "$bam_tmp" "$bam_tmp.bai"
        die "RNA alignment failed for sample $sample_id library $library_id. See $hisat2_log"
    fi

    [[ -s "$bam_tmp" ]] || die "RNA alignment produced empty BAM: $bam_tmp"
    samtools index "$bam_tmp"
    [[ -s "$bam_tmp.bai" ]] || die "RNA alignment BAM index was not created: $bam_tmp.bai"

    samtools flagstat "$bam_tmp" > "$flagstat_tmp"
    [[ -s "$flagstat_tmp" ]] || die "RNA alignment flagstat was not created: $flagstat_tmp"

    mv -f "$bam_tmp" "$bam_file"
    mv -f "$bam_tmp.bai" "$bai_file"
    mv -f "$flagstat_tmp" "$flagstat_file"
done

if ! truthy "$RNA_ALIGN_KEEP_INDEX"; then
    log "Removing HISAT2 index for sample $sample_id to save quota"
    rm -rf "$index_dir"
fi
