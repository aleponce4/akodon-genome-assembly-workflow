#!/usr/bin/env bash
# Stage 07: aggregate QUAST and BUSCO outputs with MultiQC.

set -euo pipefail

CONFIG_PATH="${1:-${CONFIG:-}}"
[[ -n "$CONFIG_PATH" ]] || { echo "ERROR: config path is required" >&2; exit 1; }
CONFIG_DIR="$(cd "$(dirname "$CONFIG_PATH")" && pwd)"
PIPELINE_ROOT="$(cd "$CONFIG_DIR/.." && pwd)"

# shellcheck source=scripts/lib/common.sh
source "$PIPELINE_ROOT/scripts/lib/common.sh"
source_config "$CONFIG_PATH"
ensure_base_dirs

write_qc_summary() {
    local output_file="$MULTIQC_DIR/qc_summary.tsv"
    local sample_total
    local idx
    local sample_id
    local assembly
    local quast_label
    local busco_line
    local total_length
    local contigs
    local n50

    quast_metric() {
        local metric="$1"
        local label="$2"
        local report
        report="$(quast_report_tsv)"

        [[ -s "$report" ]] || return 0
        awk -F '\t' -v metric="$metric" -v label="$label" '
            NR == 1 {
                for (i = 1; i <= NF; i++) {
                    header[$i] = i
                    if ($i == label) {
                        label_col = i
                    }
                }
            }
            NR > 1 && $1 == label && header[metric] {
                print $header[metric]
                exit
            }
            NR > 1 && $1 == metric && label_col {
                print $label_col
                exit
            }
        ' "$report"
    }

    printf 'sample_id\tassembly\tquast_total_length\tquast_contigs\tquast_n50\tbusco_summary\n' > "$output_file"

    sample_total="$(sample_count)"
    for ((idx = 0; idx < sample_total; idx++)); do
        sample_id="$(sample_id_by_index "$idx")"
        assembly="$(assembly_stem "$sample_id")"
        quast_label="$(basename "$(filtered_fasta "$sample_id")" .fasta)"
        total_length="$(quast_metric "Total length" "$quast_label")"
        contigs="$(quast_metric "# contigs" "$quast_label")"
        if [[ -z "$contigs" ]]; then
            contigs="$(quast_metric "# contigs (>= 0 bp)" "$quast_label")"
        fi
        n50="$(quast_metric "N50" "$quast_label")"
        busco_line="$(find "$(busco_sample_dir "$sample_id")" -type f -name 'short_summary*.txt' -exec awk '/C:[0-9]/{print; exit}' {} \; | head -n 1)"
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$sample_id" "$assembly" "$total_length" "$contigs" "$n50" "$busco_line" >> "$output_file"
    done
}

if smoke_mode; then
    log "Smoke mode: creating mock MultiQC report"
    write_smoke_html "$MULTIQC_DIR/multiqc_report.html"
    write_qc_summary
    exit 0
fi

activate_conda_env "$MULTIQC_ENV" "${MULTIQC_ENV_PREFIX:-}"

log "Running MultiQC across BUSCO and QUAST outputs"
cd "$MULTIQC_DIR"
multiqc "$BUSCO_DIR" "$QUAST_DIR" -o "$MULTIQC_DIR"
[[ -s "$MULTIQC_DIR/multiqc_report.html" ]] || die "MultiQC report was not created: $MULTIQC_DIR/multiqc_report.html"
write_qc_summary
