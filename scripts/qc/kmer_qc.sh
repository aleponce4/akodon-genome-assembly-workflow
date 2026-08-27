#!/usr/bin/env bash
#SBATCH --job-name=akodon_kmer_qc
#SBATCH --output=logs/slurm/kmer_qc_%j.out
#SBATCH --error=logs/slurm/kmer_qc_%j.err
#
# k-mer based assembly QC: Merqury (QV, k-mer completeness, false duplication)
# and GenomeScope2 (independent genome size and heterozygosity).
#
# WHY THIS MATTERS FOR THIS PROJECT
# BUSCO tells you about gene space only. Merqury's false-duplication estimate is
# the evidence that decides whether purging is needed at all -- BUSCO Duplicated
# under-reports it, because a second copy scoring below 85% of the best hit is
# demoted to single-copy, so divergent haplotigs are invisible to BUSCO, as is
# any duplicated megabase carrying no BUSCO gene.
#
# THE 10x BARCODE, WHICH IS THE EASY THING TO GET WRONG
# In Chromium Genome reads, R1 begins with a 16 bp GEM barcode followed by a
# 7 bp spacer. Those 23 bases are synthetic: they are not in the genome, and
# every k-mer spanning them is noise. Left in, they inflate the read k-mer set
# with sequence the assembly cannot contain, so QV is depressed and k-mer
# completeness is wrong. R2 is ordinary genomic sequence and must NOT be trimmed.
# This mirrors merqury's own build/count_10x.sh.
#
# QV CAVEAT TO CARRY INTO THE PAPER
# QV computed from the same Illumina reads that built the consensus is partly
# circular: assembly-only k-mers are rare by construction. Report QV, but lead
# with k-mer completeness and false-duplication %, which are not inflated this
# way. (Merqury's own caveat runs the other way: QV is UNDER-estimated when
# coverage is biased.)
#
# Usage:
#   sbatch scripts/qc/kmer_qc.sh config/pipeline.env <assembly.fasta> <sample_id>
#   bash   scripts/qc/kmer_qc.sh config/pipeline.env <assembly.fasta> <sample_id>

set -euo pipefail

CONFIG_PATH="${1:?usage: kmer_qc.sh <config> <assembly.fasta> <sample_id>}"
ASSEMBLY="${2:?assembly FASTA required}"
SAMPLE_ID="${3:?sample id required}"

CONFIG_DIR="$(cd "$(dirname "$CONFIG_PATH")" && pwd)"
PIPELINE_ROOT="$(cd "$CONFIG_DIR/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$PIPELINE_ROOT/scripts/lib/common.sh"
source_config "$CONFIG_PATH"

KMER_DIR="${KMER_QC_DIR:-$OUTPUT_DIR/qc_kmer/$SAMPLE_ID}"
THREADS="${KMER_QC_THREADS:-${SLURM_CPUS_PER_TASK:-16}}"
MEMORY="${KMER_QC_MEMORY:-48g}"
KVAL="${KMER_QC_K:-21}"
BARCODE_TRIM="${TENX_BARCODE_TRIM:-23}"   # 16 bp GEM barcode + 7 bp spacer

[[ -f "$ASSEMBLY" ]] || die "Assembly not found: $ASSEMBLY"
ensure_dir "$KMER_DIR"

# Resolve the FASTQ filename stem for this sample_id from the sample table.
fastq_sample=""
sample_total="$(sample_count)"
for ((i = 0; i < sample_total; i++)); do
    if [[ "$(sample_id_by_index "$i")" == "$SAMPLE_ID" ]]; then
        fastq_sample="$(fastq_sample_by_index "$i")"
        break
    fi
done
[[ -n "$fastq_sample" ]] || die "sample_id '$SAMPLE_ID' is not in $SAMPLES_TSV"
log "sample_id $SAMPLE_ID -> FASTQ stem $fastq_sample"

r1="$(find -L "$DATA_DIR" -maxdepth 1 -name "${fastq_sample}*R1*.fastq.gz" | sort | head -1)"
r2="$(find -L "$DATA_DIR" -maxdepth 1 -name "${fastq_sample}*R2*.fastq.gz" | sort | head -1)"
[[ -n "$r1" && -n "$r2" ]] || die "Could not locate R1/R2 for '$fastq_sample' under $DATA_DIR"
log "R1: $r1"
log "R2: $r2"

# ---------------------------------------------------------------------------
# Self-test the barcode trim before spending hours on the real data. A silent
# off-by-one here would corrupt every downstream number.
# ---------------------------------------------------------------------------
trim_r1_stream () {
    # Records are 4 lines: 1=header 2=sequence 3='+' 4=quality.
    # Trim sequence and quality identically; leave both header lines untouched.
    awk -v n="$BARCODE_TRIM" '
        NR % 4 == 1 || NR % 4 == 3 { print; next }
        { print substr($0, n + 1) }
    '
}

log "Self-testing the ${BARCODE_TRIM} bp R1 trim"
selftest_out="$(printf '@read1 1:N:0:ACGT\n%s\n+\n%s\n' \
    "$(printf 'B%.0s' $(seq 1 "$BARCODE_TRIM"))GGGGCCCC" \
    "$(printf 'I%.0s' $(seq 1 $((BARCODE_TRIM + 8))))" | trim_r1_stream)"
