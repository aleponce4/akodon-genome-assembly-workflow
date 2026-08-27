#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_PATH="${1:-$REPO_ROOT/config/smoke_test.env}"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
source_config "$CONFIG_PATH"

log "Running smoke test output contract verification..."

assert_nonempty_file() {
    local file_path="$1"
    local description="$2"
    if [[ ! -f "$file_path" ]]; then
        die "Verification failed: $description missing at $file_path"
    fi
    if [[ ! -s "$file_path" ]]; then
        die "Verification failed: $description is empty at $file_path"
    fi
    log "OK: $description verified ($file_path)"
}

assert_file_contains() {
    local file_path="$1"
    local pattern="$2"
    local description="$3"
    assert_nonempty_file "$file_path" "$description"
    if ! grep -q "$pattern" "$file_path"; then
        die "Verification failed: $description does not contain expected pattern '$pattern'"
    fi
    log "OK: $description contains '$pattern'"
}

assert_restored_headers_match_map() {
    local simplified_fasta="$1"
    local header_map="$2"
    local restored_fasta="$3"
    local description="$4"

    assert_nonempty_file "$simplified_fasta" "$description simplified genome"
    assert_nonempty_file "$header_map" "$description header map"
    assert_nonempty_file "$restored_fasta" "$description restored genome"

    local problem
    problem="$(awk -F '\t' '
        NR == FNR {
            simple = $1
            original = $2
            sub(/^>/, "", simple)
            sub(/^>/, "", original)
            sub(/[ \t\r]+$/, "", original)
            mapping[simple] = original
            next
        }
        FNR == 1 { file_index++ }
        /^>/ {
            header = substr($0, 2)
            sub(/[ \t\r]+$/, "", header)
            if (file_index == 1) {
                simplified_count++
                if (!(header in mapping)) {
                    print "simplified header missing from map: " header
                    exit 1
                }
                expected[simplified_count] = mapping[header]
            } else {
                restored_count++
                if (restored_count > simplified_count) {
                    print "restored genome has more headers than the simplified genome"
                    exit 1
                }
                if (header != expected[restored_count]) {
                    print "restored header " restored_count " is \"" header "\" but the map says \"" expected[restored_count] "\""
                    exit 1
                }
            }
        }
        END {
            if (simplified_count == 0) {
                print "simplified genome contains no FASTA headers"
                exit 1
            }
            if (restored_count != simplified_count) {
                print "restored genome has " restored_count " headers but the simplified genome has " simplified_count
                exit 1
            }
        }
    ' "$header_map" "$simplified_fasta" "$restored_fasta")" || {
        die "Verification failed: $description header integrity check: ${problem:-unknown mismatch}"
    }

    log "OK: $description restored headers match the header map"
}

sample_total="$(sample_count)"
log "Verifying outputs for $sample_total samples..."

# 1. Pseudohap & Filtered FASTAs
for ((idx = 0; idx < sample_total; idx++)); do
    sample_id="$(sample_id_by_index "$idx")"
    assert_nonempty_file "$(canonical_pseudohap "$sample_id")" "Pseudohap assembly for sample $sample_id"
    assert_nonempty_file "$(filtered_fasta "$sample_id")" "Filtered FASTA for sample $sample_id"
done

# 2. QUAST & BUSCO reports
assert_nonempty_file "$(quast_report_tsv)" "QUAST report TSV"
for ((idx = 0; idx < sample_total; idx++)); do
    sample_id="$(sample_id_by_index "$idx")"
    busco_summary_file="$(find "$(busco_sample_dir "$sample_id")" -name "short_summary*.txt" | head -n 1)"
    assert_nonempty_file "$busco_summary_file" "BUSCO summary for sample $sample_id"
done

# 3. MultiQC outputs
assert_nonempty_file "$MULTIQC_DIR/multiqc_report.html" "MultiQC HTML report"
assert_nonempty_file "$MULTIQC_DIR/qc_summary.tsv" "MultiQC summary TSV"
for ((idx = 0; idx < sample_total; idx++)); do
    sample_id="$(sample_id_by_index "$idx")"
    assert_file_contains "$MULTIQC_DIR/qc_summary.tsv" "$sample_id" "MultiQC summary entry for sample $sample_id"
done

# 4. Repeat modeler & masker outputs
assert_nonempty_file "$REPEAT_LIBRARY_DIR/non_redundant_repeats.fa" "Merged non-redundant repeat library"
for ((idx = 0; idx < sample_total; idx++)); do
    sample_id="$(sample_id_by_index "$idx")"
    assert_nonempty_file "$(repeatmasker_final_masked "$sample_id")" "RepeatMasker output for sample $sample_id"
done

# 5. Annotation simplified genome and header maps
for ((idx = 0; idx < sample_total; idx++)); do
    sample_id="$(sample_id_by_index "$idx")"
    assert_nonempty_file "$(annotation_simplified_genome "$sample_id")" "Simplified genome for sample $sample_id"
    assert_nonempty_file "$(annotation_header_map "$sample_id")" "Header map for sample $sample_id"
done

# 6. Annotation GTF and Restored Headers, including header integrity:
#    every contig header in the restored genome must be the original header the
#    stage 11 map recorded for the matching simplified header, in the same order
#    and with the same count.
for ((idx = 0; idx < sample_total; idx++)); do
    sample_id="$(sample_id_by_index "$idx")"
    assert_nonempty_file "$(annotation_restored_genome "$sample_id")" "Restored genome headers for sample $sample_id"
    assert_restored_headers_match_map \
        "$(annotation_simplified_genome "$sample_id")" \
        "$(annotation_header_map "$sample_id")" \
        "$(annotation_restored_genome "$sample_id")" \
        "Sample $sample_id"
done

# 7. TSEBRA deliverables reach stages 19 and 20.
#    Regression guard: stage 18 publishes its results through a `tsebra_current`
#    symlink, and a plain `find` does not descend into a symlinked start point.
#    That silently dropped every TSEBRA model -- the final annotation -- from the
#    isoform filter and the header restore while both stages still exited 0.
#    These assertions fail if that regresses.
if truthy "${ENABLE_TSEBRA:-0}"; then
    for ((idx = 0; idx < sample_total; idx++)); do
        sample_id="$(sample_id_by_index "$idx")"
        restore_dir="$(annotation_original_headers_dir "$sample_id")"

        tsebra_found="$(find -L "$(annotation_tsebra_current_dir "$sample_id")" \
            -type f -name 'tsebra_*.gtf' 2>/dev/null | wc -l)"
        (( tsebra_found > 0 )) \
            || die "No TSEBRA GTF found under $(annotation_tsebra_current_dir "$sample_id") for sample $sample_id"
        log "OK: $tsebra_found TSEBRA GTF(s) discoverable for sample $sample_id"

        tsebra_restored="$(find -L "$restore_dir" -maxdepth 1 -type f \
            -name 'tsebra_*_original_headers.gtf' 2>/dev/null | wc -l)"
        (( tsebra_restored > 0 )) \
            || die "Stage 20 restored no TSEBRA GTF for sample $sample_id (expected tsebra_*_original_headers.gtf in $restore_dir)"
        log "OK: $tsebra_restored TSEBRA GTF(s) restored to original headers for sample $sample_id"
    done
fi

log "All smoke test output contracts verified successfully."
