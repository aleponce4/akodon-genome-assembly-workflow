#!/usr/bin/env bash
# Collect every headline metric the pipeline has already produced into one
# table, so assembly selection and the paper's stats table come from the tool
# outputs themselves rather than from anyone's notes.
#
# Reads (whatever is present):
#   Supernova   outs/report.txt          input DNA quality + assembly summary
#   QUAST       report.tsv               contiguity of the filtered assemblies
#   BUSCO       short_summary*.txt       gene-space completeness
#   RepeatMasker  *.tbl                  repeat content per masking round
#
# Usage: collect_run_metrics.sh [project_root] [outdir]
# Default project_root is the repo root; default outdir is <root>/output/run_metrics

set -euo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
OUT="${2:-$ROOT/output/run_metrics}"
mkdir -p "$OUT"

hr () { printf '%s\n' "------------------------------------------------------------"; }

########## Supernova
sn="$OUT/supernova_metrics.tsv"
printf 'sample\treads_M\traw_cov\teff_cov\tmol_len_kb\tp10\tbarcode_frac\tunbar_pct\tdups_pct\tphased_pct\test_genome_gb\thetdist_bp\tscaffold_n50\tcontig_n50\tphaseblock_n50\tlong_scaffolds\tasm_size\tmissing_10kb_pct\n' > "$sn"
found_sn=0
while IFS= read -r rpt; do
    [[ -s "$rpt" ]] || continue
    found_sn=$((found_sn+1))
    s="$(awk -F'[][]' '/^- \[/{print $2; exit}' "$rpt")"
    v () { awk -v k="$1" -F'=' '$0 ~ ("= " k "  *$") || $0 ~ ("= " k "$") {
               split($1, a, "-"); gsub(/^[ \t-]+|[ \t]+$/, "", $1); print $1; exit }' "$rpt" \
           | awk '{print $1, $2}'; }
    g () { grep -m1 "= $1 " "$rpt" 2>/dev/null | sed 's/^- *//' | awk '{print $1}'; }
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${s:-$(basename "$(dirname "$(dirname "$rpt")")")}" \
        "$(g READS)" "$(g 'RAW COV')" "$(g 'EFFECTIVE COV')" "$(g 'MOLECULE LEN')" \
        "$(g P10)" "$(g 'BARCODE FRACTION')" "$(g UNBAR)" "$(g DUPS)" "$(g PHASED)" \
        "$(g 'EST GENOME SIZE')" "$(g HETDIST)" "$(g 'SCAFFOLD N50')" "$(g 'CONTIG N50')" \
        "$(g 'PHASEBLOCK N50')" "$(g 'LONG SCAFFOLDS')" "$(g 'ASSEMBLY SIZE')" \
        "$(g 'MISSING 10KB')" >> "$sn"
done < <(find -L "$ROOT" -type f -path '*/outs/report.txt' 2>/dev/null | sort)

hr; echo "SUPERNOVA  ($found_sn reports)"; hr
if (( found_sn )); then column -t -s $'\t' "$sn"; else echo "  none found"; fi

########## QUAST
echo; hr; echo "QUAST"; hr
qt="$(find -L "$ROOT" -type f -name 'report.tsv' -path '*QUAST*' 2>/dev/null | head -1)"
if [[ -s "${qt:-}" ]]; then
    cp "$qt" "$OUT/quast_report.tsv"
    awk -F'\t' 'NR==1 || /^(# contigs|Total length|Largest contig|N50|N90|L50|GC|# N.s per)/' "$qt" \
      | cut -f1-9 | column -t -s $'\t'
    echo "  (full table: $OUT/quast_report.tsv)"
else
    echo "  none found"
fi

########## BUSCO
echo; hr; echo "BUSCO"; hr
bt="$OUT/busco_summary.tsv"
printf 'assembly\tlineage\tsummary\n' > "$bt"
nb=0
while IFS= read -r f; do
    [[ -s "$f" ]] || continue
    line="$(grep -m1 -E '^\s+C:[0-9]' "$f" | sed 's/^[ \t]*//')"
    [[ -n "$line" ]] || continue
    lin="$(grep -m1 'lineage dataset' "$f" | sed 's/.*is: //; s/ (.*//')"
    name="$(basename "$f" | sed 's/^short_summary\.\(specific\|generic\)\.//; s/\.txt$//')"
    printf '%s\t%s\t%s\n' "$name" "$lin" "$line" >> "$bt"
    nb=$((nb+1))
