#!/usr/bin/env bash
# Remove childless mRNA features.
#
# The source GTF carried BOTH a 'transcript' and an 'mRNA' line for 723 genes,
# so after transcript->mRNA those genes end up with two identical mRNA. GenBank
# requires 1:1 gene:mRNA:CDS, and a duplicate transcript would either be rejected
# or silently produce a second identical protein.
#
# The discriminator is children: exon/CDS features parent to the ORIGINAL
# transcript id, leaving the AGAT-generated mRNA with nothing beneath it. Drop
# any mRNA whose ID appears in no child's Parent -- general, and does not rely on
# recognising AGAT's id naming.
set -uo pipefail
B=/mnt/d/HPC_Backup/akodon-genome-assembly-workflow
MODEL="${1:-tsebra_config_5}"
IN="$B/submission/gff3/${MODEL}.genbank.gff3"
OUT="$B/submission/gff3/${MODEL}.genbank.dedup.gff3"

awk -F'\t' -v OFS='\t' '
    FNR==NR {
        if (/^#/ || NF<9) next
        if ($3=="exon" || $3=="CDS" || $3=="start_codon" || $3=="stop_codon" \
            || $3=="five_prime_UTR" || $3=="three_prime_UTR") {
            p=$9; sub(/.*Parent=/,"",p); sub(/;.*/,"",p); haschild[p]=1
        }
        next
    }
    /^#/ { print; next }
    NF<9 { next }
    $3=="mRNA" {
        id=$9; sub(/.*ID=/,"",id); sub(/;.*/,"",id)
        if (!(id in haschild)) { removed++; next }
    }
    { print }
    END { printf("childless mRNA removed: %d\n", removed+0) > "/dev/stderr" }
' "$IN" "$IN" > "$OUT"

echo
echo "=== final counts ==="
for t in gene mRNA exon CDS; do printf '  %-6s %s\n' "$t" "$(awk -F'\t' -v T="$t" '!/^#/&&$3==T' "$OUT" | wc -l)"; done
echo
echo "=== genes by mRNA count (must be all 1) ==="
awk -F'\t' '!/^#/ && $3=="mRNA"{p=$9; sub(/.*Parent=/,"",p); sub(/;.*/,"",p); c[p]++}
     END{for(k in c) n[c[k]]++; for(x in n) printf "  %s mRNA: %d genes\n", x, n[x]}' "$OUT" | sort
echo
echo "=== orphan check after dedup ==="
awk -F'\t' '!/^#/&&$3=="mRNA"{p=$9;sub(/.*ID=/,"",p);sub(/;.*/,"",p);ids[p]=1;next}
     !/^#/&&$3=="CDS"{p=$9;sub(/.*Parent=/,"",p);sub(/;.*/,"",p); if(!(p in ids))bad++; tot++}
     END{printf "  CDS=%d orphaned=%d\n", tot, bad+0}' "$OUT"
ls -la "$OUT"
