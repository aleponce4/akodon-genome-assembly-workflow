#!/usr/bin/env bash
# Stage 02: convert each Supernova assembly into the canonical pseudohap FASTA used downstream.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="${1:-${CONFIG:-}}"

# shellcheck source=../scripts/lib/common.sh
source "$SCRIPT_DIR/../scripts/lib/common.sh"
source_config "$CONFIG_PATH"
ensure_base_dirs

require_var SUPERNOVA_BIN

sample_index="${SLURM_ARRAY_TASK_ID:?SLURM_ARRAY_TASK_ID is required}"
sample_id="$(sample_id_by_index "$sample_index")"
fastq_sample="$(fastq_sample_by_index "$sample_index")"
assembly_dir="$(supernova_asmdir "$fastq_sample")"
outprefix="$(pseudohap_prefix "$sample_id")"
canonical_output="$(canonical_pseudohap "$sample_id")"

if smoke_mode; then
    log "Smoke mode: creating mock pseudohap FASTA"
    primary_output="${outprefix}.${PRIMARY_HAPLOTYPE}.fasta.gz"
    write_smoke_fasta_gz "$primary_output" "${ASSEMBLY_PREFIX}_${sample_id}" "ATGCGTATGCGTATGCGTATGCGTATGCGT"
    cp -f "$primary_output" "$canonical_output"
    [[ -s "$canonical_output" ]] || die "Canonical pseudohap FASTA is missing or empty: $canonical_output"
    exit 0
fi

[[ -x "$SUPERNOVA_BIN" ]] || die "Supernova executable not found: $SUPERNOVA_BIN"
[[ -d "$assembly_dir" ]] || die "Assembly directory not found: $assembly_dir"

log "Generating FASTA output for sample $sample_id"
"$SUPERNOVA_BIN" mkoutput \
    --style="$SUPERNOVA_MKOUTPUT_STYLE" \
    --asmdir="$assembly_dir" \
    --outprefix="$outprefix"

case "$SUPERNOVA_MKOUTPUT_STYLE" in
    pseudohap)
        [[ -f "$canonical_output" ]] || die "Expected Supernova output was not created: $canonical_output"
        ;;
    pseudohap2)
        primary_output="${outprefix}.${PRIMARY_HAPLOTYPE}.fasta.gz"
        [[ -f "$primary_output" ]] || die "Expected pseudohap2 output was not created: $primary_output"
        cp -f "$primary_output" "$canonical_output"
        ;;
    *)
        die "Unsupported SUPERNOVA_MKOUTPUT_STYLE: $SUPERNOVA_MKOUTPUT_STYLE"
        ;;
esac

[[ -s "$canonical_output" ]] || die "Canonical pseudohap FASTA is missing or empty: $canonical_output"
