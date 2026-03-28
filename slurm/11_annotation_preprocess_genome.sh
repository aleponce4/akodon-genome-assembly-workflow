#!/usr/bin/env bash
# Stage 11: simplify the final masked genome headers for annotation tools.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="${1:-${CONFIG:-}}"

# shellcheck source=../scripts/lib/common.sh
source "$SCRIPT_DIR/../scripts/lib/common.sh"
source_config "$CONFIG_PATH"
ensure_base_dirs

sample_id="$ANNOTATION_SAMPLE_ID"
input_fasta="$(annotation_masked_genome "$sample_id")"
output_fasta="$(annotation_simplified_genome "$sample_id")"
header_map="$(annotation_header_map "$sample_id")"
name_stem="$ANNOTATION_HEADER_NAME_STEM"

if smoke_mode; then
    log "Smoke mode: creating mock simplified annotation genome and header map"
    write_smoke_fasta "$output_fasta" "${name_stem}1" "ATGCGTATGCGTATGCGTATGCGTATGCGT"
    cat > "$header_map" <<EOF
>${name_stem}1	>original_smoke_contig|1
EOF
    [[ -s "$output_fasta" ]] || die "Simplified annotation genome was not created: $output_fasta"
    [[ -s "$header_map" ]] || die "Annotation genome header map was not created: $header_map"
    exit 0
fi

command -v perl >/dev/null 2>&1 || load_module_if_available "$PERL_MODULE"
command -v perl >/dev/null 2>&1 || die "perl is required for genome preprocessing."

[[ -f "$GENOME_HEADER_SIMPLIFIER" ]] || die "Header simplifier script not found: $GENOME_HEADER_SIMPLIFIER"
[[ -f "$input_fasta" ]] || die "RepeatMasker final masked genome not found: $input_fasta"

log "Simplifying masked genome headers for annotation sample $sample_id"
perl "$GENOME_HEADER_SIMPLIFIER" "$input_fasta" "$name_stem" "$output_fasta" "$header_map"

[[ -s "$output_fasta" ]] || die "Simplified annotation genome was not created: $output_fasta"
[[ -s "$header_map" ]] || die "Annotation genome header map was not created: $header_map"
