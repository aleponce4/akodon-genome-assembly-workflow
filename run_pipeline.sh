#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="${1:-$SCRIPT_DIR/config/pipeline.env}"
CONFIG_DIR="$(cd "$(dirname "$CONFIG_PATH")" && pwd)"
CONFIG_PATH="$CONFIG_DIR/$(basename "$CONFIG_PATH")"

# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/scripts/lib/common.sh"
source_config "$CONFIG_PATH"
ensure_base_dirs

command -v sbatch >/dev/null 2>&1 || die "sbatch was not found on PATH."

PIPELINE_START_STAGE="${PIPELINE_START_STAGE:-00}"
PIPELINE_END_STAGE="${PIPELINE_END_STAGE:-20}"
PIPELINE_DEPENDENCY_JOB_ID="${PIPELINE_DEPENDENCY_JOB_ID:-}"

normalize_stage() {
    local stage="$1"
    [[ "$stage" =~ ^[0-9]{1,2}$ ]] || die "Invalid stage value: $stage"
    printf '%02d' "$((10#$stage))"
}

stage_number() {
    printf '%d' "$((10#$1))"
}

PIPELINE_START_STAGE="$(normalize_stage "$PIPELINE_START_STAGE")"
PIPELINE_END_STAGE="$(normalize_stage "$PIPELINE_END_STAGE")"
(( $(stage_number "$PIPELINE_START_STAGE") <= $(stage_number "$PIPELINE_END_STAGE") )) || \
    die "PIPELINE_START_STAGE must be <= PIPELINE_END_STAGE."

submission_timestamp="$(date '+%Y%m%d_%H%M%S')"
submission_dir="$LOG_DIR/submissions"
ensure_dir "$submission_dir"
submission_manifest="$submission_dir/run_${submission_timestamp}_jobs.tsv"
config_snapshot="$submission_dir/run_${submission_timestamp}_config.env"

cp "$CONFIG_PATH" "$config_snapshot"
{
    printf '\n# Runtime resume controls captured at submission time\n'
    printf 'PIPELINE_START_STAGE=%q\n' "$PIPELINE_START_STAGE"
    printf 'PIPELINE_END_STAGE=%q\n' "$PIPELINE_END_STAGE"
    printf 'PIPELINE_DEPENDENCY_JOB_ID=%q\n' "$PIPELINE_DEPENDENCY_JOB_ID"
} >> "$config_snapshot"

printf 'stage_id\tstage_name\tjob_id\tdependency\tarray\tstdout\tstderr\tscript\n' > "$submission_manifest"

stage_in_range() {
    local stage="$1"
    local stage_n start_n end_n
    stage_n="$(stage_number "$stage")"
    start_n="$(stage_number "$PIPELINE_START_STAGE")"
    end_n="$(stage_number "$PIPELINE_END_STAGE")"
    (( stage_n >= start_n && stage_n <= end_n ))
}

join_dependencies() {
    local joined=""
    local job_id

    for job_id in "$@"; do
        [[ -n "$job_id" ]] || continue
        joined="${joined:+$joined:}$job_id"
    done

    printf '%s' "$joined"
}

array_spec() {
    local bounds="$1"
    local concurrency="${2:-}"

    if [[ -n "$concurrency" && "$concurrency" != "0" ]]; then
        printf '%s%%%s' "$bounds" "$concurrency"
    else
        printf '%s' "$bounds"
    fi
}

manifest_has_jobs() {
    awk 'NR > 1 { found = 1 } END { exit(found ? 0 : 1) }' "$submission_manifest"
}

submit_stage() {
    local stage_id="$1"
    local stage_name="$2"
    local dependency="$3"
    local array_value="$4"
    local stdout_path="$5"
    local stderr_path="$6"
    local script_path="$7"
    shift 7

    stage_id="$(normalize_stage "$stage_id")"
    stage_in_range "$stage_id" || return 0

    if [[ -z "$dependency" && -n "$PIPELINE_DEPENDENCY_JOB_ID" ]] && ! manifest_has_jobs; then
        dependency="$PIPELINE_DEPENDENCY_JOB_ID"
    fi

    local -a sbatch_args=(--parsable --account="$SBATCH_ACCOUNT")
    if [[ -n "$dependency" ]]; then
        sbatch_args+=(--dependency="afterok:$dependency")
    fi

    local job_id
    job_id="$(sbatch "${sbatch_args[@]}" "$@")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$stage_id" "$stage_name" "$job_id" "$dependency" "$array_value" "$stdout_path" "$stderr_path" "$script_path" \
        >> "$submission_manifest"
    printf '%s' "$job_id"
}