exp_seq="GGGGCCCC"
got_seq="$(sed -n 2p <<<"$selftest_out")"
got_qual="$(sed -n 4p <<<"$selftest_out")"
[[ "$got_seq" == "$exp_seq" ]] \
    || die "Barcode trim self-test FAILED: sequence '$got_seq' != '$exp_seq'"
[[ ${#got_qual} -eq ${#got_seq} ]] \
    || die "Barcode trim self-test FAILED: quality length ${#got_qual} != sequence length ${#got_seq}"
log "Self-test OK: sequence and quality both trimmed to ${#got_seq} b, headers intact"

# ---------------------------------------------------------------------------
# meryl k-mer databases
# ---------------------------------------------------------------------------
cd "$KMER_DIR"

if command -v best_k.sh >/dev/null 2>&1 && [[ -n "${MERQURY:-}" ]]; then
    log "best_k.sh suggestion for a 2.6 Gb genome:"
    best_k.sh 2600000000 2>&1 | tail -2 || true
fi
log "Using k=$KVAL (k=31 tracks true QV more closely; k=21 is the size-derived optimum)"

if [[ ! -d "$KMER_DIR/reads.meryl" ]]; then
    log "Counting R1 k-mers (barcode-trimmed)"
    gzip -cd "$r1" | trim_r1_stream \
        | meryl k="$KVAL" threads="$THREADS" memory="$MEMORY" count output R1.meryl /dev/stdin

    log "Counting R2 k-mers (untrimmed)"
    meryl k="$KVAL" threads="$THREADS" memory="$MEMORY" count output R2.meryl "$r2"

    log "Union-summing read k-mers"
    meryl union-sum output reads.meryl R1.meryl R2.meryl
    rm -rf R1.meryl R2.meryl
else
    log "reads.meryl already exists - reusing"
fi

# ---------------------------------------------------------------------------
# GenomeScope2: genome size and heterozygosity, independent of the assembly
# ---------------------------------------------------------------------------
log "GenomeScope2"
meryl histogram reads.meryl > reads.hist
if command -v genomescope2 >/dev/null 2>&1; then
    genomescope2 -i reads.hist -o genomescope2 -k "$KVAL" -p 2 -n "$SAMPLE_ID" \
        >genomescope2.log 2>&1 || log "WARNING: genomescope2 failed - see genomescope2.log"
    [[ -f genomescope2/summary.txt ]] && { log "GenomeScope2 summary:"; cat genomescope2/summary.txt; }
else
    log "WARNING: genomescope2 not on PATH; reads.hist written for manual upload to"
    log "         http://genomescope.org/genomescope2.0/"
fi

# ---------------------------------------------------------------------------
# Merqury
# ---------------------------------------------------------------------------
[[ -n "${MERQURY:-}" ]] || die "MERQURY is not set; export MERQURY=/path/to/merqury"
log "Merqury against $(basename "$ASSEMBLY")"
"$MERQURY/merqury.sh" reads.meryl "$ASSEMBLY" "${SAMPLE_ID}_merqury" \
    >merqury.log 2>&1 || die "merqury.sh failed - see $KMER_DIR/merqury.log"

log "False-duplication estimate"
spectra_hist="$(find . -maxdepth 1 -name "${SAMPLE_ID}_merqury*.spectra-cn.hist" | head -1)"
if [[ -n "$spectra_hist" && -x "$MERQURY/eval/false_duplications.sh" ]]; then
    "$MERQURY/eval/false_duplications.sh" "$spectra_hist" \
        > false_duplications.txt 2>&1 || true
    cat false_duplications.txt
else
    log "WARNING: could not run false_duplications.sh (no spectra-cn.hist found)"
fi

# ---------------------------------------------------------------------------
echo
log "================ INTERPRETATION ================"
qv_file="$(find . -maxdepth 1 -name '*.qv' | head -1)"
cmp_file="$(find . -maxdepth 1 -name '*.completeness.stats' | head -1)"
[[ -n "$qv_file"  ]] && { echo "QV:"; cat "$qv_file"; }
[[ -n "$cmp_file" ]] && { echo "Completeness:"; cat "$cmp_file"; }
cat <<'INTERP'

Reference values for a short-read mammalian assembly (EBP where stated):
  k-mer completeness   >90% good | 84-90% typical short-read ceiling | <80% poor
  false duplication    <5% (EBP threshold) -- ABOVE THIS, PURGE
  QV                   report it, but see the circularity caveat in this
                       script's header; lead with the two metrics above

Reading the spectra-cn plot (Merqury colours: red=1-copy, blue=2-copy):
  heterozygous k-mers at C/2 half red, half black  -> bubble collapsed correctly
  BLUE mass at C/2                                 -> FALSE DUPLICATION
  a 2-copy shoulder at C                           -> unpurged haplotig
  growth of the black (0-copy) band after purging  -> YOU OVER-PURGED, back off

Note KAT uses a different colour convention (purple=2-copy). Do not mix them up.
INTERP

log "Outputs in $KMER_DIR"
