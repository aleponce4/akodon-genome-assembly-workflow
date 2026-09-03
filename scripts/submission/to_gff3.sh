#!/usr/bin/env bash
# Convert the selected BRAKER/TSEBRA GTF into a normalised GFF3 suitable for
# table2asn. AGAT rebuilds the feature hierarchy (gene -> mRNA -> exon/CDS),
# adds ID/Parent, and reconciles the mixed 'transcript'/'mRNA' feature types
# that GenBank will not accept.
set -uo pipefail
export MAMBA_ROOT_PREFIX="$HOME/micromamba"
MM="$HOME/bin/micromamba"
B=/mnt/d/HPC_Backup/akodon-genome-assembly-workflow
MODEL="${1:-tsebra_config_5}"
IN="$B/submission/gtf_ready/${MODEL}_longest_isoform_original_headers.gtf"
OUT="$B/submission/gff3"
W="$HOME/agat_work"
mkdir -p "$OUT" "$W"

[ -f "$IN" ] || { echo "missing $IN"; exit 1; }
cp "$IN" "$W/in.gtf"

echo "### AGAT convert+normalise ($(date +%H:%M:%S))"
cd "$W"
"$MM" run -n akodon-agat agat_convert_sp_gxf2gxf.pl -g "$W/in.gtf" -o "$W/out.gff3" \
    > "$W/agat.log" 2>&1
rc=$?
echo "  exit=$rc"
[ -s "$W/out.gff3" ] || { echo "  FAILED"; tail -20 "$W/agat.log"; exit 1; }

cp "$W/out.gff3" "$OUT/${MODEL}.agat.gff3"
echo
echo "### feature types after conversion"
awk -F'\t' '!/^#/{print $3}' "$OUT/${MODEL}.agat.gff3" | sort | uniq -c | sort -rn
echo
echo "### sample gene + mRNA + CDS attributes"
awk -F'\t' '!/^#/ && $3=="gene"{print "  gene: " $9; exit}' "$OUT/${MODEL}.agat.gff3"
awk -F'\t' '!/^#/ && $3=="mRNA"{print "  mRNA: " $9; exit}' "$OUT/${MODEL}.agat.gff3"
awk -F'\t' '!/^#/ && $3=="CDS"{print "  CDS : " $9; exit}' "$OUT/${MODEL}.agat.gff3"
echo
echo "### 1:1 mRNA:CDS check (GenBank requirement)"
nm=$(awk -F'\t' '!/^#/ && $3=="mRNA"' "$OUT/${MODEL}.agat.gff3" | wc -l)
ng=$(awk -F'\t' '!/^#/ && $3=="gene"' "$OUT/${MODEL}.agat.gff3" | wc -l)
echo "  genes=$ng  mRNA=$nm"
