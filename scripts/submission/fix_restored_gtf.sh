#!/usr/bin/env bash
# Stage 19/20's header restore wrote the FULL original FASTA header into GTF
# column 1. A GTF seqname cannot contain whitespace: every parser truncates at
# the first space, and the value no longer matches the FASTA record id (which IS
# the first token). Repair by keeping only that first token -- which makes the
# GTF seqname identical to the assembly's record id, as intended.
set -uo pipefail
B=/mnt/d/HPC_Backup/akodon-genome-assembly-workflow
SRC="$B/annotation/original_headers/0339"
OUT="$B/submission/gtf_fixed"
mkdir -p "$OUT"

echo "=== available restored GTFs ==="
ls "$SRC"/*.gtf 2>/dev/null | xargs -n1 basename | sed 's/^/  /'
echo
for f in "$SRC"/*.gtf; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    awk -F'\t' -v OFS='\t' '/^#/{print; next} NF>=9 { sub(/[ \t].*$/,"",$1); print }' "$f" > "$OUT/$b"
    before=$(awk -F'\t' '!/^#/ && NF>=9{print $1}' "$f" | head -1)
    after=$(awk -F'\t' '!/^#/ && NF>=9{print $1}' "$OUT/$b" | head -1)
    printf '  %-56s "%s" -> "%s"\n' "$b" "${before:0:28}" "$after"
done
