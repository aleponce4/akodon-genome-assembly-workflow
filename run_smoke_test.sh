#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="${1:-$SCRIPT_DIR/config/smoke_test.env}"

source "$SCRIPT_DIR/scripts/lib/common.sh"
source_config "$CONFIG_PATH"

bash "$SCRIPT_DIR/scripts/setup_smoke_test.sh" "$CONFIG_PATH"

export CONFIG="$CONFIG_PATH"
export SLURM_ARRAY_TASK_ID=0

run_stage() {
    local stage_script="$1"
    printf 'Running %s\n' "$(basename "$stage_script")"
    bash "$stage_script" "$CONFIG_PATH"
}

run_stage "$SCRIPT_DIR/slurm/01_supernova_array.sh"
run_stage "$SCRIPT_DIR/slurm/02_mkoutput_array.sh"
run_stage "$SCRIPT_DIR/slurm/03_filter_fasta_array.sh"
run_stage "$SCRIPT_DIR/slurm/04_quast.sh"
run_stage "$SCRIPT_DIR/slurm/05_busco_array.sh"

if truthy "$ENABLE_BUSCO_PLOT"; then
    run_stage "$SCRIPT_DIR/slurm/06_busco_plot.sh"
fi

run_stage "$SCRIPT_DIR/slurm/07_multiqc.sh"
run_stage "$SCRIPT_DIR/slurm/08_repeatmodeler_array.sh"
run_stage "$SCRIPT_DIR/slurm/09_prepare_repeat_library.sh"
run_stage "$SCRIPT_DIR/slurm/10_repeatmasker_array.sh"

if truthy "$ENABLE_ANNOTATION"; then
    run_stage "$SCRIPT_DIR/slurm/11_annotation_preprocess_genome.sh"

    if truthy "$ENABLE_ANNOTATION_PROTEIN_DOWNLOAD"; then
        run_stage "$SCRIPT_DIR/slurm/12_annotation_download_proteins.sh"
    fi

    if truthy "$ENABLE_ANNOTATION_PROTEIN_PREPROCESS"; then
        run_stage "$SCRIPT_DIR/slurm/13_annotation_prepare_proteins.sh"
    fi

    if truthy "$ENABLE_GALBA"; then
        run_stage "$SCRIPT_DIR/slurm/14_galba.sh"
    fi

    if truthy "$ENABLE_BRAKER2"; then
        run_stage "$SCRIPT_DIR/slurm/15_braker2.sh"
    fi

    if truthy "$ENABLE_BRAKER3"; then
        run_stage "$SCRIPT_DIR/slurm/16_braker3.sh"
    fi

    if truthy "$ENABLE_TSEBRA"; then
        run_stage "$SCRIPT_DIR/slurm/17_tsebra.sh"
    fi

    if truthy "$ENABLE_ISOFORM_FILTER"; then
        run_stage "$SCRIPT_DIR/slurm/18_isoform_filter.sh"
    fi

    if truthy "$ENABLE_REASSIGN_HEADERS"; then
        run_stage "$SCRIPT_DIR/slurm/19_restore_headers.sh"
    fi

    if truthy "$ENABLE_INTERPROSCAN"; then
        run_stage "$SCRIPT_DIR/slurm/20_interproscan.sh"
    fi
fi

printf 'Smoke test completed.\n'
