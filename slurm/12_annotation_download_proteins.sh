#!/usr/bin/env bash
# Stage 12: download reference protein datasets listed in the NCBI TSV.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="${1:-${CONFIG:-}}"

# shellcheck source=../scripts/lib/common.sh
source "$SCRIPT_DIR/../scripts/lib/common.sh"
source_config "$CONFIG_PATH"
ensure_base_dirs

ensure_dir "$NCBI_PROTEIN_ZIP_DIR"
download_count=0

if smoke_mode; then
    log "Smoke mode: creating mock downloaded protein dataset zip"
    output_zip="$NCBI_PROTEIN_ZIP_DIR/smoke_protein_dataset.zip"
    python3 - "$output_zip" <<'PY'
import sys, zipfile
out = sys.argv[1]
with zipfile.ZipFile(out, "w") as zf:
    zf.writestr("ncbi_dataset/data/GCF_smoke/protein.faa", ">smoke_protein\nMPEPTIDE\n")
PY
    [[ -f "$output_zip" ]] || die "Mock protein dataset zip was not created: $output_zip"
    exit 0
fi

datasets_bin="$(resolve_ncbi_datasets_bin)"
command -v "$datasets_bin" >/dev/null 2>&1 || die "datasets CLI not found: $datasets_bin"
[[ -f "$NCBI_DATASETS_TSV" ]] || die "NCBI datasets TSV not found: $NCBI_DATASETS_TSV"

while IFS=$'\t' read -r assembly_accession assembly_name _; do
    [[ -n "${assembly_accession:-}" ]] || continue
    safe_name="${assembly_name//[^A-Za-z0-9._-]/_}"
    output_zip="$NCBI_PROTEIN_ZIP_DIR/${safe_name}_protein_dataset.zip"

    if [[ -f "$output_zip" ]]; then
        log "Protein dataset already present, skipping download: $output_zip"
        continue
    fi

    log "Downloading protein FASTA for $assembly_name ($assembly_accession)"
    "$datasets_bin" download genome accession "$assembly_accession" --include protein --filename "$output_zip"
    ((download_count += 1))
done < <(tail -n +2 "$NCBI_DATASETS_TSV")

find "$NCBI_PROTEIN_ZIP_DIR" -maxdepth 1 -type f -name '*.zip' | grep -q . \
    || die "No protein dataset zip files were found in $NCBI_PROTEIN_ZIP_DIR"

log "Protein download stage completed with $download_count new downloads"
