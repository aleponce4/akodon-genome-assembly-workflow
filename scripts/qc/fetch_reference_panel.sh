#!/usr/bin/env bash
# Fetch the reference data identify_species.sh needs, from NCBI:
#   NC_025746.1  Akodon montensis mitogenome  (GetOrganelle seed + cytb locus)
#   NC_088492.1  Akodon affinis mitogenome    (outgroup sanity check)
#   akodon_cytb_panel.fasta  genus-wide cytb panel for the identity ranking
#
# The panel is fetched rather than committed so it stays current and the repo
# stays free of third-party sequence data. Record the retrieval date and the
# sequence count in the methods -- GenBank content changes over time.
#
# Usage: fetch_reference_panel.sh [outdir]

set -euo pipefail

OUTDIR="${1:-${REFDIR:-/mnt/d/HPC_Backup/local_work/reference}}"
EUTILS="https://eutils.ncbi.nlm.nih.gov/entrez/eutils"
mkdir -p "$OUTDIR"

echo "### mitogenome references"
for acc in NC_025746.1 NC_088492.1; do
    if [[ -s "$OUTDIR/${acc}.fasta" ]]; then
        echo "  $acc already present"
        continue
    fi
    curl -fsS "${EUTILS}/efetch.fcgi?db=nuccore&id=${acc}&rettype=fasta&retmode=text" \
         -o "$OUTDIR/${acc}.fasta"
    printf '  %s  %s bp  %s\n' "$acc" \
        "$(grep -v '>' "$OUTDIR/${acc}.fasta" | tr -d '\n' | wc -c)" \
        "$(head -1 "$OUTDIR/${acc}.fasta" | cut -c2-60)"
    sleep 1
done

PANEL="$OUTDIR/akodon_cytb_panel.fasta"
if [[ -s "$PANEL" ]]; then
    echo "### cytb panel already present: $(grep -c '>' "$PANEL") sequences"
else
    echo "### cytb panel (genus-wide, 700-1200 bp)"
    query='Akodon%5BOrganism%5D+AND+(cytb%5BGene%5D+OR+%22cytochrome+b%22%5BAll+Fields%5D)+AND+700:1200%5BSLEN%5D'
    ids="$(curl -fsS "${EUTILS}/esearch.fcgi?db=nuccore&term=${query}&retmax=1200&retmode=json" \
           | python3 -c 'import sys,json; print(",".join(json.load(sys.stdin)["esearchresult"]["idlist"]))')"
    total="$(tr ',' '\n' <<<"$ids" | grep -c .)"
    echo "  $total records to fetch"

    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    tr ',' '\n' <<<"$ids" > "$tmp/all_ids"
    split -l 300 "$tmp/all_ids" "$tmp/chunk_"
    : > "$PANEL"
    for f in "$tmp"/chunk_*; do
        curl -fsS "${EUTILS}/efetch.fcgi?db=nuccore&id=$(paste -sd, "$f")&rettype=fasta&retmode=text" \
            >> "$PANEL"
        sleep 1
    done
    echo "  fetched $(grep -c '>' "$PANEL") sequences"
fi

echo
echo "### species represented in the panel"
grep '>' "$PANEL" | grep -o 'Akodon [a-z]*' | sort | uniq -c | sort -rn \
  | awk '{printf "  %5d  %s %s\n", $1, $2, $3}' | head -20
echo
printf 'retrieved: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$OUTDIR/PANEL_PROVENANCE.txt"
printf 'panel sequences: %s\n' "$(grep -c '>' "$PANEL")" >> "$OUTDIR/PANEL_PROVENANCE.txt"
printf 'source: NCBI nuccore via E-utilities\n' >> "$OUTDIR/PANEL_PROVENANCE.txt"
echo "provenance written to $OUTDIR/PANEL_PROVENANCE.txt"
