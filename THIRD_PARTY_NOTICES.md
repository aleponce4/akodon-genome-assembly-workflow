# Third-Party Notices

This repository vendors a small number of files that were **not** written for
this project. The repository-level [`LICENSE`](LICENSE) (MIT) covers only the
workflow code authored here; it does not cover, and cannot relicense, the
third-party files listed below. Each remains under its own upstream license and
copyright.

If you redistribute this repository, keep this file with it and check the
upstream projects for the authoritative license text before relying on any of
the terms summarized here.

## `job_scripts/bin/simplifyFastaHeaders.pl`

| | |
| :--- | :--- |
| Upstream project | AUGUSTUS (<https://github.com/Gaius-Augustus/Augustus>) |
| Author | Katharina J. Hoff (header comment dated Dec 3rd 2012) |
| Upstream license | Artistic License 1.0, per the `LICENSE` file in the AUGUSTUS repository |
| Vendored copy | unmodified except for an added attribution comment pointing here |

The script rewrites FASTA headers to short, tool-safe names and writes a
`header.map` file with the new and old headers, which is exactly what stages 11
and 13 of this workflow need before running GALBA/BRAKER. It ships inside the
AUGUSTUS distribution and is also bundled in the BRAKER and GALBA containers
this workflow uses; it is vendored here so the annotation stages do not depend
on reaching into a container filesystem for a helper script.

No changes were made to its behavior. Bug reports and improvements belong
upstream, not here.

## Helper scripts fetched at bootstrap time (not vendored)

These are downloaded by `scripts/hpc/bootstrap_dependencies.sh` rather than
committed, so they carry no copy in this repository, but they are third-party
code at runtime and are listed here for completeness:

- `get_longest_isoform.py` and the default TSEBRA configuration files, from
  TSEBRA (<https://github.com/Gaius-Augustus/TSEBRA>).
- Container images for RepeatModeler/RepeatMasker (`dfam/tetools`), BRAKER,
  GALBA, and InterProScan, each under its own upstream license.
- Dfam FamDB partitions used by the RepeatMasker Dfam rounds
  (<https://www.dfam.org>), under the Dfam license/terms of use.