done < <(find -L "$ROOT" -type f -name 'short_summary*.txt' 2>/dev/null | sort -u)
if (( nb )); then
    sort -u "$bt" | column -t -s $'\t'
else
    # Fall back to full_table.tsv. The one-line C/S/D/F/M summary is fully
    # derivable from it, so a missing short_summary.txt is not a missing result.
    # Duplicated BUSCOs occupy one ROW PER COPY, so every status must be counted
    # over UNIQUE busco ids or D is inflated and the percentages do not sum to n.
    nft=0
    while IFS= read -r ft; do
        [[ -s "$ft" ]] || continue
        name="$(basename "$(dirname "$(dirname "$ft")")")"
        lin="$(awk -F'is: ' '/lineage dataset/{split($2,a," "); print a[1]; exit}' "$ft")"
        awk -F'\t' -v name="$name" -v lin="${lin:-unknown}" '
            /^#/ { next }
            NF >= 2 { status[$1] = ($1 in status && status[$1] == "Duplicated") ? status[$1] : $2 }
            $2 == "Duplicated" { status[$1] = "Duplicated" }
            END {
                for (id in status) {
                    s = status[id]; n++
                    if (s == "Complete")        single++
                    else if (s == "Duplicated") dup++
                    else if (s == "Fragmented") frag++
                    else if (s == "Missing")    miss++
                }
                comp = single + dup
                printf "%s\t%s\tC:%.1f%%[S:%.1f%%,D:%.1f%%],F:%.1f%%,M:%.1f%%,n:%d  (from full_table.tsv)\n",
                    name, lin, 100*comp/n, 100*single/n, 100*dup/n, 100*frag/n, 100*miss/n, n
                printf "%s\t%s\tcounts: C=%d S=%d D=%d F=%d M=%d\n", name, lin, comp, single, dup, frag, miss
            }
        ' "$ft" >> "$bt"
        nft=$((nft+1))
    done < <(find -L "$ROOT" -type f -name 'full_table.tsv' 2>/dev/null | sort)
    if (( nft )); then
        echo "  (short_summary*.txt absent; derived from $nft full_table.tsv)"
        sort -u "$bt" | column -t -s $'\t'
    else
        echo "  none found"
    fi
fi

########## RepeatMasker
echo; hr; echo "REPEATMASKER (per round; verifies masking accumulates)"; hr
rt="$OUT/repeatmasker_rounds.tsv"
printf 'sample\tround\tinput_file\tbases_masked\tpct\n' > "$rt"
nr=0
while IFS= read -r f; do
    [[ -s "$f" ]] || continue
    samp="$(basename "$(dirname "$f")")"
    rnd="$(basename "$f" | sed 's/.*\.\(round[0-9]*_[a-z_]*\)\.tbl/\1/')"
    inp="$(awk -F': *' '/^file name:/{print $2; exit}' "$f")"
    mb="$(awk '/^bases masked:/{print $3; exit}' "$f")"
    pc="$(awk '/^bases masked:/{gsub(/[()%]/,""); print $(NF-1); exit}' "$f")"
    printf '%s\t%s\t%s\t%s\t%s\n' "$samp" "$rnd" "$(basename "${inp:-?}")" "${mb:-?}" "${pc:-?}" >> "$rt"
    nr=$((nr+1))
done < <(find -L "$ROOT" -type f -name '*.tbl' -path '*Repeat*' 2>/dev/null | sort)
if (( nr )); then
    column -t -s $'\t' "$rt"
    echo
    echo "  CHECK: each round's input_file must be the PREVIOUS round's .masked output."
    echo "  CHECK: rounds should sum to roughly 40-48% for a rodent."
else
    echo "  none found"
fi

echo; hr
echo "Written to: $OUT"
