#!/usr/bin/env bash
# Stage 19: restore original contig headers in annotation deliverables.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="${1:-${CONFIG:-}}"

# shellcheck source=../scripts/lib/common.sh
source "$SCRIPT_DIR/../scripts/lib/common.sh"
source_config "$CONFIG_PATH"
ensure_base_dirs

sample_id="$ANNOTATION_SAMPLE_ID"
header_map="$(annotation_header_map "$sample_id")"
input_genome="$(annotation_simplified_genome "$sample_id")"
output_genome="$(annotation_restored_genome "$sample_id")"
manifest_file="$ANNOTATION_ORIGINAL_HEADERS_DIR/restored_files.tsv"

[[ -f "$header_map" ]] || die "Annotation header map not found: $header_map"
[[ -f "$input_genome" ]] || die "Simplified annotation genome not found: $input_genome"

awk -F '\t' '
    NR == FNR {
        from = $1
        to = $2
        sub(/^>/, "", from)
        sub(/^>/, "", to)
        mapping[from] = to
        next
    }
    /^>/ {
        header = substr($0, 2)
        if (header in mapping) {
            print ">" mapping[header]
        } else {
            print
        }
        next
    }
    { print }
' "$header_map" "$input_genome" > "$output_genome"
[[ -s "$output_genome" ]] || die "Genome with restored headers was not created: $output_genome"

printf 'label\tinput\toutput\n' > "$manifest_file"
printf 'genome\t%s\t%s\n' "$input_genome" "$output_genome" >> "$manifest_file"

restore_gtf() {
    local label="$1"
    local input_gtf="$2"
    local output_gtf="$ANNOTATION_ORIGINAL_HEADERS_DIR/${label}_original_headers.gtf"

    [[ -f "$input_gtf" ]] || return 0
    awk -F '\t' -v OFS='\t' '
        NR == FNR {
            from = $1
            to = $2
            sub(/^>/, "", from)
            sub(/^>/, "", to)
            mapping[from] = to
            next
        }
        {
            if ($1 in mapping) {
                $1 = mapping[$1]
            }
            print
        }
    ' "$header_map" "$input_gtf" > "$output_gtf"
    [[ -s "$output_gtf" ]] || die "Restored GTF was not created: $output_gtf"
    printf '%s\t%s\t%s\n' "$label" "$input_gtf" "$output_gtf" >> "$manifest_file"
}

for predictor in galba braker2 braker3; do
    restore_gtf "$predictor" "$(annotation_predictor_gtf "$predictor")"
done

if [[ -d "$(annotation_tsebra_current_dir)" ]]; then
    while IFS= read -r gtf_path; do
        config_name="$(basename "$(dirname "$gtf_path")")"
        restore_gtf "$config_name" "$gtf_path"
    done < <(find "$(annotation_tsebra_current_dir)" -type f -name 'tsebra_*.gtf' | sort)
fi

if [[ -d "$(annotation_isoform_root)" ]]; then
    while IFS= read -r gtf_path; do
        model_name="$(basename "$(dirname "$gtf_path")")"
        restore_gtf "${model_name}_longest_isoform" "$gtf_path"
    done < <(find "$(annotation_isoform_root)" -type f -name '*_longest_isoform.gtf' | sort)
fi
