# Annotating the mitogenome (MITOS2)

Input file: `akodon_0339_mitogenome.rotated.fasta` (16,404 bp, circular,
rotated to begin at tRNA-Phe, the vertebrate convention).

Use the ROTATED file. Annotating the unrotated one puts the origin mid-gene,
which splits a feature across the sequence ends and is painful to fix later.

## Run it

Easiest is Galaxy EU, which has MITOS2 as a tool:

1. Go to https://usegalaxy.eu  (the EU server -- usegalaxy.org does NOT have MITOS2)
2. Upload `akodon_0339_mitogenome.rotated.fasta`
3. Search tools for "MITOS2"
4. Set:
     Reference data          : RefSeq89 Metazoa
     Genetic code            : 2 = Vertebrate Mitochondrial     <-- critical
     Leave everything else at default
5. Run. Takes a few minutes.

Alternative web server: http://mitos2.bioinf.uni-leipzig.de/index.py
(same settings; email-notified).

## Check the result before trusting it

A complete vertebrate mitogenome must have exactly **37 genes**:

    13  protein-coding (ND1 ND2 COX1 COX2 ATP8 ATP6 COX3 ND3 ND4L ND4 ND5 ND6 CYTB)
    22  tRNA
     2  rRNA (12S = rrnS, 16S = rrnL)

Count them in the returned GFF/BED. If any are missing, the usual causes are:
  - wrong genetic code (code 1 instead of 2) -> many PCGs truncated or absent
  - ND6 missing: it is on the minority strand; confirm it is reported as such
  - a duplicated tRNA: check it does not straddle the rotation origin

Note ATP8/ATP6 and ND4L/ND4 overlap in vertebrates -- that is correct, not an error.

## Then

Deposit as a SEPARATE GenBank record from the nuclear WGS -- a complete
mitochondrial genome is not part of the WGS set. The mito contig has already
been confirmed absent from `akodon_0339_genbank.fasta`, so nothing needs removing.

Submit via BankIt (easiest for a single annotated circular sequence) with:
  organism      : Akodon montensis
  location      : mitochondrion
  topology      : circular
  completeness  : complete
  genetic code  : 2
and the same BioSample as the nuclear genome (individual 0339).
