#!/usr/bin/env bash
# Verify that RepeatMasker softmasking ACCUMULATES across the four rounds.
#
# THE QUESTION THIS ANSWERS
# Stage 10 runs four masking rounds, each taking the previous round's .masked
# output as input, and passes -xsmall every time. RepeatMasker documents -xsmall
# as "returns repetitive regions in lowercase (rest capitalized)". If a given
# build re-capitalises non-hit sequence when it writes .masked, then each round
# DISCARDS the previous rounds' softmasking rather than adding to it:
#
#   - round 2 runs with -nolow, so it will not re-find round 1's simple repeats
#   - rounds 3 and 4 use -lib only (no -species), so round 2's Dfam interspersed
#     masking survives only where the RepeatModeler library happens to hit the
#     same intervals
#
# The final genome would then be masked to roughly whatever the LAST round found
# instead of the union of all four -- badly under-masked going into GALBA and
# BRAKER3, which is a known cause of inflated, fragmented gene predictions.
#
# Reading each round's .tbl is NOT sufficient to answer this: "bases masked" in a
# .tbl is what THAT round found in ITS input, not the cumulative lowercase
# content of its output. Only counting the output files settles it.
#
# WHAT A PASS LOOKS LIKE
# Lowercase fraction must increase monotonically across rounds and land in the
# 40-48% band expected for a rodent (mouse 45.0%, rat 42.6%, cotton rat 41.1%).
# A flat or falling series means masking is being lost between rounds; the fix is
# to hard-mask rounds 2-4 and rebuild the softmasked genome at the end from the
# concatenated .out files with `bedtools maskfasta -soft`.
#
# Usage: verify_masking_chain.sh <repeatmasker_sample_dir> [expected_min_pct]

set -euo pipefail

DIR="${1:?usage: verify_masking_chain.sh <repeatmasker_sample_dir> [min_pct]}"
MIN_PCT="${2:-40}"
[[ -d "$DIR" ]] || { echo "ERROR: not a directory: $DIR" >&2; exit 1; }

# Single streaming pass per file, line at a time. Do NOT strip newlines first:
# that makes awk buffer the whole multi-gigabase genome as one record, costing
# ~6-8 GB of heap for a count that needs none, and mawk can fail outright on a
# record over 2 GB. FASTA line wrapping already bounds the record size.
masked_pct () {
    awk '
        /^>/ { next }
        { sub(/\r$/, ""); total += length($0); gsub(/[^acgtn]/, "", $0); lower += length($0) }
        END { if (total == 0) print "NA"; else printf("%.2f", 100 * lower / total) }
    ' "$1"
}

echo "RepeatMasker softmask accumulation check"
echo "dir: $DIR"
echo

shopt -s nullglob
declare -a labels=() files=()

# The unmasked filtered assembly is the round-0 baseline, if we can find it.
base="$(find -L "$DIR" -maxdepth 1 -name '*_filtered.fasta' ! -name '*.masked*' | head -1)"
[[ -n "$base" ]] && { labels+=("round0_input"); files+=("$base"); }

for tag in round1_simple_dfam round2_complex_dfam round3_known_repeats round4_unknown_repeats; do
    f="$(find -L "$DIR" -maxdepth 1 -name "*.${tag}.masked*" | sort | head -1)"
    [[ -n "$f" ]] && { labels+=("$tag"); files+=("$f"); }
done

if (( ${#files[@]} == 0 )); then
    echo "ERROR: no round outputs found under $DIR" >&2
    echo "       expected files matching *.round{1..4}_*.masked*" >&2
    exit 1
fi

printf '%-24s %10s %14s  %s\n' ROUND 'MASKED %' DELTA FILE
prev=""
status=0
for i in "${!files[@]}"; do
    pct="$(masked_pct "${files[$i]}")"
    if [[ -n "$prev" && "$pct" != "NA" && "$prev" != "NA" ]]; then
        delta="$(awk -v a="$pct" -v b="$prev" 'BEGIN{printf "%+.2f", a-b}')"
        if awk -v a="$pct" -v b="$prev" 'BEGIN{exit !(a < b - 0.01)}'; then
            delta="$delta  <-- DROPPED"
            status=1
        fi
    else
        delta="-"
    fi
    printf '%-24s %9s%% %14s  %s\n' "${labels[$i]}" "$pct" "$delta" "$(basename "${files[$i]}")"
    prev="$pct"
done

echo
final="$prev"
if [[ "$final" == "NA" ]]; then
    echo "VERDICT: could not measure the final round"
    exit 1
fi

if (( status != 0 )); then
    echo "VERDICT: FAIL - masking DROPPED between rounds."
    echo "  -xsmall is re-capitalising non-hit sequence, so each round is discarding"
    echo "  the previous rounds' softmasking. Hard-mask rounds 2-4 and rebuild the"
    echo "  final softmasked genome from the concatenated .out files:"
    echo "    cat *.round?_*.out | <to BED> | bedtools maskfasta -soft -fi <asm> -bed - -fo <out>"
    exit 1
fi

if awk -v p="$final" -v m="$MIN_PCT" 'BEGIN{exit !(p < m)}'; then
    echo "VERDICT: SUSPICIOUS - final masking ${final}% is below ${MIN_PCT}%."
    echo "  Rodent genomes run 40-48% repetitive (mouse 45.0, rat 42.6, cotton rat 41.1)."
    echo "  Masking accumulated, but less was found than expected. Check that the"
    echo "  RepeatModeler library is non-empty and that the Dfam rounds actually ran."
    exit 1
fi

echo "VERDICT: PASS - masking accumulates monotonically, final ${final}%,"
echo "  consistent with the 40-48% expected for a rodent genome."
