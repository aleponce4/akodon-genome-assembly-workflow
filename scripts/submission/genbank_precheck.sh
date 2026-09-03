#!/usr/bin/env bash
# Audit an assembly against GenBank's hard WGS requirements before submission.
# Fully STREAMING: never holds a scaffold in memory. Accumulating each record
# into an awk string is O(n^2) and stalls on a 21.5 Mb scaffold.
FA="${1:?usage: genbank_precheck.sh <assembly.fasta>}"
echo "audit: $FA"; echo
awk '
    function finish() {
        if (name == "") return
        n++; total += L; ntotal += nn
        if (nn > 0) withN++
        if (L > maxlen) { maxlen = L; maxname = name }
        if (minlen == 0 || L < minlen) { minlen = L; minname = name }
        if (L < 200) short200++
        if (L > 2147483000) toolong++
        if (firstc ~ /[Nn]/) { leadN++;  if (leadex  == "") leadex  = name }
        if (lastc  ~ /[Nn]/) { trailN++; if (trailex == "") trailex = name }
        if (length(name) > 50) idlong++
        if (name ~ /[^A-Za-z0-9._|-]/) idodd++
        if (hasdesc) hdrdesc++
    }
    /^>/ {
        finish()
        hdr = substr($0,2); name = hdr; sub(/[ \t].*$/,"",name)
        hasdesc = (hdr ~ /[ \t]/)
        L = 0; nn = 0; firstc = ""; lastc = ""
        next
    }
    {
        sub(/\r$/,"")
        if (length($0) == 0) next
        if (firstc == "") firstc = substr($0,1,1)
        lastc = substr($0,length($0),1)
        L += length($0)
        t = $0; gsub(/[^Nn]/,"",t); nn += length(t)
    }
    END {
        finish()
        printf "sequences             : %d\n", n
        printf "total length          : %d bp (%.3f Gb)\n", total, total/1e9
        printf "longest               : %d bp  (%s)\n", maxlen, maxname
        printf "shortest              : %d bp  (%s)\n", minlen, minname
        printf "total N               : %d bp (%.2f%%)\n", ntotal, 100*ntotal/total
        printf "sequences containing N: %d\n", withN
        print ""
        print "GENBANK HARD REQUIREMENTS"
        printf "  sequences < 200 bp           : %-7d %s\n", short200+0, (short200>0?"MUST REMOVE":"OK")
        printf "  sequences > 2.147 Gbp        : %-7d %s\n", toolong+0,  (toolong>0? "MUST SPLIT":"OK")
        printf "  sequences BEGINNING with N   : %-7d %s\n", leadN+0,    (leadN>0?  "MUST TRIM  e.g. " leadex :"OK")
        printf "  sequences ENDING with N      : %-7d %s\n", trailN+0,   (trailN>0? "MUST TRIM  e.g. " trailex:"OK")
        print ""
        print "SEQUENCE IDs"
        printf "  ids > 50 chars               : %-7d %s\n", idlong+0, (idlong>0?"shorten":"OK")
        printf "  ids with unusual characters  : %-7d %s\n", idodd+0,  (idodd>0? "rename":"OK")
        printf "  headers carrying description : %-7d %s\n", hdrdesc+0,(hdrdesc>0?"(ok - table2asn uses the id only)":"none")
    }
' "$FA"