print_job() {
    local label="$1"
    local job_id="${2:-}"
    [[ -n "$job_id" ]] || return 0
    printf '  %-18s %s\n' "$label:" "$job_id"
}

array_bounds="$(sample_array_bounds)"
annotation_array_bounds="$(annotation_sample_array_bounds)"
supernova_array="$(array_spec "$array_bounds" "$SUPERNOVA_ARRAY_CONCURRENCY")"
mkoutput_array="$(array_spec "$array_bounds" "$MKOUTPUT_ARRAY_CONCURRENCY")"
filter_array="$(array_spec "$array_bounds" "$FILTER_ARRAY_CONCURRENCY")"
busco_array="$(array_spec "$array_bounds" "$BUSCO_ARRAY_CONCURRENCY")"
repeatmodeler_array="$(array_spec "$array_bounds" "$REPEATMODELER_ARRAY_CONCURRENCY")"
repeatmasker_array="$(array_spec "$array_bounds" "$REPEATMASKER_ARRAY_CONCURRENCY")"
annotation_array="$(array_spec "$annotation_array_bounds" "$ANNOTATION_ARRAY_CONCURRENCY")"

workflow_start_dependency=""

if truthy "$ENABLE_PREFLIGHT"; then
    preflight_job_id="$(submit_stage 00 preflight "" "" "$LOG_DIR/preflight_%j.out" "$LOG_DIR/preflight_%j.err" "$SCRIPT_DIR/slurm/00_tool_preflight.sh" \
        --job-name=akodon_preflight \
        --partition="$PREFLIGHT_PARTITION" \
        --qos="$PREFLIGHT_QOS" \
        --time="$PREFLIGHT_TIME" \
        --cpus-per-task="$PREFLIGHT_CPUS" \
        --mem="$PREFLIGHT_MEM" \
        --output="$LOG_DIR/preflight_%j.out" \
        --error="$LOG_DIR/preflight_%j.err" \
        "$SCRIPT_DIR/slurm/00_tool_preflight.sh" "$CONFIG_PATH")"
    workflow_start_dependency="$preflight_job_id"
fi

declare -a supernova_args=(
    --job-name=akodon_supernova
    --partition="$SUPERNOVA_PARTITION"
    --qos="$SUPERNOVA_QOS"
    --time="$SUPERNOVA_TIME"
    --cpus-per-task="$SUPERNOVA_CPUS"
    --mem="$SUPERNOVA_MEM"
    --array="$supernova_array"
    --output="$LOG_DIR/supernova_%A_%a.out"
    --error="$LOG_DIR/supernova_%A_%a.err"
)

if [[ -n "$SUPERNOVA_NODELIST" ]]; then
    supernova_args+=(--nodelist="$SUPERNOVA_NODELIST")
fi

supernova_job_id="$(submit_stage 01 supernova "$workflow_start_dependency" "$supernova_array" "$LOG_DIR/supernova_%A_%a.out" "$LOG_DIR/supernova_%A_%a.err" "$SCRIPT_DIR/slurm/01_supernova_array.sh" \
    "${supernova_args[@]}" "$SCRIPT_DIR/slurm/01_supernova_array.sh" "$CONFIG_PATH")"

mkoutput_job_id="$(submit_stage 02 mkoutput "$supernova_job_id" "$mkoutput_array" "$LOG_DIR/mkoutput_%A_%a.out" "$LOG_DIR/mkoutput_%A_%a.err" "$SCRIPT_DIR/slurm/02_mkoutput_array.sh" \
    --job-name=akodon_mkoutput \
    --partition="$MKOUTPUT_PARTITION" \
    --qos="$MKOUTPUT_QOS" \
    --time="$MKOUTPUT_TIME" \
    --cpus-per-task="$MKOUTPUT_CPUS" \
    --mem="$MKOUTPUT_MEM" \
    --array="$mkoutput_array" \
    --output="$LOG_DIR/mkoutput_%A_%a.out" \
    --error="$LOG_DIR/mkoutput_%A_%a.err" \
    "$SCRIPT_DIR/slurm/02_mkoutput_array.sh" "$CONFIG_PATH")"

