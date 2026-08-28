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

# bedtools is not part of this pipeline's conda environments, so it is often
# absent on the cluster. Fall back to awk, which needs nothing beyond coreutils.
# Both paths produce byte-identical output. Set SOFTMASK_BACKEND=awk to force the
# fallback (used by the backend-equivalence test).
BACKEND="${SOFTMASK_BACKEND:-}"
if [[ -z "$BACKEND" ]]; then
    if command -v bedtools >/dev/null 2>&1; then
        BACKEND=bedtools
    else
        BACKEND="awk"
        echo "NOTE: bedtools not on PATH - using the awk backend (identical output)"
    fi
fi
case "$BACKEND" in
    bedtools)
        command -v bedtools >/dev/null 2>&1 \
            || { echo "ERROR: SOFTMASK_BACKEND=bedtools but bedtools is not on PATH" >&2; exit 1; } ;;
    awk) ;;
    *) echo "ERROR: SOFTMASK_BACKEND must be 'bedtools' or 'awk', got '$BACKEND'" >&2; exit 1 ;;
esac

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

if [[ "$BACKEND" == "bedtools" ]]; then
    bedtools merge -i "$WORK/sorted.bed" > "$WORK/merged.bed"
else
    # Sweep the sorted intervals, extending while they overlap or abut. This is
    # exactly `bedtools merge -d 0`: a new interval starts only when its start
    # lies strictly beyond the current end.
    #
    # `have` rather than testing chrom against "": Supernova names scaffolds
    # numerically ("0", "1", ...), and awk treats a numeric-looking field as a
    # strnum, so `chrom != ""` compares NUMERICALLY and 0 == "" is true. That
    # silently discards every interval on scaffold 0. Sequence names are also
    # forced to string comparison with ("") for the same reason -- otherwise
    # "01" and "1" would compare equal.
    awk 'BEGIN { OFS = "\t" }
        {
            if (!have || ($1 "") != (chrom "") || $2 > end) {
                if (have) print chrom, start, end
                chrom = $1; start = $2; end = $3; have = 1
            } else if ($3 > end) {
                end = $3
            }
        }
        END { if (have) print chrom, start, end }
    ' "$WORK/sorted.bed" > "$WORK/merged.bed"
fi

merged_n="$(wc -l < "$WORK/merged.bed")"
masked_bp="$(awk '{ s += $3 - $2 } END { print s + 0 }' "$WORK/merged.bed")"
echo "  merged intervals: $merged_n"
echo "  repeat-masked bp: $masked_bp"

echo "Applying soft-mask to $(basename "$ASSEMBLY") [$BACKEND]"
if [[ "$BACKEND" == "bedtools" ]]; then
    bedtools maskfasta -soft -fi "$ASSEMBLY" -bed "$WORK/merged.bed" -fo "$OUTPUT"
else
    # Load intervals per sequence, then rewrite each record with those ranges
    # lowercased. Output is wrapped at 60 columns, matching bedtools maskfasta.
    awk -v bed="$WORK/merged.bed" '
        function flush_record(   i, j, lo, hi, seqlen) {
            # `have` not `name == ""`: scaffold names here are numeric strings,
            # and awk would compare "0" to "" numerically and skip the record.
            if (!have) return
            seqlen = length(seq)
            for (i = 1; i <= n[name]; i++) {
                lo = s[name, i] + 1          # BED is 0-based half-open
                hi = e[name, i]
                if (lo < 1) lo = 1
                if (hi > seqlen) hi = seqlen
                if (hi >= lo)
                    seq = substr(seq, 1, lo - 1) tolower(substr(seq, lo, hi - lo + 1)) substr(seq, hi + 1)
            }
            print ">" hdr
            for (j = 1; j <= seqlen; j += 60) print substr(seq, j, 60)
        }
        BEGIN {
            while ((getline line < bed) > 0) {
                split(line, f, "\t")
                i = ++n[f[1]]
                s[f[1], i] = f[2]; e[f[1], i] = f[3]
            }
            close(bed)
        }
        /^>/ {
            flush_record()
            hdr = substr($0, 2)
            name = hdr; sub(/[ \t].*$/, "", name)   # FASTA id is the first token
            seq = ""; have = 1
            next
        }
        { sub(/\r$/, ""); seq = seq $0 }
        END { flush_record() }
    ' "$ASSEMBLY" > "$OUTPUT"
fi
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
