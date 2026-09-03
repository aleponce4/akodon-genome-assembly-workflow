# TSEBRA configurations

`tsebra_config_1..3` are TSEBRA's own shipped configs, fetched at bootstrap:

| file | upstream |
|---|---|
| `tsebra_config_1` | `default.cfg` |
| `tsebra_config_2` | `braker3.cfg` |
| `tsebra_config_3` | `keep_ab_initio.cfg` |

`tsebra_config_4..6` are vendored here because they are not upstream files —
they were built to scan one parameter and the scan is part of the method.

## Why the scan

On *Akodon montensis* 0339, `default.cfg` and `keep_ab_initio.cfg` differed by
2,300 genes and 2.6 points of BUSCO completeness. They differ in five
parameters, so the cause was not obvious from the configs alone.

`tsebra_config_6` isolates it: `default.cfg`'s weights with **only**
`intron_support` changed to 0. It reproduced `keep_ab_initio.cfg` on every
metric and to within one gene, establishing that `intron_support` alone drives
the difference and the P/E/C hint weights are immaterial here.

`tsebra_config_4` and `_5` then sample the interior of the range.

## Results

BUSCO `glires_odb10`, protein mode, n=13,798. OMArk clade `Cricetidae`.
Assembly genome-mode BUSCO was 96.3%, the ceiling any annotation can reach.

| config | `intron_support` | genes | BUSCO C | HOG missing | consistent | unknown |
|---|---|---|---|---|---|---|
| 1 (`default`) | 1.0 | 22,956 | 93.3% | 5.02% | 86.07% | 10.17% |
| 5 | **0.5** | **24,195** | **95.9%** | 2.56% | **86.42%** | **9.85%** |
| 4 | 0.2 | 24,314 | 95.9% | 2.53% | 86.39% | 9.87% |
| 3 (`keep_ab_initio`) | 0.0 | 25,252 | 95.9% | 2.32% | 85.05% | 10.89% |
| 6 (control) | 0.0 | 25,253 | 95.9% | 2.32% | 85.05% | 10.89% |

For reference, the unmerged inputs: GALBA alone 94.7% BUSCO / 92.88% consistent,
BRAKER3 alone 87.2% / 87.11%.

## Why 0.5 is the default

**Completeness saturates at 0.5.** BUSCO is 95.9% at 0.5, 0.2 and 0.0 alike, so
relaxing below 0.5 buys no additional completeness. It does cost: ~1,000 more
genes, OMArk consistency down 1.4 points, "unknown" up 1.0 point, and higher
duplication. 0.5 is the knee of the curve.

`intron_support 1.0` requires EVERY intron in a transcript to be evidence-
supported or the transcript is discarded. RNA-seq does not cover every gene in
every tissue, so that setting discards real genes — which is why the merge at
1.0 scores *below* GALBA alone, an outcome that should not happen when merging
GALBA with BRAKER3.

## Caveat to carry into any writeup

OMArk's "unknown" category is defined as orphan genes **or** erroneous
predictions, and it cannot distinguish them. At 9.85% for config_5 versus 4.22%
for GALBA alone, some of that gap is genuinely lineage-specific *Akodon* genes
and some is likely noise. GALBA's low "unknown" is also partly circular: it
predicts genes *from* known proteomes via miniprot, so matching known families
is partly a property of the method.