filter_job_id="$(submit_stage 03 filter "$mkoutput_job_id" "$filter_array" "$LOG_DIR/filter_%A_%a.out" "$LOG_DIR/filter_%A_%a.err" "$SCRIPT_DIR/slurm/03_filter_fasta_array.sh" \
    --job-name=akodon_filter \
    --partition="$FILTER_PARTITION" \
    --qos="$FILTER_QOS" \
    --time="$FILTER_TIME" \
    --cpus-per-task="$FILTER_CPUS" \
    --mem="$FILTER_MEM" \
    --array="$filter_array" \
    --output="$LOG_DIR/filter_%A_%a.out" \
    --error="$LOG_DIR/filter_%A_%a.err" \
    "$SCRIPT_DIR/slurm/03_filter_fasta_array.sh" "$CONFIG_PATH")"

quast_job_id="$(submit_stage 04 quast "$filter_job_id" "" "$LOG_DIR/quast_%j.out" "$LOG_DIR/quast_%j.err" "$SCRIPT_DIR/slurm/04_quast.sh" \
    --job-name=akodon_quast \
    --partition="$QUAST_PARTITION" \
    --qos="$QUAST_QOS" \
    --time="$QUAST_TIME" \
    --cpus-per-task="$QUAST_CPUS" \
    --mem="$QUAST_MEM" \
    --output="$LOG_DIR/quast_%j.out" \
    --error="$LOG_DIR/quast_%j.err" \
    "$SCRIPT_DIR/slurm/04_quast.sh" "$CONFIG_PATH")"

busco_job_id="$(submit_stage 05 busco "$filter_job_id" "$busco_array" "$LOG_DIR/busco_%A_%a.out" "$LOG_DIR/busco_%A_%a.err" "$SCRIPT_DIR/slurm/05_busco_array.sh" \
    --job-name=akodon_busco \
    --partition="$BUSCO_PARTITION" \
    --qos="$BUSCO_QOS" \
    --time="$BUSCO_TIME" \
    --cpus-per-task="$BUSCO_CPUS" \
    --mem="$BUSCO_MEM" \
    --array="$busco_array" \
    --output="$LOG_DIR/busco_%A_%a.out" \
    --error="$LOG_DIR/busco_%A_%a.err" \
    "$SCRIPT_DIR/slurm/05_busco_array.sh" "$CONFIG_PATH")"

repeatmodeler_job_id="$(submit_stage 08 repeatmodeler "$filter_job_id" "$repeatmodeler_array" "$LOG_DIR/repeatmodeler_%A_%a.out" "$LOG_DIR/repeatmodeler_%A_%a.err" "$SCRIPT_DIR/slurm/08_repeatmodeler_array.sh" \
    --job-name=akodon_repeatmodeler \
    --partition="$REPEATMODELER_PARTITION" \
    --qos="$REPEATMODELER_QOS" \
    --time="$REPEATMODELER_TIME" \
    --cpus-per-task="$REPEATMODELER_CPUS" \
    --mem="$REPEATMODELER_MEM" \
    --array="$repeatmodeler_array" \
    --output="$LOG_DIR/repeatmodeler_%A_%a.out" \
    --error="$LOG_DIR/repeatmodeler_%A_%a.err" \
    "$SCRIPT_DIR/slurm/08_repeatmodeler_array.sh" "$CONFIG_PATH")"

repeat_library_job_id="$(submit_stage 09 repeat_library "$repeatmodeler_job_id" "" "$LOG_DIR/repeat_library_%j.out" "$LOG_DIR/repeat_library_%j.err" "$SCRIPT_DIR/slurm/09_prepare_repeat_library.sh" \
    --job-name=akodon_repeat_library \
    --partition="$REPEAT_LIBRARY_PARTITION" \
    --qos="$REPEAT_LIBRARY_QOS" \
    --time="$REPEAT_LIBRARY_TIME" \
    --cpus-per-task="$REPEAT_LIBRARY_CPUS" \
    --mem="$REPEAT_LIBRARY_MEM" \
    --output="$LOG_DIR/repeat_library_%j.out" \
    --error="$LOG_DIR/repeat_library_%j.err" \
    "$SCRIPT_DIR/slurm/09_prepare_repeat_library.sh" "$CONFIG_PATH")"

