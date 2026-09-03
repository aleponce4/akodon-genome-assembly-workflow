#!/usr/bin/env bash
# Apply the FASTA trim offsets to GTF coordinates.
#
# genbank_clean.sh removes leading/trailing N from scaffolds, which renumbers
# every downstream base. Any annotation on a trimmed scaffold must move with it
# or the GTF silently points at the wrong sequence -- the kind of error that
# produces a valid-looking submission describing the wrong thing.
set -uo pipefail
B=/mnt/d/HPC_Backup/akodon-genome-assembly-workflow
RPT="$B/submission/akodon_0339_genbank.trim_report.tsv"
SRC="$B/submission/gtf_fixed"
OUT="$B/submission/gtf_ready"
DROPPED=/tmp/dropped_ids.txt
mkdir -p "$OUT"

grep '^>' "$B/output/filtered_fasta/akodon_0339_pseudohap_filtered.fasta" | sed 's/^>//; s/[ \t].*//' | sort -u > /tmp/all_ids
grep '^>' "$B/submission/akodon_0339_genbank.fasta"                        | sed 's/^>//; s/[ \t].*//' | sort -u > /tmp/kept_ids
comm -23 /tmp/all_ids /tmp/kept_ids > "$DROPPED"

echo "trim offsets to apply:"; awk 'NR>1{printf "  %s: -%s from 5p\n",$1,$3}' "$RPT"
echo "scaffolds removed entirely: $(wc -l < "$DROPPED")"
echo

for f in "$SRC"/*.gtf; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    awk -F'\t' -v OFS='\t' -v rpt="$RPT" -v drop="$DROPPED" '
        BEGIN {
            while ((getline l < rpt) > 0) { split(l,a,"\t"); if (a[1]!="sequence") off[a[1]]=a[3]+0 }
            while ((getline l < drop) > 0) gone[l]=1
        }
        /^#/ { print; next }
        NF < 9 { next }
        {
            if ($1 in gone) { removed++; next }
            t = ($1 in off) ? off[$1] : 0
            if (t > 0) {
                ns = $4 - t; ne = $5 - t
                if (ne < 1) { removed++; next }          # entirely inside trimmed region
                if (ns < 1) { ns = 1; clamped++ }        # straddles the boundary
                $4 = ns; $5 = ne; shifted++
            }
            print
        }
        END {
            printf("  %-52s shifted=%d clamped=%d removed=%d\n", FILENAME_B, shifted+0, clamped+0, removed+0) > "/dev/stderr"
        }
    ' FILENAME_B="$b" "$f" > "$OUT/$b" 2>>/tmp/shift.log
done
cat /tmp/shift.log | sed 's/^/  /'; rm -f /tmp/shift.log

echo
echo "=== verify: any coordinate now exceeds its scaffold length? ==="
python3 - <<'PY'
import os
B="/mnt/d/HPC_Backup/akodon-genome-assembly-workflow"
lens={}
name=None; L=0
with open(f"{B}/submission/akodon_0339_genbank.fasta") as f:
    for line in f:
        if line.startswith(">"):
            if name: lens[name]=L
            name=line[1:].split()[0]; L=0
        else: L+=len(line.strip())
    if name: lens[name]=L
bad=0; checked=0
d=f"{B}/submission/gtf_ready"
for fn in sorted(os.listdir(d)):
    n=0
    with open(os.path.join(d,fn)) as f:
        for line in f:
            if line.startswith("#"): continue
            p=line.rstrip("\n").split("\t")
            if len(p)<9: continue
            checked+=1
            sl=lens.get(p[0])
            if sl is None or int(p[4])>sl or int(p[3])<1: n+=1
    if n: print(f"  {fn}: {n} out-of-range")
    bad+=n
print(f"  features checked: {checked:,}")
print(f"  out-of-range   : {bad}   {'OK' if bad==0 else '<-- PROBLEM'}")
PY
