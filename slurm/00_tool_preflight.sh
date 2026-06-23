#!/usr/bin/env bash
# Stage 00: fail fast on cluster/tool/path problems before expensive jobs queue.

set -euo pipefail

CONFIG_PATH="${1:-${CONFIG:-}}"
[[ -n "$CONFIG_PATH" ]] || { echo "ERROR: config path is required" >&2; exit 1; }
CONFIG_DIR="$(cd "$(dirname "$CONFIG_PATH")" && pwd)"
PIPELINE_ROOT="$(cd "$CONFIG_DIR/.." && pwd)"

# shellcheck source=scripts/lib/common.sh
source "$PIPELINE_ROOT/scripts/lib/common.sh"
source_config "$CONFIG_PATH"
ensure_base_dirs

checks_tsv="$PREFLIGHT_DIR/preflight_checks.tsv"
versions_tsv="$TOOL_VERSIONS_TSV"
failures=0

printf 'check\tstatus\tdetail\n' > "$checks_tsv"
printf 'tool\tversion_detail\n' > "$versions_tsv"

record_check() {
    local check_name="$1"
    local status="$2"
    local detail="${3:-}"

    printf '%s\t%s\t%s\n' "$check_name" "$status" "$detail" >> "$checks_tsv"
    if [[ "$status" == "FAIL" ]]; then
        failures=$((failures + 1))
        log "Preflight failed: $check_name - $detail"
    fi
}

check_file() {
    local check_name="$1"
    local path="$2"

    if [[ -f "$path" ]]; then
        record_check "$check_name" "OK" "$path"
    else
        record_check "$check_name" "FAIL" "Missing file: $path"
    fi
}

check_dir() {
    local check_name="$1"
    local path="$2"

    if [[ -d "$path" ]]; then
        record_check "$check_name" "OK" "$path"
    else
        record_check "$check_name" "FAIL" "Missing directory: $path"
    fi
}

check_executable_path() {
    local check_name="$1"
    local path="$2"

    if [[ -x "$path" ]]; then
        record_check "$check_name" "OK" "$path"
    else
        record_check "$check_name" "FAIL" "Missing executable: $path"
    fi
}

check_command_or_path() {
    local check_name="$1"
    local preferred_path="$2"
    local command_name="$3"
    local resolved

    if [[ -n "$preferred_path" && -x "$preferred_path" ]]; then
        record_check "$check_name" "OK" "$preferred_path"
    elif resolved="$(resolve_command_path "$command_name")"; then
        record_check "$check_name" "OK" "$resolved"
    else
        record_check "$check_name" "FAIL" "Not found: $preferred_path or $command_name on PATH"
    fi
}

load_module_for_preflight() {
    local module_name="$1"

    [[ -n "$module_name" ]] || return 1
    load_module_support || return 1
    module load "$module_name" >/dev/null 2>&1
}

check_command_with_optional_module() {
    local check_name="$1"
    local command_name="$2"
    local module_name="$3"
    local resolved

    if resolved="$(resolve_command_path "$command_name")"; then
        record_check "$check_name" "OK" "$resolved"
        return 0
    fi

    if load_module_for_preflight "$module_name" && resolved="$(resolve_command_path "$command_name")"; then
        record_check "$check_name" "OK" "$resolved via module $module_name"
        return 0
    fi

    record_check "$check_name" "FAIL" "Command not found after optional module load: $command_name (module: $module_name)"
    return 1
}

resolve_command_or_path_for_version() {
    local preferred_path="$1"
    local command_name="$2"

    if [[ -n "$preferred_path" && -x "$preferred_path" ]]; then
        printf '%s\n' "$preferred_path"
        return 0
    fi

    resolve_command_path "$command_name"
}

record_version() {
    local label="$1"
    shift
    local detail

    set +e
    detail="$(timeout 30s "$@" 2>&1 | head -n 1)"
    set -e

    if [[ -z "$detail" ]]; then
        detail="version command produced no output"
    fi
    printf '%s\t%s\n' "$label" "$detail" >> "$versions_tsv"
}

check_version_command() {
    local check_name="$1"
    shift
    local detail

    set +e
    detail="$(timeout 30s "$@" 2>&1 | head -n 1)"
    local exit_code=$?
    set -e

    if (( exit_code == 0 )); then
        record_check "$check_name" "OK" "${detail:-version command succeeded}"
    else
        record_check "$check_name" "FAIL" "Version command failed: ${detail:-no output}"
    fi
}

