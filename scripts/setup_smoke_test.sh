#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_PATH="${1:-$REPO_ROOT/config/smoke_test.env}"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
source_config "$CONFIG_PATH"
ensure_base_dirs
ensure_dir "$DATA_DIR"
ensure_dir "$RNA_ALIGN_FASTQ_DIR"

sample_total="$(sample_count)"
for ((idx = 0; idx < sample_total; idx++)); do
    sample_id="$(sample_id_by_index "$idx")"
    fastq_sample="$(fastq_sample_by_index "$idx")"
    write_smoke_fastq_gz "$DATA_DIR/${fastq_sample}_S1_L001_R1_001.fastq.gz" "${fastq_sample}_R1"
    write_smoke_fastq_gz "$DATA_DIR/${fastq_sample}_S1_L001_R2_001.fastq.gz" "${fastq_sample}_R2"
done

for library_id in $RNA_ALIGN_LIBRARY_IDS; do
    write_smoke_fastq_gz "$(rna_align_fastq_r1 "$library_id")" "${library_id}_R1"
    write_smoke_fastq_gz "$(rna_align_fastq_r2 "$library_id")" "${library_id}_R2"
done

ensure_dir "$ANNOTATION_INPUT_DIR"
ensure_dir "$NCBI_PROTEIN_ZIP_DIR"
ensure_dir "$INTERPROSCAN_OUTPUT_DIR"

cat > "$NCBI_DATASETS_TSV" <<EOF
Assembly Accession	Assembly Name
GCF_smoke	SmokeAssembly
EOF

write_smoke_fasta "$ANNOTATION_INPUT_DIR/Vertebrata.fa" "vertebrate_smoke" "MPEPTIDESEQ"

for ((idx = 0; idx < sample_total; idx++)); do
    sample_id="$(sample_id_by_index "$idx")"
    bam_glob="$(braker3_bam_glob_for_sample "$sample_id")"
    bam_dir="$(dirname "$bam_glob")"
    ensure_dir "$bam_dir"
    write_smoke_fasta "$bam_dir/smoke.bam" "placeholder" "NOT_A_REAL_BAM"
done

for cfg in 1 2 3; do
    cat > "$ANNOTATION_INPUT_DIR/tsebra_config_${cfg}.cfg" <<EOF
[DEFAULT]
filter=smoke
EOF
done

log "Smoke test inputs prepared under DATA_DIR=$DATA_DIR and OUTPUT_DIR=$OUTPUT_DIR"
