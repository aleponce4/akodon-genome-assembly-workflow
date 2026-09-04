# Submission package — *Akodon montensis* 0339

Everything here was produced locally from HPC pipeline output. Regenerate any of
it with `scripts/submission/` in the workflow repo (github.com/aleponce4/akodon-genome-assembly-workflow).

## Files

| file | description |
|---|---|
| `akodon_0339_genbank.fasta` | assembly, GenBank-legal. 4,977 seq, 2,291,029,792 bp |
| `akodon_0339_genbank.trim_report.tsv` | what the cleaning step changed |
| `gff3/tsebra_config_5.genbank.final.gff3` | **the annotation to submit**. 24,178 genes |
| `gff3/*.agat.gff3`, `*.genbank.gff3`, `*.dedup.gff3` | intermediates, kept for audit |
| `gtf_fixed/`, `gtf_ready/` | all 8 candidate models, seqid- and coordinate-corrected |
| `mitogenome/akodon_0339_mitogenome.rotated.fasta` | **submit this one** — rotated to tRNA-Phe |
| `mitogenome/akodon_0339_mitogenome.fasta` | as assembled, arbitrary start |
| `vecscreen_hits.tsv` | raw UniVec BLAST output |

## Assembly

Library 0339 of four, chosen on input DNA quality (25.5 kb mean molecule length,
P10 32.3 — roughly double the other three) and every contiguity metric.

Authoritative values, from `gfastats` on the submission file itself
(`assembly_statistics.txt`). These differ slightly from the pipeline's QUAST
report because cleaning removed 2 scaffolds and 100 bp.

| | |
|---|---|
| Scaffolds | 4,977 |
| Total length | 2,291,029,792 bp |
| Scaffold N50 | 4,776,966 bp (4.78 Mb) |
| Largest scaffold | 21,529,063 bp |
| Scaffold L50 | 144 |
| **Contigs** | **67,615** |
| **Contig N50** | **61,415 bp (61.4 kb)** |
| Largest contig | 590,219 bp |
| Gaps | 62,638, totalling 27,120,430 bp (1.18%) |
| GC | 40.26% |
| BUSCO genome (`glires_odb10`) | 96.3% complete |
| Repeat content | 43.67% |

Report contig N50 alongside scaffold N50. The multi-megabase scaffold N50 comes
from gap-spanning, not contiguous sequence, and a reviewer will ask.

Supernova estimated the genome at 2.81 Gb against 2.29 Gb assembled, so roughly
**19% is unassembled** — mostly repeats. State this rather than reporting
assembled size as a biological result.

## Cleaning applied

- 2 scaffolds (`1377`, `1380`) removed: entirely N. Neither carried an
  annotation in any of the 8 candidate models.
- 1 scaffold (`678`) lost 100 bp of leading N. **All annotation coordinates on it
  were shifted by −100.** Without that shift the submission would validate
  cleanly while describing the wrong bases.
- No sequence is under 200 bp (the 10 kb assembly filter already exceeds this).

## Annotation

`tsebra_config_5` — TSEBRA merging GALBA and BRAKER3 with `intron_support 0.5`,
selected by scanning that parameter. See `config/tsebra/README.md` in the repo.

| | |
|---|---|
| Genes | 24,178 |
| gene : mRNA : CDS | 1 : 1 : 1 |
| BUSCO protein (`glires_odb10`) | 95.9% complete, 1.3% duplicated |
| OMArk consistency | 86.42%, 0% contamination |
| OMArk clade | Cricetidae (correct family, independently inferred) |
| Internal stop codons | **0** |

22 models encoding 3-8 residue proteins were removed (0.09%).

### Structure (AGAT v1.7.0, `annotation_statistics.txt`)