record_conda_version() {
    local label="$1"
    local env_name="$2"
    local env_prefix="$3"
    shift 3
    local detail

    set +e
    detail="$((
        activate_conda_env "$env_name" "$env_prefix" >/dev/null
        timeout 30s "$@"
    ) 2>&1)"
    local exit_code=$?
    set -e

    detail="$(printf '%s\n' "$detail" | head -n 1)"
    if [[ -z "$detail" ]]; then
        detail="version command produced no output"
    fi
    printf '%s\t%s\n' "$label" "$detail" >> "$versions_tsv"

    if (( exit_code == 0 )); then
        record_check "${label}_version" "OK" "$detail"
    else
        record_check "${label}_version" "OK" "Version capture failed, but executable check passed: $detail"
    fi
}

check_line_endings() {
    local bad_files=()
    local file
    local repo_root="$PIPELINE_ROOT"

    if ! command -v git >/dev/null 2>&1 || ! git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        record_check "line_endings" "OK" "Git unavailable; skipped tracked-file CRLF scan."
        return 0
    fi

    while IFS= read -r file; do
        case "$file" in
            *.sh|*.env|*.tsv|*.pl|*.md|.gitattributes)
                if [[ ! -f "$repo_root/$file" ]]; then
                    bad_files+=("$file (missing)")
                elif grep -q $'\r' "$repo_root/$file"; then
                    bad_files+=("$file")
                fi
                ;;
        esac
    done < <(git -C "$repo_root" ls-files)

    if (( ${#bad_files[@]} > 0 )); then
        record_check "line_endings" "FAIL" "CRLF found in: ${bad_files[*]}"
    else
        record_check "line_endings" "OK" "Tracked scripts/configs use LF line endings."
    fi
}

check_fastqs() {
    local sample_total
    local idx
    local sample_id
    local fastq_sample
    local r1_files=()
    local r2_files=()

    check_file "samples_tsv" "$SAMPLES_TSV"
    check_dir "data_dir" "$DATA_DIR"

    sample_total="$(sample_count)"
    for ((idx = 0; idx < sample_total; idx++)); do
        sample_id="$(sample_id_by_index "$idx")"
        fastq_sample="$(fastq_sample_by_index "$idx")"
        mapfile -t r1_files < <(compgen -G "$DATA_DIR/${fastq_sample}"'*R1*.fastq.gz' | sort || true)
        mapfile -t r2_files < <(compgen -G "$DATA_DIR/${fastq_sample}"'*R2*.fastq.gz' | sort || true)

        if (( ${#r1_files[@]} > 0 && ${#r2_files[@]} > 0 )); then
            record_check "fastq_pair:$sample_id" "OK" "$fastq_sample R1=${#r1_files[@]} R2=${#r2_files[@]}"
        else
            record_check "fastq_pair:$sample_id" "FAIL" "Expected raw 10x FASTQs matching ${fastq_sample}*R1/R2*.fastq.gz in $DATA_DIR"
        fi
    done
}

check_rna_fastqs() {
    local library_id
    local r1_file
    local r2_file

    truthy "$ENABLE_ANNOTATION" || return 0
    truthy "$ENABLE_BRAKER3" || return 0
    truthy "$ENABLE_RNA_ALIGNMENT" || return 0

    check_dir "rna_fastq_dir" "$RNA_ALIGN_FASTQ_DIR"

    for library_id in $RNA_ALIGN_LIBRARY_IDS; do
        r1_file="$(rna_align_fastq_r1 "$library_id")"
        r2_file="$(rna_align_fastq_r2 "$library_id")"

        if [[ -f "$r1_file" && -f "$r2_file" ]]; then
            record_check "rna_fastq_pair:$library_id" "OK" "$r1_file $r2_file"
        else
            record_check "rna_fastq_pair:$library_id" "FAIL" "Expected RNA FASTQ pair: $r1_file and $r2_file"
        fi
    done
}

check_braker3_bams() {
    local sample_total
    local idx
    local sample_id
    local bam_glob
    local bam_files=()

    truthy "$ENABLE_ANNOTATION" || return 0
    truthy "$ENABLE_BRAKER3" || return 0

    if truthy "$ENABLE_RNA_ALIGNMENT"; then
        record_check "braker3_bams" "OK" "Will be generated by stage 15 RNA alignment."
        return 0
    fi

    if [[ "$BRAKER3_MODE" == "single_bam" ]]; then
        if [[ -f "$BRAKER3_SINGLE_BAM" ]]; then
            record_check "braker3_bams:single_bam" "OK" "$BRAKER3_SINGLE_BAM"
        else
            record_check "braker3_bams:single_bam" "FAIL" "BRAKER3_SINGLE_BAM not found: $BRAKER3_SINGLE_BAM"
        fi
        return 0
    fi

    [[ "$BRAKER3_MODE" == "all_samples" ]] || {
        record_check "braker3_mode" "FAIL" "Unsupported BRAKER3_MODE: $BRAKER3_MODE"
        return 0
    }

    sample_total="$(annotation_sample_count)"
    for ((idx = 0; idx < sample_total; idx++)); do
        sample_id="$(annotation_sample_id_by_index "$idx")"
        bam_glob="$(braker3_bam_glob_for_sample "$sample_id")"
        mapfile -t bam_files < <(compgen -G "$bam_glob" | sort || true)

        if (( ${#bam_files[@]} > 0 )); then
            record_check "braker3_bams:$sample_id" "OK" "$bam_glob count=${#bam_files[@]}"
        else
            record_check "braker3_bams:$sample_id" "FAIL" "No BAMs found for sample $sample_id with glob: $bam_glob"
        fi
    done
}

check_line_endings
check_fastqs
check_rna_fastqs

check_executable_path "supernova_bin" "$SUPERNOVA_BIN"
if ensure_supernova_runtime_libs; then
    record_check "supernova_runtime_libs" "OK" "$SUPERNOVA_LIB_DIR"
fi
if detail="$(timeout 120s bash -c 'source "$1"; source_config "$2"; supernova_python_import_probe' bash "$PIPELINE_ROOT/scripts/lib/common.sh" "$CONFIG_PATH" 2>&1 | head -n 1)"; then
    record_check "supernova_python_imports" "OK" "${detail:-supernova python imports OK}"
else
    record_check "supernova_python_imports" "FAIL" "${detail:-Supernova Python import probe failed}"
fi
check_command_or_path "quast_bin" "${QUAST_ENV_PREFIX:-}/bin/quast.py" "$QUAST_BIN"
check_command_or_path "busco_bin" "${BUSCO_ENV_PREFIX:-}/bin/busco" busco
check_command_or_path "multiqc_bin" "${MULTIQC_ENV_PREFIX:-}/bin/multiqc" multiqc
check_command_or_path "filter_seqkit" "${FILTER_ENV_PREFIX:-}/bin/seqkit" seqkit
check_command_or_path "repeat_cd_hit" "${REPEAT_ENV_PREFIX:-}/bin/cd-hit-est" cd-hit-est
check_command_or_path "repeat_seqkit" "${REPEAT_ENV_PREFIX:-}/bin/seqkit" seqkit
check_dir "busco_lineage" "$BUSCO_LINEAGE_DIR"
check_file "repeatmodeler_image" "$REPEATMODELER_IMAGE"

if truthy "$ENABLE_ANNOTATION"; then
    check_file "header_simplifier" "$GENOME_HEADER_SIMPLIFIER"

    if truthy "$ENABLE_ANNOTATION_PROTEIN_DOWNLOAD"; then
        check_file "ncbi_dataset_tsv" "$NCBI_DATASETS_TSV"
        check_command_or_path "datasets_bin" "${DATASETS_ENV_PREFIX:-}/bin/datasets" "$NCBI_DATASETS_BIN"
    fi

    if truthy "$ENABLE_GALBA"; then
        check_file "galba_image" "$GALBA_SIF"
    fi

    if truthy "$ENABLE_BRAKER2" || truthy "$ENABLE_BRAKER3" || truthy "$ENABLE_TSEBRA" || truthy "$ENABLE_ISOFORM_FILTER"; then
        check_file "braker_image" "$BRAKER_SIF"
    fi

    if truthy "$ENABLE_BRAKER3"; then
        check_file "braker3_protein_fasta" "$BRAKER3_PROTEIN_FASTA"
        if truthy "$ENABLE_RNA_ALIGNMENT"; then
            check_command_with_optional_module "hisat2_bin" hisat2 "$HISAT2_MODULE" || true
            check_command_with_optional_module "hisat2_build_bin" hisat2-build "$HISAT2_MODULE" || true
            check_command_with_optional_module "samtools_bin" samtools "$SAMTOOLS_MODULE" || true
        fi
        check_braker3_bams
    fi

    if truthy "$ENABLE_TSEBRA"; then
        if compgen -G "$TSEBRA_CONFIG_GLOB" >/dev/null 2>&1; then
            record_check "tsebra_configs" "OK" "$TSEBRA_CONFIG_GLOB"
        else
            record_check "tsebra_configs" "FAIL" "No TSEBRA configs found with glob: $TSEBRA_CONFIG_GLOB"
        fi
    fi

    if truthy "$ENABLE_INTERPROSCAN"; then
        check_file "interproscan_image" "$INTERPROSCAN_SIF"
        check_dir "interproscan_data" "$INTERPROSCAN_DATA_DIR/data"
    fi
fi

if resolved_singularity="$(resolve_command_path "$SINGULARITY_BIN")"; then
    record_check "singularity_bin" "OK" "$resolved_singularity"
else
    record_check "singularity_bin" "FAIL" "Container runtime not found: $SINGULARITY_BIN"
fi

if [[ -x "$SUPERNOVA_BIN" ]]; then
    record_version "supernova" "$SUPERNOVA_BIN" --version
fi

if resolved_quast="$(resolve_command_or_path_for_version "${QUAST_ENV_PREFIX:-}/bin/quast.py" "$QUAST_BIN")"; then
    record_version "quast" "$resolved_quast" --version
fi

if [[ -x "${BUSCO_ENV_PREFIX:-}/bin/busco" ]]; then
    record_conda_version "busco" "$BUSCO_ENV" "$BUSCO_ENV_PREFIX" busco --version
elif resolved_busco="$(resolve_command_or_path_for_version "" busco)"; then
    record_version "busco" "$resolved_busco" --version
fi

if resolved_multiqc="$(resolve_command_or_path_for_version "${MULTIQC_ENV_PREFIX:-}/bin/multiqc" multiqc)"; then
    record_version "multiqc" "$resolved_multiqc" --version
fi

if [[ -f "$REPEATMODELER_IMAGE" ]] && resolved_singularity="$(resolve_command_path "$SINGULARITY_BIN")"; then
    record_version "RepeatMasker" "$resolved_singularity" exec "$REPEATMODELER_IMAGE" RepeatMasker -v
    record_version "RepeatModeler" "$resolved_singularity" exec "$REPEATMODELER_IMAGE" RepeatModeler -version
fi

if truthy "$ENABLE_ANNOTATION" && [[ -f "$BRAKER_SIF" ]] && resolved_singularity="$(resolve_command_path "$SINGULARITY_BIN")"; then
    record_version "BRAKER" "$resolved_singularity" exec "$BRAKER_SIF" braker.pl --version
    record_version "TSEBRA" "$resolved_singularity" exec "$BRAKER_SIF" tsebra.py --help
fi

if truthy "$ENABLE_ANNOTATION" && truthy "$ENABLE_GALBA" && [[ -f "$GALBA_SIF" ]] && resolved_singularity="$(resolve_command_path "$SINGULARITY_BIN")"; then
    record_version "GALBA" "$resolved_singularity" exec "$GALBA_SIF" galba.pl --version
fi

if truthy "$ENABLE_ANNOTATION" && truthy "$ENABLE_BRAKER3" && truthy "$ENABLE_RNA_ALIGNMENT"; then
    if resolved_hisat2="$(resolve_command_path hisat2)"; then
        record_version "hisat2" "$resolved_hisat2" --version
    fi
    if resolved_samtools="$(resolve_command_path samtools)"; then
        record_version "samtools" "$resolved_samtools" --version
    fi
fi

printf 'BUSCO_LINEAGE\t%s\n' "$BUSCO_LINEAGE_DIR" >> "$versions_tsv"
printf 'REPEATMASKER_SPECIES\t%s\n' "$REPEATMASKER_SPECIES" >> "$versions_tsv"
printf 'REPEATMASKER_ENABLE_DFAM_ROUNDS\t%s\n' "$REPEATMASKER_ENABLE_DFAM_ROUNDS" >> "$versions_tsv"

if (( failures > 0 )); then
    die "Preflight found $failures problem(s). See $checks_tsv"
fi

log "Preflight completed successfully. Reports: $checks_tsv and $versions_tsv"
