#!/usr/bin/env bash
# Convert a MITOS2 BED annotation into an NCBI 5-column feature table (.tbl).
#
# BED is 0-based half-open; .tbl is 1-based inclusive, and minus-strand features
# are written with the coordinates reversed (end first). Both conversions are
# applied here -- getting either wrong silently shifts every feature by one base
# or flips gene orientation, neither of which table2asn will catch for you.
#
# MITOS2 does not emit the control region or the origin of light-strand
# replication; both are added from the gaps when --add-dloop is given.

set -euo pipefail
bed=""; seqlen=""; seqid=""; add_extra=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --bed)        bed="$2"; shift 2 ;;
        --seq-length) seqlen="$2"; shift 2 ;;
        --seqid)      seqid="$2"; shift 2 ;;
        --add-dloop)  add_extra=1; shift ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done
[[ -f "$bed" ]] || { echo "ERROR: --bed file not found: $bed" >&2; exit 1; }
[[ -n "$seqlen" ]] || { echo "ERROR: --seq-length is required" >&2; exit 1; }
[[ -n "$seqid" ]] || seqid="$(awk 'NR==1{print $1}' "$bed")"

awk -F'\t' -v seqid="$seqid" -v seqlen="$seqlen" -v extra="$add_extra" '
function pname(n,  b) {
    b = n; sub(/\(.*/, "", b)
    if (b=="nad1") return "NADH dehydrogenase subunit 1"
    if (b=="nad2") return "NADH dehydrogenase subunit 2"
    if (b=="nad3") return "NADH dehydrogenase subunit 3"
    if (b=="nad4") return "NADH dehydrogenase subunit 4"
    if (b=="nad4l") return "NADH dehydrogenase subunit 4L"
    if (b=="nad5") return "NADH dehydrogenase subunit 5"
    if (b=="nad6") return "NADH dehydrogenase subunit 6"
    if (b=="cox1") return "cytochrome c oxidase subunit I"
    if (b=="cox2") return "cytochrome c oxidase subunit II"
    if (b=="cox3") return "cytochrome c oxidase subunit III"
    if (b=="atp6") return "ATP synthase F0 subunit 6"
    if (b=="atp8") return "ATP synthase F0 subunit 8"
    if (b=="cob")  return "cytochrome b"
    if (b=="rrnS") return "12S ribosomal RNA"
    if (b=="rrnL") return "16S ribosomal RNA"
    return b
}
function gname(n,  b) {
    b = n; sub(/\(.*/, "", b)
    if (b=="cob") return "CYTB"
    if (b=="rrnS") return "rrnS"
    if (b=="rrnL") return "rrnL"
    if (b ~ /^trn/) return b
    return toupper(b)
}
# MITOS trn codes -> amino acid. L1/L2 and S1/S2 are the isoacceptors:
# L2(taa)=Leu(UUR), L1(tag)=Leu(CUN), S1(gct)=Ser(AGY), S2(tga)=Ser(UCN).
function aa(n,  b) {
    b = n; sub(/\(.*/, "", b); sub(/^trn/, "", b); sub(/[12]$/, "", b)
    if (b=="A") return "Ala"; if (b=="R") return "Arg"; if (b=="N") return "Asn"
    if (b=="D") return "Asp"; if (b=="C") return "Cys"; if (b=="Q") return "Gln"
    if (b=="E") return "Glu"; if (b=="G") return "Gly"; if (b=="H") return "His"
    if (b=="I") return "Ile"; if (b=="L") return "Leu"; if (b=="K") return "Lys"
    if (b=="M") return "Met"; if (b=="F") return "Phe"; if (b=="P") return "Pro"
    if (b=="S") return "Ser"; if (b=="T") return "Thr"; if (b=="W") return "Trp"
    if (b=="Y") return "Tyr"; if (b=="V") return "Val"
    return b
}
function anticodon(n,  a) { a=n; if (a !~ /\(/) return ""; sub(/.*\(/,"",a); sub(/\).*/,"",a); return toupper(a) }
function emit(s,e,strand,key,  a,b) { if (strand=="-") { a=e; b=s } else { a=s; b=e }
    printf "%d\t%d\t%s\n", a, b, key }
BEGIN { printf ">Feature %s\n", seqid }
{
    s = $2 + 1; e = $3; nm = $4; st = $6
    base = nm; sub(/\(.*/, "", base)
    if (base ~ /^trn/)      type = "tRNA"
    else if (base ~ /^rrn/) type = "rRNA"
    else                    type = "CDS"

    emit(s, e, strand=st, "gene")
    printf "\t\t\tgene\t%s\n", gname(nm)
    emit(s, e, st, type)
    if (type == "CDS") {
        printf "\t\t\tproduct\t%s\n", pname(nm)
        printf "\t\t\ttransl_table\t2\n"
    } else if (type == "tRNA") {
        printf "\t\t\tproduct\ttRNA-%s\n", aa(nm)
        ac = anticodon(nm); if (ac != "") printf "\t\t\tnote\tanticodon:%s\n", ac
    } else {
        printf "\t\t\tproduct\t%s\n", pname(nm)
    }
    if (e > maxend) maxend = e
    # remember the gap between trnN and trnC for the OL
    if (base=="trnN") nend = e
    if (base=="trnC") cstart = s
}
END {
    if (extra) {
        if (nend > 0 && cstart > nend + 1) {
            printf "%d\t%d\trep_origin\n", nend + 1, cstart - 1
            printf "\t\t\tnote\torigin of light strand replication\n"
        }
        if (seqlen > maxend) {
            printf "%d\t%d\tD-loop\n", maxend + 1, seqlen
            printf "\t\t\tnote\tcontrol region\n"
        }
    }
}' "$bed"
