#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_PATH="${1:-$REPO_ROOT/config/pipeline.env}"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
source_config "$CONFIG_PATH"

report_path() {
    local label="$1"
    local path="$2"
    local kind="${3:-either}"
    local status="MISSING"

    case "$kind" in
        file)
            [[ -f "$path" ]] && status="OK"
            ;;
        dir)
            [[ -d "$path" ]] && status="OK"
            ;;
        either)
            [[ -e "$path" ]] && status="OK"
            ;;
        *)
            die "Unsupported path kind: $kind"
            ;;
    esac

    printf '    %-24s %s\n' "$label [$status]" "$path"
}

report_command() {
    local label="$1"
    local candidate="$2"
    local status="MISSING"
    local resolved="$candidate"

    if resolved="$(resolve_command_path "$candidate")"; then
        status="OK"
    fi

    printf '    %-24s %s\n' "$label [$status]" "$resolved"
}

printf 'Pipeline stage order\n'
printf '  01  Supernova assembly\n'
printf '  02  Supernova mkoutput -> canonical pseudohap FASTA\n'
printf '  03  Scaffold filtering with seqkit\n'
printf '  04  QUAST on filtered assemblies\n'
printf '  05  BUSCO on filtered assemblies\n'
printf '  06  BUSCO plot generation (optional)\n'
printf '  07  MultiQC across QUAST + BUSCO\n'
printf '  08  RepeatModeler on filtered assemblies\n'
printf '  09  Repeat library merge + CD-HIT + known/unknown split\n'
printf '  10  RepeatMasker with Dfam and custom repeat libraries\n'
printf '  11  Annotation genome preprocessing: simplify masked-genome headers\n'
printf '  12  Download reference protein sets from NCBI\n'
printf '  13  Prepare combined simplified protein FASTA for GALBA/BRAKER\n'
printf '  14  Run GALBA with protein evidence\n'
printf '  15  Run BRAKER2 with protein evidence\n'
printf '  16  Run BRAKER3 with RNA-seq BAM evidence\n'
printf '  17  Combine GALBA + BRAKER with TSEBRA\n'
printf '  18  Filter to longest isoform and export CDS/proteins\n'
printf '  19  Restore original genome headers in final annotation files\n'
printf '  20  Run InterProScan on predicted proteins\n'
printf '\n'

printf 'Shared resources\n'
report_path "Samples table" "$SAMPLES_TSV" file
report_path "FASTQ directory" "$DATA_DIR" dir
report_path "Supernova binary" "$SUPERNOVA_BIN" file
report_command "QUAST binary" "$QUAST_BIN"
report_command "BUSCO plot script" "$BUSCO_PLOT_SCRIPT"
report_path "BUSCO lineage" "$BUSCO_LINEAGE_DIR" dir
report_path "RepeatModeler image" "$REPEATMODELER_IMAGE" file
report_path "BRAKER image" "$BRAKER_SIF" file
report_path "GALBA image" "$GALBA_SIF" file
report_path "InterProScan image" "$INTERPROSCAN_SIF" file
report_path "InterProScan data" "$INTERPROSCAN_DATA_DIR" dir
report_path "Longest isoform script" "$ANNOTATION_LONGEST_ISOFORM_SCRIPT" file
printf '\n'

