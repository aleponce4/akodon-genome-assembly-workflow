#!/usr/bin/env bash
# Confirm the species identity of a library from its own reads.
#
# Assembles the mitogenome de novo from a read subsample (GetOrganelle, seeded
# with the Akodon montensis reference NC_025746.1), extracts cytochrome b, and
# ranks it against a cytb panel spanning the genus.
#
# Why from reads and not from the nuclear assembly: rodent genomes carry NUMTs
# (nuclear mitochondrial insertions). A cytb pulled out of the assembly may be a
# diverged nuclear pseudogene, which is a well-known way to mis-call a species.
# The read-derived mitogenome is backed by depth orders of magnitude above
# nuclear, so it is the real mitochondrion.
#
# The discriminating comparison is against A. cursor: it is the sister species,
# sympatric with A. montensis over much of its range, hard to separate
# morphologically, and the two differ mainly in karyotype (cursor 2n=14-16,
# montensis 2n=24-25). Congeneric cytb divergence here is several percent, so a
# correct call should be unambiguous.
#
# Usage: identify_species.sh <R1.fastq.gz> <R2.fastq.gz> <outdir> [n_read_pairs]

set -euo pipefail

R1="${1:?usage: identify_species.sh R1.fastq.gz R2.fastq.gz outdir [n_pairs]}"
R2="${2:?R2 required}"
OUTDIR="${3:?outdir required}"
NPAIRS="${4:-3000000}"

MM="${MICROMAMBA_BIN:-$HOME/bin/micromamba}"
export MAMBA_ROOT_PREFIX="${MAMBA_ROOT_PREFIX:-$HOME/micromamba}"
REFDIR="${REFDIR:-/mnt/d/HPC_Backup/local_work/reference}"
SEED="$REFDIR/NC_025746.1.fasta"
PANEL="$REFDIR/akodon_cytb_panel.fasta"

for f in "$R1" "$R2" "$SEED" "$PANEL"; do
    [[ -f "$f" ]] || { echo "ERROR: missing input: $f" >&2; exit 1; }
done
mkdir -p "$OUTDIR"

# 10x R1 carries a 16 bp GEM barcode + 7 bp spacer at the 5' end. Those 23 bases
# are not genomic and would inject noise into the assembly, so drop them. R2 is
# untouched. Subsampling is safe: mitochondrial depth is in the thousands.
echo "### subsampling ${NPAIRS} read pairs and trimming the 10x barcode from R1"
"$MM" run -n akodon bash -c "
    seqtk sample -s42 '$R1' $NPAIRS | seqtk trimfq -b 23 - | gzip -1 > '$OUTDIR/sub_R1.fq.gz'
    seqtk sample -s42 '$R2' $NPAIRS | gzip -1 > '$OUTDIR/sub_R2.fq.gz'
"

echo "### assembling mitogenome (GetOrganelle, animal_mt)"
"$MM" run -n akodon-mito bash -c "
    get_organelle_config.py --add animal_mt >/dev/null 2>&1 || true
    get_organelle_from_reads.py \
        -1 '$OUTDIR/sub_R1.fq.gz' -2 '$OUTDIR/sub_R2.fq.gz' \
        -F animal_mt -s '$SEED' \
        -R 10 -k 21,45,65,85,105 -t 8 \
        -o '$OUTDIR/getorganelle' --overwrite
" 2>&1 | tail -8

mito="$(find "$OUTDIR/getorganelle" -name '*.path_sequence.fasta' 2>/dev/null | head -1)"
if [[ -z "$mito" ]]; then
    echo "ERROR: GetOrganelle produced no circular/path sequence." >&2
    echo "       Try more read pairs, or inspect $OUTDIR/getorganelle" >&2
    exit 1
fi
cp "$mito" "$OUTDIR/mitogenome.fasta"
echo "### mitogenome: $(grep -vc '>' "$OUTDIR/mitogenome.fasta") record(s), $(grep -v '>' "$OUTDIR/mitogenome.fasta" | tr -d '\n' | wc -c) bp"

# Pull cytb out of the new mitogenome by aligning the reference's cytb to it.
echo "### extracting cytb"
"$MM" run -n akodon bash -c "
    # cytb coordinates in the NC_025746.1 reference, via the panel's own records
    makeblastdb -in '$OUTDIR/mitogenome.fasta' -dbtype nucl -out '$OUTDIR/mitodb' >/dev/null
    blastn -query '$PANEL' -db '$OUTDIR/mitodb' -outfmt '6 sseqid sstart send pident length qseqid' \
           -max_target_seqs 5 -evalue 1e-50 2>/dev/null \
      | sort -k5,5nr | head -1 > '$OUTDIR/cytb_locus.tsv'
"
read -r sid sstart send _ <<<"$(cut -f1-4 "$OUTDIR/cytb_locus.tsv")"
[[ -n "${sid:-}" ]] || { echo "ERROR: no cytb hit in the assembled mitogenome" >&2; exit 1; }
if (( sstart > send )); then tmp=$sstart; sstart=$send; send=$tmp; rev="-r"; else rev=""; fi

"$MM" run -n akodon bash -c "
    samtools faidx '$OUTDIR/mitogenome.fasta' '${sid}:${sstart}-${send}' \
      | seqkit seq $rev > '$OUTDIR/cytb_query.fasta'
"
echo "### cytb recovered: $(grep -v '>' "$OUTDIR/cytb_query.fasta" | tr -d '\n' | wc -c) bp"

echo "### ranking against the genus panel"
"$MM" run -n akodon bash -c "
    makeblastdb -in '$PANEL' -dbtype nucl -out '$OUTDIR/paneldb' >/dev/null
    blastn -query '$OUTDIR/cytb_query.fasta' -db '$OUTDIR/paneldb' \
           -outfmt '6 sseqid pident length evalue bitscore stitle' \
           -max_target_seqs 1000 -evalue 1e-20 2>/dev/null > '$OUTDIR/cytb_hits.tsv'
"

echo
echo "================ TOP 15 HITS ================"
awk -F'\t' '{
    sp="?"; if (match($6, /Akodon [a-z]+/)) sp=substr($6, RSTART, RLENGTH)
    printf "  %-24s %6.2f%% id  %4d bp  %s\n", sp, $2, $3, $1
}' "$OUTDIR/cytb_hits.tsv" | head -15

echo
echo "========= BEST IDENTITY PER SPECIES ========="
awk -F'\t' '{
    sp="?"; if (match($6, /Akodon [a-z]+/)) sp=substr($6, RSTART, RLENGTH)
    if ($2 > best[sp]) { best[sp]=$2 }; n[sp]++
} END {
    for (s in best) printf "%8.2f\t%s\t%d\n", best[s], s, n[s]
}' "$OUTDIR/cytb_hits.tsv" | sort -rn | head -12 \
  | awk -F'\t' '{printf "  %-24s %6.2f%%   (%d seqs in panel)\n", $2, $1, $3}'

echo
top="$(awk -F'\t' 'NR==1{if (match($6,/Akodon [a-z]+/)) print substr($6,RSTART,RLENGTH)}' "$OUTDIR/cytb_hits.tsv")"
topid="$(awk -F'\t' 'NR==1{print $2}' "$OUTDIR/cytb_hits.tsv")"
echo "VERDICT: best match = ${top:-unknown} at ${topid:-?}% identity"
echo "  Expect >=99% to conspecifics and a clear gap (typically several percent)"
echo "  to A. cursor and other congeners. A narrow margin means re-check."
echo "  Full results: $OUTDIR/cytb_hits.tsv"
