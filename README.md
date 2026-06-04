# Akodon Genome Assembly and Annotation Workflow

Slurm workflow for assembly, repeat annotation, structural annotation, and functional annotation of an *Akodon* genome. This repository reorganizes previously separate HPC job scripts into one reproducible workflow.


## Workflow

Assembly:

1. Supernova
2. `supernova mkoutput`
3. scaffold filtering with `seqkit`
4. QUAST
5. BUSCO
6. BUSCO plot
7. MultiQC
8. RepeatModeler
9. repeat library merge and CD-HIT filtering
10. RepeatMasker

Annotation:

0. preflight checks for line endings, tools, paths, FASTQs, and evidence files
11. simplify masked genome headers
12. download reference proteins from NCBI
13. prepare combined protein FASTA
14. GALBA
15. BRAKER2, available but off by default
16. BRAKER3
17. TSEBRA
18. longest-isoform filtering
19. restore original headers
20. InterProScan

Notes:

- stages `14`, `15`, and `16` are alternative prediction tracks
- the default annotation track is GALBA + BRAKER3 combined by TSEBRA
- annotation runs for all samples by default, with sample-specific output folders
- the annotation branch starts after RepeatMasker
- Supernova should use raw, untrimmed 10x linked-read FASTQs
- BRAKER3 BAMs must be aligned to the same simplified assembly headers used for that sample

## Main Tools

- Supernova
- `seqkit`
- QUAST
- BUSCO
- MultiQC
- RepeatModeler / RepeatMasker via `dfam/tetools`
- GALBA
- BRAKER2 / BRAKER3
- TSEBRA
- InterProScan

## Files

- [`config/pipeline.env`](config/pipeline.env): pipeline paths and Slurm settings
- [`config/bootstrap.env`](config/bootstrap.env): dependency bootstrap settings
- [`config/samples.tsv`](config/samples.tsv): sample metadata
- [`run_pipeline.sh`](run_pipeline.sh): full workflow submission
- [`run_smoke_test.sh`](run_smoke_test.sh): smoke test
- [`run_slurm_smoke_test.sh`](run_slurm_smoke_test.sh): real-SLURM toy submission
- [`slurm/`](slurm): numbered stage scripts
- [`scripts/check_pipeline_connections.sh`](scripts/check_pipeline_connections.sh): preflight path check
- [`scripts/hpc/bootstrap_dependencies.sh`](scripts/hpc/bootstrap_dependencies.sh): HPC bootstrap

## Inputs

- raw 10x FASTQs in `data/`
- sample table in `config/samples.tsv`
- BUSCO lineage data
- container images for RepeatModeler/RepeatMasker, BRAKER, GALBA, and InterProScan
- annotation inputs such as `ncbi_dataset.tsv`, protein FASTA, TSEBRA configs, and per-sample RNA BAMs for BRAKER3

Default BRAKER3 BAM layout:

```text
RNA_seq/bam_files/0337/*.bam
RNA_seq/bam_files/0338/*.bam
RNA_seq/bam_files/0339/*.bam
RNA_seq/bam_files/0340/*.bam
```

## Setup

Review:

- [`config/pipeline.env`](config/pipeline.env)
- [`config/bootstrap.env`](config/bootstrap.env)

Common settings:

- `DATA_DIR`
- `SUPERNOVA_BIN`
- `REPEATMODELER_IMAGE`
- `BUSCO_LINEAGE_DIR`
- `BRAKER_SIF`
- `GALBA_SIF`
- `INTERPROSCAN_SIF`
- `INTERPROSCAN_DATA_DIR`
- Slurm account, partition, QoS, memory, and walltime
- `ANNOTATION_SAMPLE_MODE=all`
- `BRAKER3_BAM_GLOB_TEMPLATE`
- `ENABLE_PREFLIGHT`

## Bootstrap

```bash
bash scripts/hpc/probe_node_capabilities.sh
bash scripts/hpc/bootstrap_dependencies.sh install config/bootstrap.env
bash scripts/hpc/bootstrap_dependencies.sh verify config/bootstrap.env
```

Use `install-light` on login nodes to skip large container and InterProScan
database downloads:

```bash
bash scripts/hpc/bootstrap_dependencies.sh install-light config/bootstrap.env
```

Automated by default:

- repo-local Conda environments
- BUSCO lineage download
- `tetools_latest.sif`
- InterProScan image and data
- `get_longest_isoform.py`
- default TSEBRA config files

Still manual by default:

- Supernova if the legacy path is unavailable
- BRAKER and GALBA SIFs unless source paths are provided
- biological inputs such as `Vertebrata.fa`, `ncbi_dataset.tsv`, and RNA BAMs

## Run

Preflight:

```bash
bash scripts/check_pipeline_connections.sh config/pipeline.env
bash scripts/hpc/bootstrap_dependencies.sh verify config/bootstrap.env
```

Submit:

```bash
bash run_pipeline.sh config/pipeline.env
```

Resume from a stage after fixing a failed run:

```bash
PIPELINE_START_STAGE=04 bash run_pipeline.sh config/pipeline.env
```

Each submission writes a manifest under `logs/slurm/submissions/`. Use:

```bash
bash scripts/summarize_slurm_run.sh logs/slurm/submissions/run_YYYYMMDD_HHMMSS_PID_jobs.tsv
bash scripts/cancel_submitted_run.sh logs/slurm/submissions/run_YYYYMMDD_HHMMSS_PID_jobs.tsv
```

Smoke test:

```bash
bash run_smoke_test.sh config/smoke_test.env
```

Real SLURM toy test:

```bash
bash run_slurm_smoke_test.sh config/slurm_toy.env
```

The local smoke test runs mock stages directly. The SLURM toy test submits the same dependency chain with tiny resources and writes under `slurm_toy/`.
