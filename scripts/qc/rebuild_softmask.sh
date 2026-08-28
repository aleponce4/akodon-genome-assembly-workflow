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

# The awk backend is the DEFAULT, for two reasons.
#
# 1. Correctness. `bedtools maskfasta` truncates FASTA headers at the first
#    whitespace, discarding Supernova's trailing metadata:
#        source   >0 edges=1350105..1171819 left=... ver=1.10 style=4
#        bedtools >0
#    Stage 11 records the FULL original header in its map and stage 20 restores
#    it, so truncation would propagate into the final deliverables and into
#    anything submitted to GenBank.
# 2. Availability. bedtools is not installed by any of this pipeline's conda
#    environments, so on the cluster it is usually absent anyway.
#
# The two backends were verified to produce identical SEQUENCE on the real 2.29 Gb
# assembly (same md5 of the unwrapped sequence, same 1,000,455,906 masked bp);
# they differ only in that header handling. Set SOFTMASK_BACKEND=bedtools to
# force the other path.
BACKEND="${SOFTMASK_BACKEND:-awk}"
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

# Every interval name must exist in the assembly. If stage 03's MIN_SCAFFOLD_BP
# changed, or the assembly was re-run, Supernova's numeric scaffold names shift
# and the .out coordinates then refer to different sequences. Both backends
# silently ignore intervals for names they cannot find, which would install a
# genome masked in the WRONG PLACES while still landing in a plausible-looking
# percentage band. Catch it here instead.
echo "Checking that every interval's sequence exists in the assembly"
grep '^>' "$ASSEMBLY" | sed 's/^>//; s/[ \t].*$//' | LC_ALL=C sort -u > "$WORK/asm_names"
cut -f1 "$WORK/merged.bed" | LC_ALL=C sort -u > "$WORK/bed_names"
LC_ALL=C comm -23 "$WORK/bed_names" "$WORK/asm_names" > "$WORK/orphan_names"
orphans="$(wc -l < "$WORK/orphan_names")"
if (( orphans > 0 )); then
    echo "ERROR: $orphans sequence name(s) in the RepeatMasker .out files are absent from $(basename "$ASSEMBLY")" >&2
    echo "       The .out files were produced against a DIFFERENT assembly, so their" >&2
    echo "       coordinates do not apply. Masking would land in the wrong places." >&2
    echo "       First few:" >&2
    head -5 "$WORK/orphan_names" | sed 's/^/         /' >&2
    exit 1
fi
echo "  all $(wc -l < "$WORK/bed_names") interval sequence names resolve"

echo "Applying soft-mask to $(basename "$ASSEMBLY") [$BACKEND]"
if [[ "$BACKEND" == "bedtools" ]]; then
    bedtools maskfasta -soft -fi "$ASSEMBLY" -bed "$WORK/merged.bed" -fo "$OUTPUT"
else
    # Streaming, one line at a time. Accumulating each scaffold into a single
    # awk string is O(n^2): a 21.5 Mb scaffold built from 60-character lines
    # costs ~359k reallocations copying the whole string each time, which does
    # not finish. Here each line is masked and emitted immediately, and the
    # interval list is walked with a cursor that only moves forward, so the
    # whole pass is linear in (bases + intervals) with bounded memory.
    #
    # Line structure is preserved rather than rewrapped: the input is already
    # 60-column wrapped, so this matches bedtools maskfasta byte for byte while
    # never holding a whole scaffold in memory.
    awk -v bed="$WORK/merged.bed" '
        BEGIN {
            # merged.bed is grouped by sequence and sorted by start, so store it
            # flat with a per-sequence [first, last] index range.
            m = 0
            while ((getline line < bed) > 0) {
                split(line, f, "\t")
                c = f[1] ""
                if (!(c in first)) first[c] = ++m; else m++
                S[m] = f[2] + 0; E[m] = f[3] + 0
                last[c] = m
            }
            close(bed)
        }
        /^>/ {
            hdr = substr($0, 2)
            name = hdr; sub(/[ \t].*$/, "", name); name = name ""
            if (name in first) { k = first[name]; kend = last[name] } else { k = 1; kend = 0 }
            pos = 0
            print $0
            next
        }
        {
            sub(/\r$/, "")
            L = $0; len = length(L)
            # drop intervals that end at or before this line
            while (k <= kend && E[k] <= pos) k++
            j = k
            while (j <= kend && S[j] < pos + len) {
                lo = (S[j] > pos ? S[j] : pos) - pos + 1        # 1-based in line
                hi = (E[j] < pos + len ? E[j] : pos + len) - pos
                if (hi >= lo)
                    L = substr(L, 1, lo - 1) tolower(substr(L, lo, hi - lo + 1)) substr(L, hi + 1)
                j++
            }
            print L
            pos += len
        }
    ' "$ASSEMBLY" > "$OUTPUT"
fi
[[ -s "$OUTPUT" ]] || { echo "ERROR: output was not created: $OUTPUT" >&2; exit 1; }

echo
echo "Verifying result"
# Cross-check the bases actually lowercased against the bases the merged BED
# says should have been. The two are computed independently; if masking silently
# went missing they will not agree, and a plausible-looking percentage alone
# would not reveal it.
awk -v expected="$masked_bp" '
    /^>/ { next }
    { sub(/\r$/, ""); total += length($0); gsub(/[^acgtn]/, "", $0); lower += length($0) }
    END {
        if (total == 0) { print "  ERROR: no sequence" > "/dev/stderr"; exit 1 }
        printf "  genome length  : %d bp\n", total
        printf "  soft-masked    : %d bp (%.2f%%)\n", lower, 100 * lower / total
        printf "  expected (BED) : %d bp\n", expected
        if (lower < expected * 0.999) {
            printf "  ERROR: %d bp fewer masked than the merged intervals require.\n", expected - lower > "/dev/stderr"
            print  "         Intervals were dropped or misapplied; not safe to use." > "/dev/stderr"
            exit 1
        }
        if (100 * lower / total < 20) {
            print "  ERROR: under 20% masked -- expected 40-48% for a rodent" > "/dev/stderr"
            exit 1
        }
    }
' "$OUTPUT"

echo
echo "Done: $OUTPUT"
echo "Compare against the individual rounds with:"
echo "  scripts/qc/verify_masking_chain.sh $RM_DIR"
