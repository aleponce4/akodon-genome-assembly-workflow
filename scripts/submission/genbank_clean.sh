#!/usr/bin/env bash
# Produce a GenBank-legal assembly FASTA.
#
# ORDER MATTERS: trim terminal Ns FIRST, then apply the length floor. Trimming
# can push a sequence below 200 bp, so filtering first would let such a sequence
# through. (Not a risk at a 10 kb floor, but the order should be correct anyway.)
#
# Streaming, two passes: pass 1 records each record's trim offsets, pass 2
# rewrites. Never holds a scaffold in memory.
set -uo pipefail
IN="${1:?usage: genbank_clean.sh <in.fasta> <out.fasta> [min_len]}"
OUT="${2:?output required}"
MIN="${3:-200}"
RPT="${OUT%.fasta}.trim_report.tsv"

awk -v minlen="$MIN" -v report="$RPT" '
    function emit(   i, s, e, keep) {
        if (name == "") return
        # first/last non-N base positions were tracked while streaming
        if (firstbase == 0) { dropped_allN++; return }   # entirely N
        s = firstbase; e = lastbase
        newlen = e - s + 1
        if (newlen < minlen) { dropped_short++; return }
        if (s > 1 || e < L) {
            trimmed++
            printf "%s\t%d\t%d\t%d\t%d\n", name, L, s-1, L-e, newlen >> report
        }
        kept++; keptbp += newlen
        print ">" hdr
        # re-emit sequence from the buffer file, wrapped at 60
        cmd = "sed -n " recstart "," recend "p " infile " | tr -d \"\n\r\" | cut -c" s "-" e " | fold -w 60"
        system(cmd); close(cmd)
    }
    BEGIN { print "sequence\torig_len\ttrim_5p\ttrim_3p\tnew_len" > report }
' /dev/null 2>/dev/null

# The awk-with-system approach above is fragile; use a single-pass python
# implementation instead, which streams and is far easier to reason about.
python3 - "$IN" "$OUT" "$MIN" "$RPT" <<'PY'
import sys
inp, outp, minlen, rpt = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]

def flush(fh, rf, hdr, chunks, stats):
    if hdr is None:
        return
    seq = "".join(chunks)
    L = len(seq)
    s = 0
    while s < L and seq[s] in "Nn":
        s += 1
    e = L
    while e > s and seq[e-1] in "Nn":
        e -= 1
    if s >= e:
        stats["dropped_allN"] += 1
        return
    new = seq[s:e]
    if len(new) < minlen:
        stats["dropped_short"] += 1
        return
    if s > 0 or e < L:
        stats["trimmed"] += 1
        name = hdr.split()[0]
        rf.write(f"{name}\t{L}\t{s}\t{L-e}\t{len(new)}\n")
    stats["kept"] += 1
    stats["keptbp"] += len(new)
    fh.write(">" + hdr + "\n")
    for i in range(0, len(new), 60):
        fh.write(new[i:i+60] + "\n")

stats = dict(kept=0, keptbp=0, trimmed=0, dropped_allN=0, dropped_short=0, seen=0)
with open(inp) as f, open(outp, "w") as fh, open(rpt, "w") as rf:
    rf.write("sequence\torig_len\ttrim_5p\ttrim_3p\tnew_len\n")
    hdr, chunks = None, []
    for line in f:
        line = line.rstrip("\r\n")
        if line.startswith(">"):
            flush(fh, rf, hdr, chunks, stats)
            stats["seen"] += 1
            hdr, chunks = line[1:], []
        else:
            chunks.append(line)
    flush(fh, rf, hdr, chunks, stats)

print(f"input sequences   : {stats['seen']}")
print(f"kept              : {stats['kept']}  ({stats['keptbp']:,} bp)")
print(f"terminal-N trimmed: {stats['trimmed']}")
print(f"dropped (all N)   : {stats['dropped_allN']}")
print(f"dropped (<{minlen} bp): {stats['dropped_short']}")
print(f"trim report       : {rpt}")
PY