repeatmasker_job_id="$(submit_stage 10 repeatmasker "$repeat_library_job_id" "$repeatmasker_array" "$LOG_DIR/repeatmasker_%A_%a.out" "$LOG_DIR/repeatmasker_%A_%a.err" "$SCRIPT_DIR/slurm/10_repeatmasker_array.sh" \
    --job-name=akodon_repeatmasker \
    --partition="$REPEATMASKER_PARTITION" \
    --qos="$REPEATMASKER_QOS" \
    --time="$REPEATMASKER_TIME" \
    --cpus-per-task="$REPEATMASKER_CPUS" \
    --mem="$REPEATMASKER_MEM" \
    --array="$repeatmasker_array" \
    --output="$LOG_DIR/repeatmasker_%A_%a.out" \
    --error="$LOG_DIR/repeatmasker_%A_%a.err" \
    "$SCRIPT_DIR/slurm/10_repeatmasker_array.sh" "$CONFIG_PATH")"

if truthy "$ENABLE_BUSCO_PLOT"; then
    busco_plot_job_id="$(submit_stage 06 busco_plot "$busco_job_id" "" "$LOG_DIR/busco_plot_%j.out" "$LOG_DIR/busco_plot_%j.err" "$SCRIPT_DIR/slurm/06_busco_plot.sh" \
        --job-name=akodon_busco_plot \
        --partition="$BUSCO_PLOT_PARTITION" \
        --qos="$BUSCO_PLOT_QOS" \
        --time="$BUSCO_PLOT_TIME" \
        --cpus-per-task="$BUSCO_PLOT_CPUS" \
        --mem="$BUSCO_PLOT_MEM" \
        --output="$LOG_DIR/busco_plot_%j.out" \
        --error="$LOG_DIR/busco_plot_%j.err" \
        "$SCRIPT_DIR/slurm/06_busco_plot.sh" "$CONFIG_PATH")"
fi

multiqc_dependency="$(join_dependencies "$quast_job_id" "$busco_job_id")"
multiqc_job_id="$(submit_stage 07 multiqc "$multiqc_dependency" "" "$LOG_DIR/multiqc_%j.out" "$LOG_DIR/multiqc_%j.err" "$SCRIPT_DIR/slurm/07_multiqc.sh" \
    --job-name=akodon_multiqc \
    --partition="$MULTIQC_PARTITION" \
    --qos="$MULTIQC_QOS" \
    --time="$MULTIQC_TIME" \
    --cpus-per-task="$MULTIQC_CPUS" \
    --mem="$MULTIQC_MEM" \
    --output="$LOG_DIR/multiqc_%j.out" \
    --error="$LOG_DIR/multiqc_%j.err" \
    "$SCRIPT_DIR/slurm/07_multiqc.sh" "$CONFIG_PATH")"

