#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_PATH="${1:-$SCRIPT_DIR/config/pipeline.env}"
CONFIG_DIR="$(cd "$(dirname "$CONFIG_PATH")" && pwd)"
CONFIG_PATH="$CONFIG_DIR/$(basename "$CONFIG_PATH")"

# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/scripts/lib/common.sh"
source_config "$CONFIG_PATH"

report_dir="${2:-$LOG_DIR/run_reports}"
ensure_dir "$report_dir"

timestamp="$(date '+%Y%m%d_%H%M%S')"
report_txt="$report_dir/run_report_$timestamp.txt"
resource_tsv="$report_dir/run_report_$timestamp.resources.tsv"
manifest_list="$report_dir/run_report_$timestamp.manifests.txt"

mapfile -t manifests < <(
    find "$LOG_DIR/submissions" -maxdepth 1 -type f \
        \( -name 'run_*_jobs.tsv' -o -name 'chain_*_submitters.tsv' \) 2>/dev/null | sort
)

{
    printf 'Akodon pipeline run report\n'
    printf 'Generated: %s\n' "$(date '+%F %T')"
    printf 'Config: %s\n' "$CONFIG_PATH"
    printf 'Project root: %s\n' "$PROJECT_ROOT"
    printf '\n'

    printf 'Manifests\n'
    if (( ${#manifests[@]} == 0 )); then
        printf '  No submission manifests found under %s/submissions\n' "$LOG_DIR"
    else
        printf '%s\n' "${manifests[@]}" | tee "$manifest_list" >/dev/null
        sed 's/^/  /' "$manifest_list"
    fi

    printf '\nKey output directories\n'
    printf '  SLURM logs:                  %s\n' "$LOG_DIR"
    printf '  Submission manifests:        %s/submissions\n' "$LOG_DIR"
    printf '  Preflight reports:           %s\n' "$PREFLIGHT_DIR"
    printf '  Supernova runs:              %s\n' "$SUPERNOVA_RUN_DIR"
    printf '  Pseudohap FASTA:             %s\n' "$PSEUDOHAP_DIR"
    printf '  Filtered FASTA:              %s\n' "$FILTERED_DIR"
    printf '  QUAST:                       %s\n' "$QUAST_DIR"
    printf '  BUSCO:                       %s\n' "$BUSCO_DIR"
    printf '  MultiQC/qc_summary.tsv:      %s\n' "$MULTIQC_DIR"
    printf '  RepeatModeler:               %s\n' "$REPEATMODELER_DIR"
    printf '  RepeatMasker:                %s\n' "$REPEATMASKER_DIR"
    printf '  RNA FASTQ input:             %s\n' "$RNA_ALIGN_FASTQ_DIR"
    printf '  RNA BAM evidence:            %s\n' "$RNA_ALIGN_BAM_DIR"
    printf '  RNA alignment logs:          %s\n' "$RNA_ALIGN_LOG_DIR"
    printf '  RNA alignment temp files:    %s\n' "$RNA_ALIGN_TMP_DIR"
    printf '  Annotation output:           %s\n' "$ANNOTATION_OUTPUT_DIR"
    printf '  Restored final files:        %s\n' "$ANNOTATION_ORIGINAL_HEADERS_DIR"
    printf '  InterProScan output:         %s\n' "$INTERPROSCAN_OUTPUT_DIR"
    printf '\n'

    printf 'Important files when present\n'
    for path in \
        "$TOOL_VERSIONS_TSV" \
        "$PREFLIGHT_DIR/preflight_checks.tsv" \
        "$MULTIQC_DIR/qc_summary.tsv" \
        "$MULTIQC_DIR/multiqc_report.html" \
        "$QUAST_DIR/report.tsv"
    do
        if [[ -e "$path" ]]; then
            printf '  OK       %s\n' "$path"
        else
            printf '  MISSING  %s\n' "$path"
        fi
    done
} > "$report_txt"

if (( ${#manifests[@]} > 0 )); then
    {
        first=1
        for manifest in "${manifests[@]}"; do
            if (( first )); then
                bash "$SCRIPT_DIR/scripts/summarize_slurm_run.sh" --resources "$manifest"
                first=0
            else
                bash "$SCRIPT_DIR/scripts/summarize_slurm_run.sh" --resources "$manifest" | awk 'NR > 1'
            fi
        done
    } > "$resource_tsv"
else
    printf 'stage_id\tstage_name\tjob_id\tstate\texit_code\telapsed\talloc_cpus\treq_mem\tmax_rss\ttotal_cpu\tstderr\n' > "$resource_tsv"
fi

{
    printf '\nResource summary TSV\n'
    printf '  %s\n' "$resource_tsv"
    printf '\nQuick status\n'
    awk -F '\t' '
        NR == 1 { next }
        {
            counts[$4]++
            if ($4 != "COMPLETED") {
                failed = failed sprintf("  %s\t%s\t%s\t%s\t%s\n", $1, $2, $3, $4, $11)
            }
        }
        END {
            for (state in counts) {
                printf "  %s\t%d\n", state, counts[state]
            }
            if (failed != "") {
                printf "\nNon-completed stages\n"
                printf "%s", failed
            }
        }
    ' "$resource_tsv"
} >> "$report_txt"

printf 'Run report: %s\n' "$report_txt"
printf 'Resource TSV: %s\n' "$resource_tsv"
