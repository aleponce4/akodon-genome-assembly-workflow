#!/usr/bin/env bash
# Rebuild a correctly soft-masked genome as the UNION of all RepeatMasker rounds.
#
# WHY THIS EXISTS
# Stage 10 chains four RepeatMasker rounds, each consuming the previous round's
# .masked output, and passes -xsmall every time. -xsmall returns repeats in
# lowercase and "the rest capitalized" -- so each round RE-CAPITALISES everything
# it did not itself hit, discarding the previous rounds' soft-masking instead of
# adding to it. Measured on Akodon 0339:
#
#     round1 simple  (Dfam)          2.88%
#     round2 complex (Dfam)         39.12%   +36.24
#     round3 known   (RepeatModeler) 35.73%   -3.39   <- dropped
#     round4 unknown (RepeatModeler)  8.01%  -27.72   <- dropped
#
# The genome handed to GALBA/BRAKER3 was 8% masked instead of the ~40-48%
# expected for a rodent, which inflates spurious gene models in repeat sequence.
#
# THE FIX DOES NOT REQUIRE RE-RUNNING REPEATMASKER.
# Each round's .out file is a correct record of what THAT round found. The union
# of all four .out interval sets is the full repeat annotation; applying it to
# the ORIGINAL unmasked assembly reconstructs the genome the pipeline should have
# produced. Overlaps between rounds are handled by `bedtools merge`.
#
# Usage: rebuild_softmask.sh <repeatmasker_sample_dir> <original_assembly.fasta> <output.fasta>

set -euo pipefail

RM_DIR="${1:?usage: rebuild_softmask.sh <rm_sample_dir> <original.fasta> <out.fasta>}"
ASSEMBLY="${2:?original unmasked assembly required}"
OUTPUT="${3:?output path required}"
WORK="${TMPDIR:-/tmp}/rebuild_softmask.$$"

[[ -d "$RM_DIR"    ]] || { echo "ERROR: not a directory: $RM_DIR" >&2; exit 1; }
[[ -f "$ASSEMBLY"  ]] || { echo "ERROR: assembly not found: $ASSEMBLY" >&2; exit 1; }
command -v bedtools >/dev/null 2>&1 || { echo "ERROR: bedtools not on PATH" >&2; exit 1; }

mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

shopt -s nullglob
outs=("$RM_DIR"/*.out)
(( ${#outs[@]} > 0 )) || { echo "ERROR: no .out files in $RM_DIR" >&2; exit 1; }

echo "Rebuilding soft-mask from ${#outs[@]} RepeatMasker .out file(s)"
printf '%-52s %14s\n' FILE INTERVALS
: > "$WORK/all.bed"
for f in "${outs[@]}"; do
    # RepeatMasker .out: 2 header lines then a blank, then fixed columns.
    #   $5 = query sequence, $6 = begin (1-based), $7 = end (inclusive)
    # BED is 0-based half-open, so start = begin-1. Guard against malformed rows.
    n="$(awk 'NR > 3 && NF >= 7 && $6 ~ /^[0-9]+$/ && $7 ~ /^[0-9]+$/ && $7 >= $6 {
                 printf "%s\t%d\t%d\n", $5, $6 - 1, $7
             }' "$f" | tee -a "$WORK/all.bed" | wc -l)"
    printf '%-52s %14s\n' "$(basename "$f")" "$n"
done

total_raw="$(wc -l < "$WORK/all.bed")"
echo "  total intervals before merge: $total_raw"
[[ "$total_raw" -gt 0 ]] || { echo "ERROR: no usable intervals parsed" >&2; exit 1; }

echo "Sorting and merging overlapping intervals"
LC_ALL=C sort -k1,1 -k2,2n -S 50% "$WORK/all.bed" > "$WORK/sorted.bed"
bedtools merge -i "$WORK/sorted.bed" > "$WORK/merged.bed"
merged_n="$(wc -l < "$WORK/merged.bed")"
masked_bp="$(awk '{ s += $3 - $2 } END { print s + 0 }' "$WORK/merged.bed")"
echo "  merged intervals: $merged_n"
echo "  repeat-masked bp: $masked_bp"

echo "Applying soft-mask to $(basename "$ASSEMBLY")"
bedtools maskfasta -soft -fi "$ASSEMBLY" -bed "$WORK/merged.bed" -fo "$OUTPUT"
[[ -s "$OUTPUT" ]] || { echo "ERROR: output was not created: $OUTPUT" >&2; exit 1; }

echo
echo "Verifying result"
awk '
    /^>/ { next }
    { sub(/\r$/, ""); total += length($0); gsub(/[^acgtn]/, "", $0); lower += length($0) }
    END {
        if (total == 0) { print "  ERROR: no sequence"; exit 1 }
        printf "  genome length : %d bp\n", total
        printf "  soft-masked   : %d bp (%.2f%%)\n", lower, 100 * lower / total
        if (100 * lower / total < 20) {
            print "  WARNING: below 20% -- expected 40-48% for a rodent"
            exit 1
        }
    }
' "$OUTPUT"

echo
echo "Done: $OUTPUT"
echo "Compare against the individual rounds with:"
echo "  scripts/qc/verify_masking_chain.sh $RM_DIR"
