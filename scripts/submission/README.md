# GenBank submission preparation

Run in order. Each step is separate because each one found a real defect, and
keeping them separate makes it obvious which check caught what.

| # | script | what it fixes |
|---|---|---|
| 1 | `genbank_precheck.sh` | audit only — reports violations, changes nothing |
| 2 | `genbank_clean.sh` | terminal Ns, all-N scaffolds, length floor |
| 3 | `fix_restored_gtf.sh` | GTF seqids containing whitespace |
| 4 | `shift_coords.sh` | GTF coordinates after the FASTA trim |
| 5 | `to_gff3.sh` | GTF to GFF3 via AGAT (adds ID/Parent) |
| 6 | `normalize_gff.sh` | `transcript`→`mRNA`, drop `intron`, add CDS `product` |
| 7 | `dedup_gff.sh` | duplicate mRNA per gene |
| 8 | `final_gff.sh` | gene models too short to encode a protein |

Then validate with NCBI's own tool:

```bash
table2asn -M n -J -c w -euk -t template.sbt -gaps-min 10 -l paired-ends \
  -j "[organism=Akodon montensis][isolate=0339][gcode=1]" \
  -i assembly.fsa -f annotation.gff3 -locus-tag-prefix XXXX -Z -V b -o out.sqn
```

## Result on Akodon montensis 0339

Errors went 4 → 2, warnings 24,473 → 273. Both remaining errors are
`GENERIC.MissingPubRequirement`, i.e. the placeholder template lacking a
publication block. No substantive errors remain.

## Things that are easy to get wrong

**`product` must sit on the CDS, not the gene or mRNA.** table2asn copies the CDS
product *to* the mRNA and never the reverse. Putting it higher silently yields
"hypothetical protein" for everything — the usual cause of that complaint.

**Declare `[gcode=1]`.** Without it every CDS reports `GenCodeMismatch`: 24,200
warnings, one per gene, from a single missing token.

**Trimming terminal Ns renumbers the sequence.** Any annotation on a trimmed
scaffold must shift with it. Here one scaffold lost 100 leading N, moving 21-41
features per model. Skipping the shift produces a submission that validates
cleanly while describing the wrong bases — the worst available failure mode.

**A GTF seqname cannot contain whitespace.** The header-restore step wrote the
full FASTA header into column 1, so parsers truncated at the first space and the
value no longer matched the FASTA record id.

**Watch for duplicate mRNA.** The source GTF carried both `transcript` and `mRNA`
lines for 723 genes, which becomes two identical mRNA per gene after
normalisation. GenBank requires 1:1 gene:mRNA:CDS.

## Not covered here

- **FCS-GX** contamination screening needs 512 GB RAM — use Galaxy or a rented
  node. Adaptor screening against UniVec is cheap and was clean (59 internal
  loci, zero terminal hits), but says nothing about organism contamination.
- `template.sbt`, the locus-tag prefix, and the BioSample metadata come from
  registration and are not scripted here.