sample_total="$(sample_count)"
for ((idx = 0; idx < sample_total; idx++)); do
    sample_id="$(sample_id_by_index "$idx")"
    fastq_sample="$(fastq_sample_by_index "$idx")"
    run_id="$(supernova_run_id "$fastq_sample")"
    run_dir="$(supernova_run_dir "$fastq_sample")"
    asmdir="$(supernova_asmdir "$fastq_sample")"
    pseudohap="$(canonical_pseudohap "$sample_id")"
    filtered="$(filtered_fasta "$sample_id")"
    repeatmodeler_dir="$(repeatmodeler_workdir "$sample_id")"
    repeatmasker_dir="$(repeatmasker_workdir "$sample_id")"
    busco_dir_for_sample="$(busco_sample_dir "$sample_id")"
    repeat_export="$(repeatmodeler_export_fasta "$sample_id")"
    repeatmasker_final="$(repeatmasker_final_masked "$sample_id")"

    printf 'Sample %s (%s)\n' "$sample_id" "$fastq_sample"
    printf '  01 -> 02\n'
    report_path "Supernova run dir" "$run_dir" dir
    report_path "Supernova asmdir" "$asmdir" dir
    printf '  02 -> 03\n'
    report_path "Canonical pseudohap" "$pseudohap" file
    printf '  03 -> 04/05/08/10\n'
    report_path "Filtered FASTA" "$filtered" file
    printf '  05 -> 06/07\n'
    report_path "BUSCO sample dir" "$busco_dir_for_sample" dir
    printf '  08 -> 09\n'
    report_path "RepeatModeler dir" "$repeatmodeler_dir" dir
    report_path "Exported repeats" "$repeat_export" file
    printf '  10 outputs\n'
    report_path "RepeatMasker dir" "$repeatmasker_dir" dir
    report_path "Final masked FASTA" "$repeatmasker_final" file
    printf '\n'
done

printf 'Shared downstream outputs\n'
report_path "QUAST dir" "$QUAST_DIR" dir
report_path "QUAST report" "$(quast_report_tsv)" file
report_path "MultiQC dir" "$MULTIQC_DIR" dir
report_path "Repeat family export dir" "$REPEAT_FAMILY_EXPORT_DIR" dir
report_path "Repeat library dir" "$REPEAT_LIBRARY_DIR" dir
report_path "Known repeat library" "$(known_repeat_library)" file
report_path "Unknown repeat library" "$(unknown_repeat_library)" file
printf '\n'

printf 'Annotation branch recovered from job_scripts/bin\n'
printf '  10 -> 11\n'
printf '    Final masked genome is simplified before BRAKER/GALBA.\n'
printf '  12 -> 13 -> 14\n'
printf '    NCBI protein downloads are concatenated and header-simplified for GALBA.\n'
printf '  11 + 13 -> 14\n'
printf '    GALBA uses the simplified masked genome plus the simplified protein set.\n'
printf '  11 + protein evidence -> 15\n'
printf '    BRAKER2 is a protein-evidence-only alternative model.\n'
printf '  11 + RNA BAMs + protein evidence -> 16\n'
printf '    BRAKER3 uses RNA-seq BAMs and vertebrate proteins.\n'
printf '  14 + 16 -> 17\n'
printf '    TSEBRA combines GALBA and BRAKER predictions using their GTF and hints files.\n'
printf '  14/15/16/17 -> 18\n'
printf '    Longest-isoform filtering prepares OMArk-style protein sets from each predictor.\n'
printf '  11 + 14/15/16/17 -> 19\n'
printf '    Original contig headers are restored for final genome/GTF deliverables.\n'
printf '  18 -> 20\n'
printf '    InterProScan runs on a chosen predicted protein FASTA, likely GALBA or TSEBRA output.\n'
printf '\n'
printf 'Annotation paths for configured sample %s\n' "$ANNOTATION_SAMPLE_ID"
report_path "Masked genome input" "$(annotation_masked_genome "$ANNOTATION_SAMPLE_ID")" file
report_path "Simplified genome" "$(annotation_simplified_genome "$ANNOTATION_SAMPLE_ID")" file
report_path "Genome header map" "$(annotation_header_map "$ANNOTATION_SAMPLE_ID")" file
report_path "Protein zip dir" "$NCBI_PROTEIN_ZIP_DIR" dir
report_path "Simplified proteins" "$SIMPLIFIED_PROTEIN_FASTA" file
report_path "GALBA current" "$(annotation_predictor_link galba)" dir
report_path "BRAKER2 current" "$(annotation_predictor_link braker2)" dir
report_path "BRAKER3 current" "$(annotation_predictor_link braker3)" dir
report_path "TSEBRA current" "$(annotation_tsebra_current_dir)" dir
report_path "Isoform root" "$(annotation_isoform_root)" dir
report_path "Restored headers dir" "$ANNOTATION_ORIGINAL_HEADERS_DIR" dir
report_path "InterProScan run dir" "$(annotation_interproscan_run_dir)" dir
