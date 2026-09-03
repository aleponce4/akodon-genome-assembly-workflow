#!/usr/bin/env bash
# Final GFF3 normalisation for table2asn.
#   1. transcript -> mRNA. GenBank expects mRNA for protein-coding transcripts;
#      'transcript' is a generic SO term table2asn does not map to a CDS parent.
#   2. drop 'intron' -- table2asn ignores it, and dropping avoids noise in the
#      discrepancy report.
#   3. add product=hypothetical protein to every CDS. NCBI REQUIRES a product on
#      CDS; without functional evidence 'hypothetical protein' is the correct and
#      expected placeholder. The product must sit on the CDS, not the gene or
#      mRNA -- table2asn copies CDS product TO the mRNA and never the reverse, so
#      putting it higher silently yields 'hypothetical protein' everywhere.
#   locus_tag is deliberately NOT added: table2asn generates it from
#   -locus-tag-prefix, so the structural work does not wait on BioProject
#   registration.
set -uo pipefail
B=/mnt/d/HPC_Backup/akodon-genome-assembly-workflow
MODEL="${1:-tsebra_config_5}"
IN="$B/submission/gff3/${MODEL}.agat.gff3"
OUT="$B/submission/gff3/${MODEL}.genbank.gff3"
[ -f "$IN" ] || { echo "missing $IN"; exit 1; }

awk -F'\t' -v OFS='\t' '
    /^#/ { print; next }
    NF < 9 { next }
    $3 == "intron" { dropped++; next }
    {
        if ($3 == "transcript") { $3 = "mRNA"; conv++ }
        if ($3 == "CDS" && $9 !~ /(^|;)product=/) { $9 = $9 ";product=hypothetical protein"; prod++ }
        print
    }
    END {
        printf("transcript->mRNA : %d\n", conv+0)   > "/dev/stderr"
        printf("intron dropped   : %d\n", dropped+0)> "/dev/stderr"
        printf("product added    : %d\n", prod+0)   > "/dev/stderr"
    }
' "$IN" > "$OUT"

echo
echo "=== feature types in the GenBank-ready GFF3 ==="
awk -F'\t' '!/^#/{print $3}' "$OUT" | sort | uniq -c | sort -rn
echo
echo "=== 1:1 gene:mRNA ==="
printf '  genes=%s  mRNA=%s\n' "$(awk -F'\t' '!/^#/&&$3=="gene"' "$OUT" | wc -l)" "$(awk -F'\t' '!/^#/&&$3=="mRNA"' "$OUT" | wc -l)"
echo
echo "=== sample CDS attributes ==="
awk -F'\t' '!/^#/&&$3=="CDS"{print "  "$9; exit}' "$OUT"
ls -la "$OUT"