if truthy "$ENABLE_ANNOTATION"; then
    if truthy "$ENABLE_TSEBRA" && stage_in_range 17; then
        is_supported_tsebra_source "$TSEBRA_GTF1_SOURCE" || die "Unsupported TSEBRA_GTF1_SOURCE: $TSEBRA_GTF1_SOURCE"
        is_supported_tsebra_source "$TSEBRA_GTF2_SOURCE" || die "Unsupported TSEBRA_GTF2_SOURCE: $TSEBRA_GTF2_SOURCE"
        [[ "$TSEBRA_GTF1_SOURCE" != "$TSEBRA_GTF2_SOURCE" ]] || die "TSEBRA_GTF1_SOURCE and TSEBRA_GTF2_SOURCE must be different."

        tsebra_gtf1_enable_var="$(predictor_enable_var "$TSEBRA_GTF1_SOURCE")"
        tsebra_gtf2_enable_var="$(predictor_enable_var "$TSEBRA_GTF2_SOURCE")"
        truthy "${!tsebra_gtf1_enable_var:-0}" || die "ENABLE_TSEBRA=1 requires ${tsebra_gtf1_enable_var}=1 for TSEBRA_GTF1_SOURCE=$TSEBRA_GTF1_SOURCE."
        truthy "${!tsebra_gtf2_enable_var:-0}" || die "ENABLE_TSEBRA=1 requires ${tsebra_gtf2_enable_var}=1 for TSEBRA_GTF2_SOURCE=$TSEBRA_GTF2_SOURCE."
    fi

    if truthy "$ENABLE_INTERPROSCAN" && stage_in_range 20 && ! truthy "$ENABLE_ISOFORM_FILTER" && [[ -z "$INTERPROSCAN_INPUT_FASTA" ]]; then
        die "ENABLE_INTERPROSCAN=1 without ENABLE_ISOFORM_FILTER requires INTERPROSCAN_INPUT_FASTA to be set."
    fi

    annotation_preprocess_job_id="$(submit_stage 11 annotation_preprocess "$repeatmasker_job_id" "$annotation_array" "$LOG_DIR/annotation_preprocess_%A_%a.out" "$LOG_DIR/annotation_preprocess_%A_%a.err" "$SCRIPT_DIR/slurm/11_annotation_preprocess_genome.sh" \
        --job-name=akodon_annotation_preprocess \
        --partition="$ANNOTATION_PREPROCESS_PARTITION" \
        --qos="$ANNOTATION_PREPROCESS_QOS" \
        --time="$ANNOTATION_PREPROCESS_TIME" \
        --cpus-per-task="$ANNOTATION_PREPROCESS_CPUS" \
        --mem="$ANNOTATION_PREPROCESS_MEM" \
        --array="$annotation_array" \
        --output="$LOG_DIR/annotation_preprocess_%A_%a.out" \
        --error="$LOG_DIR/annotation_preprocess_%A_%a.err" \
        "$SCRIPT_DIR/slurm/11_annotation_preprocess_genome.sh" "$CONFIG_PATH")"

    if truthy "$ENABLE_ANNOTATION_PROTEIN_DOWNLOAD"; then
        annotation_download_job_id="$(submit_stage 12 annotation_download "$repeatmasker_job_id" "" "$LOG_DIR/annotation_download_%j.out" "$LOG_DIR/annotation_download_%j.err" "$SCRIPT_DIR/slurm/12_annotation_download_proteins.sh" \
            --job-name=akodon_annotation_download \
            --partition="$ANNOTATION_DOWNLOAD_PARTITION" \
            --qos="$ANNOTATION_DOWNLOAD_QOS" \
            --time="$ANNOTATION_DOWNLOAD_TIME" \
            --cpus-per-task="$ANNOTATION_DOWNLOAD_CPUS" \
            --mem="$ANNOTATION_DOWNLOAD_MEM" \
            --output="$LOG_DIR/annotation_download_%j.out" \
            --error="$LOG_DIR/annotation_download_%j.err" \
            "$SCRIPT_DIR/slurm/12_annotation_download_proteins.sh" "$CONFIG_PATH")"
    fi

    if truthy "$ENABLE_ANNOTATION_PROTEIN_PREPROCESS"; then
        protein_prep_dependency="$(join_dependencies "${annotation_download_job_id:-}" "$repeatmasker_job_id")"
        annotation_protein_prep_job_id="$(submit_stage 13 annotation_protein_prep "$protein_prep_dependency" "" "$LOG_DIR/annotation_protein_prep_%j.out" "$LOG_DIR/annotation_protein_prep_%j.err" "$SCRIPT_DIR/slurm/13_annotation_prepare_proteins.sh" \
            --job-name=akodon_annotation_protein_prep \
            --partition="$ANNOTATION_PROTEIN_PREP_PARTITION" \
            --qos="$ANNOTATION_PROTEIN_PREP_QOS" \
            --time="$ANNOTATION_PROTEIN_PREP_TIME" \
            --cpus-per-task="$ANNOTATION_PROTEIN_PREP_CPUS" \
            --mem="$ANNOTATION_PROTEIN_PREP_MEM" \
            --output="$LOG_DIR/annotation_protein_prep_%j.out" \
            --error="$LOG_DIR/annotation_protein_prep_%j.err" \
            "$SCRIPT_DIR/slurm/13_annotation_prepare_proteins.sh" "$CONFIG_PATH")"
    fi

    galba_dependency="$(join_dependencies "$annotation_preprocess_job_id" "${annotation_protein_prep_job_id:-}")"
    if truthy "$ENABLE_GALBA"; then
        galba_job_id="$(submit_stage 14 galba "$galba_dependency" "$annotation_array" "$LOG_DIR/galba_%A_%a.out" "$LOG_DIR/galba_%A_%a.err" "$SCRIPT_DIR/slurm/14_galba.sh" \
            --job-name=akodon_galba \
            --partition="$GALBA_PARTITION" \
            --qos="$GALBA_QOS" \
            --time="$GALBA_TIME" \
            --cpus-per-task="$GALBA_CPUS" \
            --mem="$GALBA_MEM" \
            --array="$annotation_array" \
            --output="$LOG_DIR/galba_%A_%a.out" \
            --error="$LOG_DIR/galba_%A_%a.err" \
            "$SCRIPT_DIR/slurm/14_galba.sh" "$CONFIG_PATH")"
    fi

    braker2_dependency="$(join_dependencies "$annotation_preprocess_job_id" "${annotation_protein_prep_job_id:-}")"
    if truthy "$ENABLE_BRAKER2"; then
        braker2_job_id="$(submit_stage 15 braker2 "$braker2_dependency" "$annotation_array" "$LOG_DIR/braker2_%A_%a.out" "$LOG_DIR/braker2_%A_%a.err" "$SCRIPT_DIR/slurm/15_braker2.sh" \
            --job-name=akodon_braker2 \
            --partition="$BRAKER2_PARTITION" \
            --qos="$BRAKER2_QOS" \
            --time="$BRAKER2_TIME" \
            --cpus-per-task="$BRAKER2_CPUS" \
            --mem="$BRAKER2_MEM" \
            --array="$annotation_array" \
            --output="$LOG_DIR/braker2_%A_%a.out" \
            --error="$LOG_DIR/braker2_%A_%a.err" \
            "$SCRIPT_DIR/slurm/15_braker2.sh" "$CONFIG_PATH")"
    fi

    if truthy "$ENABLE_BRAKER3"; then
        braker3_job_id="$(submit_stage 16 braker3 "$annotation_preprocess_job_id" "$annotation_array" "$LOG_DIR/braker3_%A_%a.out" "$LOG_DIR/braker3_%A_%a.err" "$SCRIPT_DIR/slurm/16_braker3.sh" \
            --job-name=akodon_braker3 \
            --partition="$BRAKER3_PARTITION" \
            --qos="$BRAKER3_QOS" \
            --time="$BRAKER3_TIME" \
            --cpus-per-task="$BRAKER3_CPUS" \
            --mem="$BRAKER3_MEM" \
            --array="$annotation_array" \
            --output="$LOG_DIR/braker3_%A_%a.out" \
            --error="$LOG_DIR/braker3_%A_%a.err" \
            "$SCRIPT_DIR/slurm/16_braker3.sh" "$CONFIG_PATH")"
    fi

    if truthy "$ENABLE_TSEBRA"; then
        tsebra_dependency="$(join_dependencies "${galba_job_id:-}" "${braker2_job_id:-}" "${braker3_job_id:-}")"
        tsebra_job_id="$(submit_stage 17 tsebra "$tsebra_dependency" "$annotation_array" "$LOG_DIR/tsebra_%A_%a.out" "$LOG_DIR/tsebra_%A_%a.err" "$SCRIPT_DIR/slurm/17_tsebra.sh" \
            --job-name=akodon_tsebra \
            --partition="$TSEBRA_PARTITION" \
            --qos="$TSEBRA_QOS" \
            --time="$TSEBRA_TIME" \
            --cpus-per-task="$TSEBRA_CPUS" \
            --mem="$TSEBRA_MEM" \
            --array="$annotation_array" \
            --output="$LOG_DIR/tsebra_%A_%a.out" \
            --error="$LOG_DIR/tsebra_%A_%a.err" \
            "$SCRIPT_DIR/slurm/17_tsebra.sh" "$CONFIG_PATH")"
    fi

    if truthy "$ENABLE_ISOFORM_FILTER"; then
        isoform_dependency="$(join_dependencies "${galba_job_id:-}" "${braker2_job_id:-}" "${braker3_job_id:-}" "${tsebra_job_id:-}")"
        isoform_job_id="$(submit_stage 18 isoform_filter "$isoform_dependency" "$annotation_array" "$LOG_DIR/isoform_filter_%A_%a.out" "$LOG_DIR/isoform_filter_%A_%a.err" "$SCRIPT_DIR/slurm/18_isoform_filter.sh" \
            --job-name=akodon_isoform_filter \
            --partition="$ISOFORM_PARTITION" \
            --qos="$ISOFORM_QOS" \
            --time="$ISOFORM_TIME" \
            --cpus-per-task="$ISOFORM_CPUS" \
            --mem="$ISOFORM_MEM" \
            --array="$annotation_array" \
            --output="$LOG_DIR/isoform_filter_%A_%a.out" \
            --error="$LOG_DIR/isoform_filter_%A_%a.err" \
            "$SCRIPT_DIR/slurm/18_isoform_filter.sh" "$CONFIG_PATH")"
    fi

    if truthy "$ENABLE_REASSIGN_HEADERS"; then
        restore_dependency="$(join_dependencies "$annotation_preprocess_job_id" "${galba_job_id:-}" "${braker2_job_id:-}" "${braker3_job_id:-}" "${tsebra_job_id:-}" "${isoform_job_id:-}")"
        restore_headers_job_id="$(submit_stage 19 restore_headers "$restore_dependency" "$annotation_array" "$LOG_DIR/restore_headers_%A_%a.out" "$LOG_DIR/restore_headers_%A_%a.err" "$SCRIPT_DIR/slurm/19_restore_headers.sh" \
            --job-name=akodon_restore_headers \
            --partition="$REASSIGN_PARTITION" \
            --qos="$REASSIGN_QOS" \
            --time="$REASSIGN_TIME" \
            --cpus-per-task="$REASSIGN_CPUS" \
            --mem="$REASSIGN_MEM" \
            --array="$annotation_array" \
            --output="$LOG_DIR/restore_headers_%A_%a.out" \
            --error="$LOG_DIR/restore_headers_%A_%a.err" \
            "$SCRIPT_DIR/slurm/19_restore_headers.sh" "$CONFIG_PATH")"
    fi

    if truthy "$ENABLE_INTERPROSCAN"; then
        interproscan_dependency="$(join_dependencies "${isoform_job_id:-}" "${tsebra_job_id:-}" "${galba_job_id:-}" "${braker2_job_id:-}" "${braker3_job_id:-}")"
        interproscan_job_id="$(submit_stage 20 interproscan "$interproscan_dependency" "$annotation_array" "$LOG_DIR/interproscan_%A_%a.out" "$LOG_DIR/interproscan_%A_%a.err" "$SCRIPT_DIR/slurm/20_interproscan.sh" \
            --job-name=akodon_interproscan \
            --partition="$INTERPROSCAN_PARTITION" \
            --qos="$INTERPROSCAN_QOS" \
            --time="$INTERPROSCAN_TIME" \
            --cpus-per-task="$INTERPROSCAN_CPUS" \
            --mem="$INTERPROSCAN_MEM" \
            --array="$annotation_array" \
            --output="$LOG_DIR/interproscan_%A_%a.out" \
            --error="$LOG_DIR/interproscan_%A_%a.err" \
            "$SCRIPT_DIR/slurm/20_interproscan.sh" "$CONFIG_PATH")"
    fi
