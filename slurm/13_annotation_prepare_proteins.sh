#!/usr/bin/env bash
# Stage 13: unzip, merge, and simplify reference protein FASTA files.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="${1:-${CONFIG:-}}"

# shellcheck source=../scripts/lib/common.sh
source "$SCRIPT_DIR/../scripts/lib/common.sh"
source_config "$CONFIG_PATH"
ensure_base_dirs

if smoke_mode; then
    log "Smoke mode: creating mock simplified protein FASTA and header map"
    write_smoke_fasta "$SIMPLIFIED_PROTEIN_FASTA" "galba_protein_simplified_1" "MPEPTIDESEQ"
    cat > "$SIMPLIFIED_PROTEIN_HEADER_MAP" <<EOF
>galba_protein_simplified_1	>original_smoke_protein|1
EOF
    [[ -s "$SIMPLIFIED_PROTEIN_FASTA" ]] || die "Simplified protein FASTA was not created: $SIMPLIFIED_PROTEIN_FASTA"
    [[ -s "$SIMPLIFIED_PROTEIN_HEADER_MAP" ]] || die "Protein header map was not created: $SIMPLIFIED_PROTEIN_HEADER_MAP"
    exit 0
fi

command -v perl >/dev/null 2>&1 || load_module_if_available "$PERL_MODULE"
command -v perl >/dev/null 2>&1 || die "perl is required for protein preprocessing."
command -v unzip >/dev/null 2>&1 || die "unzip is required for protein preprocessing."

[[ -f "$GENOME_HEADER_SIMPLIFIER" ]] || die "Header simplifier script not found: $GENOME_HEADER_SIMPLIFIER"
find "$NCBI_PROTEIN_ZIP_DIR" -maxdepth 1 -type f -name '*.zip' | grep -q . \
    || die "No protein dataset zip files were found in $NCBI_PROTEIN_ZIP_DIR"

ensure_dir "$NCBI_PROTEIN_TEMP_DIR"
temp_dir="$(mktemp -d "$NCBI_PROTEIN_TEMP_DIR/run.XXXXXX")"
combined_fasta="$ANNOTATION_INPUT_DIR/combined_protein_set.fasta"

cleanup() {
    rm -rf "$temp_dir"
    rm -f "$combined_fasta"
}
trap cleanup EXIT

for zip_file in "$NCBI_PROTEIN_ZIP_DIR"/*.zip; do
    log "Unzipping protein dataset: $zip_file"
    unzip -o "$zip_file" -d "$temp_dir" >/dev/null
done

mapfile -t protein_fastas < <(find "$temp_dir" -type f -name 'protein.faa' | sort)
(( ${#protein_fastas[@]} > 0 )) || die "No protein.faa files were found after unzipping protein datasets."

cat "${protein_fastas[@]}" > "$combined_fasta"

log "Simplifying combined protein FASTA headers"
perl "$GENOME_HEADER_SIMPLIFIER" \
    "$combined_fasta" \
    "galba_protein_simplified" \
    "$SIMPLIFIED_PROTEIN_FASTA" \
    "$SIMPLIFIED_PROTEIN_HEADER_MAP"

[[ -s "$SIMPLIFIED_PROTEIN_FASTA" ]] || die "Simplified protein FASTA was not created: $SIMPLIFIED_PROTEIN_FASTA"
[[ -s "$SIMPLIFIED_PROTEIN_HEADER_MAP" ]] || die "Protein header map was not created: $SIMPLIFIED_PROTEIN_HEADER_MAP"
