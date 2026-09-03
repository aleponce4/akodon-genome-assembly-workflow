#!/usr/bin/env bash
# Drop gene models whose CDS is too short to encode a real protein.
# table2asn errors on these (SEQ_INST.ShortSeq); a 3-8 residue "protein" is a
# broken model, not a short gene. Threshold 30 bp (10 aa) is deliberately
# conservative -- it removes only the unambiguous cases (22 of 24,200 = 0.09%).
set -uo pipefail
B=/mnt/d/HPC_Backup/akodon-genome-assembly-workflow
MODEL="${1:-tsebra_config_5}"
MINCDS="${2:-30}"
IN="$B/submission/gff3/${MODEL}.genbank.dedup.gff3"
OUT="$B/submission/gff3/${MODEL}.genbank.final.gff3"

awk -F'\t' -v OFS='\t' -v mincds="$MINCDS" '
    # pass 1: CDS length per transcript, and the gene each transcript belongs to
    FNR==NR {
        if (/^#/ || NF<9) next
        if ($3=="CDS") { p=$9; sub(/.*Parent=/,"",p); sub(/;.*/,"",p); clen[p]+=$5-$4+1 }
        else if ($3=="mRNA") {
            id=$9; sub(/.*ID=/,"",id); sub(/;.*/,"",id)
            g=$9;  sub(/.*Parent=/,"",g); sub(/;.*/,"",g)
            geneof[id]=g
        }
        next
    }
    FNR==1 {  # decide what to drop, once
        for (t in clen) if (clen[t] < mincds) { dropTx[t]=1; dropGene[geneof[t]]=1; nd++ }
        printf("gene models dropped (CDS < %d bp): %d\n", mincds, nd+0) > "/dev/stderr"
    }
    /^#/ { print; next }
    NF<9 { next }
    {
        id=$9; sub(/.*ID=/,"",id);     sub(/;.*/,"",id)
        pa=$9; sub(/.*Parent=/,"",pa); sub(/;.*/,"",pa)
        if ($3=="gene" && (id in dropGene)) next
        if ($3=="mRNA" && (id in dropTx)) next
        if ($3!="gene" && $3!="mRNA" && (pa in dropTx)) next
        print
    }
' "$IN" "$IN" > "$OUT"

echo
echo "=== final GFF3 ==="
for t in gene mRNA exon CDS; do printf '  %-6s %s\n' "$t" "$(awk -F'\t' -v T="$t" '!/^#/&&$3==T' "$OUT" | wc -l)"; done
echo "  smallest CDS now: $(awk -F'\t' '!/^#/&&$3=="CDS"{p=$9;sub(/.*Parent=/,"",p);sub(/;.*/,"",p);l[p]+=$5-$4+1}END{m=1e9;for(k in l)if(l[k]<m)m=l[k];print m" bp"}' "$OUT")"
ls -la "$OUT"