| | this assembly | mouse GRCm39 | rat mRatBN7.2 | *Peromyscus* |
|---|---|---|---|---|
| Protein-coding genes | 24,178 | 22,198 | 21,990 | 22,575 |
| mean exons / mRNA | **8.1** | 11.61 | 11.53 | 12.07 |
| mean CDS length | **1,434 bp** | 2,051 | 2,123 | 2,080 |
| mean gene length | **28,211 bp** | 33,075 | 35,062 | 41,350 |
| single-exon genes | **5,185 (21.4%)** | ~5-6% | - | - |
| mRNA per gene | 1.0 | | | |
| CDS per mRNA | 1.0 | | | |
| overlapping genes | 363 | | | |
| total CDS | 34,660,453 bp | | | |

Every structural metric sits ~25-30% below the mammalian references, and in the
same direction: shorter genes, shorter CDS, fewer exons, four times the
mono-exonic fraction. **That consistency is the point** -- it is one cause, the
assembly, not an annotation defect. With contig N50 at 61 kb against a mean
mammalian gene span of 33-41 kb, a large share of genes straddle a gap and are
truncated into shorter, fewer-exon models. Mono-exonic fraction stays below the
~25% level usually treated as a red flag.

UTRs are near-absent (207 five-prime, 95 three-prime). BRAKER/GALBA do not model
UTRs reliably; this is expected and not a defect.

Protein lengths are shorter than mouse (mean 471 vs ~683 aa) and mono-exonic
fraction is higher (20.7% vs 5–6%). **This is the assembly showing through, not
an annotation failure** — with contig N50 at 61 kb and mean rodent gene span
30–41 kb, many genes straddle a gap and get truncated. Say so explicitly.

## Validation

`table2asn` 1.29.324, NCBI's own validator:

```
errors   4 -> 2      (both remaining = placeholder template lacking a publication)
warnings 24,473 -> 273
```

No substantive errors. Warnings are 150 short exons, 93 non-consensus splice
sites, 10 suspicious frames, 4 overlapping genes — all expected for a draft.

## Species identity

*Akodon montensis*, confirmed from library 0339's own reads: mitogenome
assembled de novo, cytb extracted, ranked against 845 GenBank sequences spanning
45 *Akodon* species.

- *A. montensis* **99.88%** (105 panel sequences)
- *A. reigi* 94.42%
- *A. cursor* **91.51%** (397 panel sequences)

*A. cursor* is the meaningful comparison — sister species, sympatric,
morphologically confusable, separated mainly by karyotype — and it is the
best-represented species in the panel, so its distance is well estimated.

Done from reads, not the assembly, deliberately: the nuclear assembly carries
NUMTs at 83–96% identity to the mitogenome, and a cytb pulled from one of those
could have mis-called the species.

## Mitogenome

16,404 bp, complete and circular. Aligns to *A. montensis* NC_025746.1 across
its full length at 97.59%. Rotated to begin at tRNA-Phe (`GTTAATGTAGCTTATAAT…`),
the mammalian deposition convention.

Still needs MITOS2 annotation (genetic code 2, Vertebrate Mitochondrial) and is
submitted as a separate record cross-referenced to the WGS BioProject.

## Screening

**Adaptor — clean.** UniVec with VecScreen parameters: 688,696 raw BLAST hits
collapse to 59 distinct loci, **zero terminal**. Real adaptor read-through lands
at sequence ends; internal matches to many UniVec entries at one locus are a
shared motif, not contamination.

**Organism contamination — NOT DONE.** FCS-GX needs 512 GB RAM. Run it on Galaxy
(`ncbi_fcs_gx`, taxid 10069) or a rented node before submitting. NCBI runs FCS
on every submission, so skipping this converts a clean pass into a correction
round-trip.

## Outstanding

1. **FCS-GX** — external machine
2. **`template.sbt`** — authors, contact, publication status. Clears the last 2 errors
3. **BioProject → BioSample → locus-tag prefix**, replacing the `AKMON` placeholder
4. **Metadata** — see `TODO_metadata.md`. `geo_loc_name` and `collection_date` are
   mandatory on all new INSDC records since December 2024
5. **MITOS2** on the rotated mitogenome

Submission order: BioProject/BioSample → **SRA reads** → unannotated assembly to
lock in a `GCA_` → add annotation. Do not let annotation gate the accession.
