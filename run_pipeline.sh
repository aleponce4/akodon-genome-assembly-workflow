#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="${1:-$SCRIPT_DIR/config/pipeline.env}"

# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/scripts/lib/common.sh"
source_config "$CONFIG_PATH"
ensure_base_dirs

command -v sbatch >/dev/null 2>&1 || die "sbatch was not found on PATH."

submit_stage() {
    local dependency="$1"
    shift

    local -a sbatch_args=(
        --parsable
        --account="$SBATCH_ACCOUNT"
    )

    if [[ -n "$dependency" ]]; then
        sbatch_args+=(--dependency="afterok:$dependency")
    fi

    sbatch "${sbatch_args[@]}" "$@"
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

array_bounds="$(sample_array_bounds)"
supernova_array="$(array_spec "$array_bounds" "$SUPERNOVA_ARRAY_CONCURRENCY")"
mkoutput_array="$(array_spec "$array_bounds" "$MKOUTPUT_ARRAY_CONCURRENCY")"
filter_array="$(array_spec "$array_bounds" "$FILTER_ARRAY_CONCURRENCY")"
busco_array="$(array_spec "$array_bounds" "$BUSCO_ARRAY_CONCURRENCY")"
repeatmodeler_array="$(array_spec "$array_bounds" "$REPEATMODELER_ARRAY_CONCURRENCY")"
repeatmasker_array="$(array_spec "$array_bounds" "$REPEATMASKER_ARRAY_CONCURRENCY")"

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

supernova_job_id="$(submit_stage "" "${supernova_args[@]}" "$SCRIPT_DIR/slurm/01_supernova_array.sh" "$CONFIG_PATH")"

mkoutput_job_id="$(submit_stage "$supernova_job_id" \
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

filter_job_id="$(submit_stage "$mkoutput_job_id" \
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

quast_job_id="$(submit_stage "$filter_job_id" \
    --job-name=akodon_quast \
    --partition="$QUAST_PARTITION" \
    --qos="$QUAST_QOS" \
    --time="$QUAST_TIME" \
    --cpus-per-task="$QUAST_CPUS" \
    --mem="$QUAST_MEM" \
    --output="$LOG_DIR/quast_%j.out" \
    --error="$LOG_DIR/quast_%j.err" \
    "$SCRIPT_DIR/slurm/04_quast.sh" "$CONFIG_PATH")"

busco_job_id="$(submit_stage "$filter_job_id" \
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

repeatmodeler_job_id="$(submit_stage "$filter_job_id" \
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

repeat_library_job_id="$(submit_stage "$repeatmodeler_job_id" \
    --job-name=akodon_repeat_library \
    --partition="$REPEAT_LIBRARY_PARTITION" \
    --qos="$REPEAT_LIBRARY_QOS" \
    --time="$REPEAT_LIBRARY_TIME" \
    --cpus-per-task="$REPEAT_LIBRARY_CPUS" \
    --mem="$REPEAT_LIBRARY_MEM" \
    --output="$LOG_DIR/repeat_library_%j.out" \
    --error="$LOG_DIR/repeat_library_%j.err" \
    "$SCRIPT_DIR/slurm/09_prepare_repeat_library.sh" "$CONFIG_PATH")"

repeatmasker_job_id="$(submit_stage "$repeat_library_job_id" \
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
    busco_plot_job_id="$(submit_stage "$busco_job_id" \
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

multiqc_dependency="$quast_job_id:$busco_job_id"
multiqc_job_id="$(submit_stage "$multiqc_dependency" \
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
    if truthy "$ENABLE_TSEBRA"; then
        is_supported_tsebra_source "$TSEBRA_GTF1_SOURCE" || die "Unsupported TSEBRA_GTF1_SOURCE: $TSEBRA_GTF1_SOURCE"
        is_supported_tsebra_source "$TSEBRA_GTF2_SOURCE" || die "Unsupported TSEBRA_GTF2_SOURCE: $TSEBRA_GTF2_SOURCE"
        [[ "$TSEBRA_GTF1_SOURCE" != "$TSEBRA_GTF2_SOURCE" ]] || die "TSEBRA_GTF1_SOURCE and TSEBRA_GTF2_SOURCE must be different."

        tsebra_gtf1_enable_var="$(predictor_enable_var "$TSEBRA_GTF1_SOURCE")"
        tsebra_gtf2_enable_var="$(predictor_enable_var "$TSEBRA_GTF2_SOURCE")"
        truthy "${!tsebra_gtf1_enable_var:-0}" || die "ENABLE_TSEBRA=1 requires ${tsebra_gtf1_enable_var}=1 for TSEBRA_GTF1_SOURCE=$TSEBRA_GTF1_SOURCE."
        truthy "${!tsebra_gtf2_enable_var:-0}" || die "ENABLE_TSEBRA=1 requires ${tsebra_gtf2_enable_var}=1 for TSEBRA_GTF2_SOURCE=$TSEBRA_GTF2_SOURCE."
    fi

    if truthy "$ENABLE_INTERPROSCAN" && ! truthy "$ENABLE_ISOFORM_FILTER" && [[ -z "$INTERPROSCAN_INPUT_FASTA" ]]; then
        die "ENABLE_INTERPROSCAN=1 without ENABLE_ISOFORM_FILTER requires INTERPROSCAN_INPUT_FASTA to be set."
    fi

    annotation_preprocess_job_id="$(submit_stage "$repeatmasker_job_id" \
        --job-name=akodon_annotation_preprocess \
        --partition="$ANNOTATION_PREPROCESS_PARTITION" \
        --qos="$ANNOTATION_PREPROCESS_QOS" \
        --time="$ANNOTATION_PREPROCESS_TIME" \
        --cpus-per-task="$ANNOTATION_PREPROCESS_CPUS" \
        --mem="$ANNOTATION_PREPROCESS_MEM" \
        --output="$LOG_DIR/annotation_preprocess_%j.out" \
        --error="$LOG_DIR/annotation_preprocess_%j.err" \
        "$SCRIPT_DIR/slurm/11_annotation_preprocess_genome.sh" "$CONFIG_PATH")"

    if truthy "$ENABLE_ANNOTATION_PROTEIN_DOWNLOAD"; then
        annotation_download_job_id="$(submit_stage "$repeatmasker_job_id" \
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
        annotation_protein_prep_job_id="$(submit_stage "$protein_prep_dependency" \
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
        galba_job_id="$(submit_stage "$galba_dependency" \
            --job-name=akodon_galba \
            --partition="$GALBA_PARTITION" \
            --qos="$GALBA_QOS" \
            --time="$GALBA_TIME" \
            --cpus-per-task="$GALBA_CPUS" \
            --mem="$GALBA_MEM" \
            --output="$LOG_DIR/galba_%j.out" \
            --error="$LOG_DIR/galba_%j.err" \
            "$SCRIPT_DIR/slurm/14_galba.sh" "$CONFIG_PATH")"
    fi

    braker2_dependency="$(join_dependencies "$annotation_preprocess_job_id" "${annotation_protein_prep_job_id:-}")"
    if truthy "$ENABLE_BRAKER2"; then
        braker2_job_id="$(submit_stage "$braker2_dependency" \
            --job-name=akodon_braker2 \
            --partition="$BRAKER2_PARTITION" \
            --qos="$BRAKER2_QOS" \
            --time="$BRAKER2_TIME" \
            --cpus-per-task="$BRAKER2_CPUS" \
            --mem="$BRAKER2_MEM" \
            --output="$LOG_DIR/braker2_%j.out" \
            --error="$LOG_DIR/braker2_%j.err" \
            "$SCRIPT_DIR/slurm/15_braker2.sh" "$CONFIG_PATH")"
    fi

    if truthy "$ENABLE_BRAKER3"; then
        braker3_job_id="$(submit_stage "$annotation_preprocess_job_id" \
            --job-name=akodon_braker3 \
            --partition="$BRAKER3_PARTITION" \
            --qos="$BRAKER3_QOS" \
            --time="$BRAKER3_TIME" \
            --cpus-per-task="$BRAKER3_CPUS" \
            --mem="$BRAKER3_MEM" \
            --output="$LOG_DIR/braker3_%j.out" \
            --error="$LOG_DIR/braker3_%j.err" \
            "$SCRIPT_DIR/slurm/16_braker3.sh" "$CONFIG_PATH")"
    fi

    if truthy "$ENABLE_TSEBRA"; then
        tsebra_dependency="$(join_dependencies "${galba_job_id:-}" "${braker3_job_id:-}")"
        tsebra_job_id="$(submit_stage "$tsebra_dependency" \
            --job-name=akodon_tsebra \
            --partition="$TSEBRA_PARTITION" \
            --qos="$TSEBRA_QOS" \
            --time="$TSEBRA_TIME" \
            --cpus-per-task="$TSEBRA_CPUS" \
            --mem="$TSEBRA_MEM" \
            --output="$LOG_DIR/tsebra_%j.out" \
            --error="$LOG_DIR/tsebra_%j.err" \
            "$SCRIPT_DIR/slurm/17_tsebra.sh" "$CONFIG_PATH")"
    fi

    if truthy "$ENABLE_ISOFORM_FILTER"; then
        isoform_dependency="$(join_dependencies "${galba_job_id:-}" "${braker2_job_id:-}" "${braker3_job_id:-}" "${tsebra_job_id:-}")"
        isoform_job_id="$(submit_stage "$isoform_dependency" \
            --job-name=akodon_isoform_filter \
            --partition="$ISOFORM_PARTITION" \
            --qos="$ISOFORM_QOS" \
            --time="$ISOFORM_TIME" \
            --cpus-per-task="$ISOFORM_CPUS" \
            --mem="$ISOFORM_MEM" \
            --output="$LOG_DIR/isoform_filter_%j.out" \
            --error="$LOG_DIR/isoform_filter_%j.err" \
            "$SCRIPT_DIR/slurm/18_isoform_filter.sh" "$CONFIG_PATH")"
    fi

    if truthy "$ENABLE_REASSIGN_HEADERS"; then
        restore_dependency="$(join_dependencies "$annotation_preprocess_job_id" "${galba_job_id:-}" "${braker2_job_id:-}" "${braker3_job_id:-}" "${tsebra_job_id:-}" "${isoform_job_id:-}")"
        restore_headers_job_id="$(submit_stage "$restore_dependency" \
            --job-name=akodon_restore_headers \
            --partition="$REASSIGN_PARTITION" \
            --qos="$REASSIGN_QOS" \
            --time="$REASSIGN_TIME" \
            --cpus-per-task="$REASSIGN_CPUS" \
            --mem="$REASSIGN_MEM" \
            --output="$LOG_DIR/restore_headers_%j.out" \
            --error="$LOG_DIR/restore_headers_%j.err" \
            "$SCRIPT_DIR/slurm/19_restore_headers.sh" "$CONFIG_PATH")"
    fi

    if truthy "$ENABLE_INTERPROSCAN"; then
        interproscan_dependency="$(join_dependencies "${isoform_job_id:-}" "${tsebra_job_id:-}" "${galba_job_id:-}" "${braker2_job_id:-}" "${braker3_job_id:-}")"
        interproscan_job_id="$(submit_stage "$interproscan_dependency" \
            --job-name=akodon_interproscan \
            --partition="$INTERPROSCAN_PARTITION" \
            --qos="$INTERPROSCAN_QOS" \
            --time="$INTERPROSCAN_TIME" \
            --cpus-per-task="$INTERPROSCAN_CPUS" \
            --mem="$INTERPROSCAN_MEM" \
            --output="$LOG_DIR/interproscan_%j.out" \
            --error="$LOG_DIR/interproscan_%j.err" \
            "$SCRIPT_DIR/slurm/20_interproscan.sh" "$CONFIG_PATH")"
    fi
fi

printf 'Submitted workflow with these job IDs:\n'
printf '  Supernova:          %s\n' "$supernova_job_id"
printf '  mkoutput:           %s\n' "$mkoutput_job_id"
printf '  Filter FASTA:       %s\n' "$filter_job_id"
printf '  QUAST:              %s\n' "$quast_job_id"
printf '  BUSCO:              %s\n' "$busco_job_id"
printf '  MultiQC:            %s\n' "$multiqc_job_id"
printf '  RepeatModeler:      %s\n' "$repeatmodeler_job_id"
printf '  Repeat library:     %s\n' "$repeat_library_job_id"
printf '  RepeatMasker:       %s\n' "$repeatmasker_job_id"

if [[ -n "${busco_plot_job_id:-}" ]]; then
    printf '  BUSCO plot:         %s\n' "$busco_plot_job_id"
fi

if truthy "$ENABLE_ANNOTATION"; then
    printf '  Annotation prep:    %s\n' "$annotation_preprocess_job_id"

    if [[ -n "${annotation_download_job_id:-}" ]]; then
        printf '  Protein download:   %s\n' "$annotation_download_job_id"
    fi

    if [[ -n "${annotation_protein_prep_job_id:-}" ]]; then
        printf '  Protein prep:       %s\n' "$annotation_protein_prep_job_id"
    fi

    if [[ -n "${galba_job_id:-}" ]]; then
        printf '  GALBA:              %s\n' "$galba_job_id"
    fi

    if [[ -n "${braker2_job_id:-}" ]]; then
        printf '  BRAKER2:            %s\n' "$braker2_job_id"
    fi

    if [[ -n "${braker3_job_id:-}" ]]; then
        printf '  BRAKER3:            %s\n' "$braker3_job_id"
    fi

    if [[ -n "${tsebra_job_id:-}" ]]; then
        printf '  TSEBRA:             %s\n' "$tsebra_job_id"
    fi

    if [[ -n "${isoform_job_id:-}" ]]; then
        printf '  Isoform filter:     %s\n' "$isoform_job_id"
    fi

    if [[ -n "${restore_headers_job_id:-}" ]]; then
        printf '  Restore headers:    %s\n' "$restore_headers_job_id"
    fi

    if [[ -n "${interproscan_job_id:-}" ]]; then
        printf '  InterProScan:       %s\n' "$interproscan_job_id"
    fi
fi