fi

manifest_has_jobs || die "No stages were submitted for range ${PIPELINE_START_STAGE}-${PIPELINE_END_STAGE}."

printf 'Submitted workflow with these job IDs:\n'
print_job "Preflight" "${preflight_job_id:-}"
print_job "Supernova" "${supernova_job_id:-}"
print_job "mkoutput" "${mkoutput_job_id:-}"
print_job "Filter FASTA" "${filter_job_id:-}"
print_job "QUAST" "${quast_job_id:-}"
print_job "BUSCO" "${busco_job_id:-}"
print_job "BUSCO plot" "${busco_plot_job_id:-}"
print_job "MultiQC" "${multiqc_job_id:-}"
print_job "RepeatModeler" "${repeatmodeler_job_id:-}"
print_job "Repeat library" "${repeat_library_job_id:-}"
print_job "RepeatMasker" "${repeatmasker_job_id:-}"
print_job "Annotation prep" "${annotation_preprocess_job_id:-}"
print_job "Protein download" "${annotation_download_job_id:-}"
print_job "Protein prep" "${annotation_protein_prep_job_id:-}"
print_job "GALBA" "${galba_job_id:-}"
print_job "BRAKER2" "${braker2_job_id:-}"
print_job "BRAKER3" "${braker3_job_id:-}"
print_job "TSEBRA" "${tsebra_job_id:-}"
print_job "Isoform filter" "${isoform_job_id:-}"
print_job "Restore headers" "${restore_headers_job_id:-}"
print_job "InterProScan" "${interproscan_job_id:-}"

printf '\nSubmission manifest: %s\n' "$submission_manifest"
printf 'Config snapshot:      %s\n' "$config_snapshot"
