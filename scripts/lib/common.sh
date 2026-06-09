#!/usr/bin/env bash

set -euo pipefail

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*" >&2
}

die() {
    log "ERROR: $*"
    exit 1
}

truthy() {
    case "${1:-0}" in
        1|true|TRUE|True|yes|YES|on|ON)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

smoke_mode() {
    truthy "${SMOKE_TEST_MODE:-0}"
}

source_config() {
    local config_path="$1"
    [[ -n "$config_path" ]] || die "Config path was not provided."
    [[ -f "$config_path" ]] || die "Config file not found: $config_path"
    # shellcheck disable=SC1090
    source "$config_path"
}

require_var() {
    local var_name="$1"
    [[ -n "${!var_name:-}" ]] || die "Required variable is not set: $var_name"
}

ensure_dir() {
    mkdir -p "$1"
}

write_smoke_fasta() {
    local output_file="$1"
    local header="${2:-smoke_seq}"
    local sequence="${3:-ATGCGTATGCGTATGCGTATGCGTATGCGT}"

    cat > "$output_file" <<EOF
>${header}
${sequence}
EOF
}

write_smoke_fasta_gz() {
    local output_file="$1"
    local header="${2:-smoke_seq}"
    local sequence="${3:-ATGCGTATGCGTATGCGTATGCGTATGCGT}"
    local tmp_file

    tmp_file="$(mktemp)"
    write_smoke_fasta "$tmp_file" "$header" "$sequence"
    gzip -c "$tmp_file" > "$output_file"
    rm -f "$tmp_file"
}

write_smoke_fastq_gz() {
    local output_file="$1"
    local read_name="${2:-smoke_read}"
    local sequence="${3:-ACGTACGTACGTACGT}"
    local quality

    quality="$(printf 'I%.0s' $(seq 1 "${#sequence}"))"
    cat <<EOF | gzip -c > "$output_file"
@${read_name}
${sequence}
+
${quality}
EOF
}

write_smoke_gtf() {
    local output_file="$1"
    local seqid="${2:-smoke_seq}"

    cat > "$output_file" <<EOF
${seqid}	smoke	gene	1	30	.	+	.	gene_id "g1";
${seqid}	smoke	transcript	1	30	.	+	.	gene_id "g1"; transcript_id "tx1";
${seqid}	smoke	exon	1	30	.	+	.	gene_id "g1"; transcript_id "tx1";
${seqid}	smoke	CDS	1	30	.	+	0	gene_id "g1"; transcript_id "tx1";
EOF
}

write_smoke_hints() {
    local output_file="$1"
    local seqid="${2:-smoke_seq}"

    cat > "$output_file" <<EOF
${seqid}	smoke	intron	5	20	1	+	.	src=E
EOF
}

write_smoke_html() {
    local output_file="$1"

    cat > "$output_file" <<EOF
<html><body><h1>Smoke Test Output</h1></body></html>
EOF
}

check_command_available() {
    local description="$1"
    shift

    "$@" >/dev/null 2>&1 || die "${description} failed during smoke test"
}

resolve_command_path() {
    local candidate="${1:-}"

    [[ -n "$candidate" ]] || return 1

    if [[ "$candidate" == */* ]]; then
        [[ -x "$candidate" ]] || return 1
        printf '%s\n' "$candidate"
        return 0
    fi

    command -v "$candidate" 2>/dev/null || return 1
}

ensure_base_dirs() {
    ensure_dir "$OUTPUT_DIR"
    ensure_dir "$LOG_DIR"
    ensure_dir "$SUPERNOVA_RUN_DIR"
    ensure_dir "$PSEUDOHAP_DIR"
    ensure_dir "$FILTERED_DIR"
    ensure_dir "$QUAST_DIR"
    ensure_dir "$BUSCO_DIR"
    ensure_dir "$BUSCO_SUMMARY_DIR"
    ensure_dir "$MULTIQC_DIR"
    ensure_dir "$REPEATMODELER_DIR"
    ensure_dir "$REPEAT_DATABASE_DIR"
    ensure_dir "$REPEAT_FAMILY_EXPORT_DIR"
    ensure_dir "$REPEAT_LIBRARY_DIR"
    ensure_dir "$REPEATMASKER_DIR"
    ensure_dir "$RNA_SEQ_DIR"
    ensure_dir "$RNA_ALIGN_FASTQ_DIR"
    ensure_dir "$RNA_ALIGN_BAM_DIR"
    ensure_dir "$RNA_ALIGN_LOG_DIR"
    ensure_dir "$RNA_ALIGN_TMP_DIR"
    ensure_dir "$RNA_ALIGN_INDEX_DIR"
    ensure_dir "$ANNOTATION_DIR"
    ensure_dir "$ANNOTATION_INPUT_DIR"
    ensure_dir "$ANNOTATION_OUTPUT_DIR"
    ensure_dir "$ANNOTATION_LOG_DIR"
    ensure_dir "$ANNOTATION_ORIGINAL_HEADERS_DIR"
    ensure_dir "$ANNOTATION_AUGUSTUS_BRAKER2_DIR"
    ensure_dir "$ANNOTATION_AUGUSTUS_GALBA_DIR"
    ensure_dir "$ANNOTATION_AUGUSTUS_BRAKER3_DIR"
    ensure_dir "$ANNOTATION_FUNCTIONAL_DIR"
    ensure_dir "$ANNOTATION_FUNCTIONAL_INPUT_DIR"
    ensure_dir "$ANNOTATION_FUNCTIONAL_OUTPUT_DIR"
    ensure_dir "$ANNOTATION_FUNCTIONAL_TEMP_DIR"
    ensure_dir "$PREFLIGHT_DIR"
}

sample_count() {
    awk 'NR == 1 { next } $0 ~ /^#/ || NF == 0 { next } { count++ } END { print count + 0 }' "$SAMPLES_TSV"
}

sample_field_by_index() {
    local index="$1"
    local field="$2"
    awk -F '\t' -v idx="$index" -v field="$field" '
        NR == 1 { next }
        $0 ~ /^#/ || NF == 0 { next }
        count == idx { print $field; exit }
        { count++ }
    ' "$SAMPLES_TSV"
}

sample_id_by_index() {
    sample_field_by_index "$1" 1
}

fastq_sample_by_index() {
    sample_field_by_index "$1" 2
}

assembly_stem() {
    local sample_id="$1"
    printf '%s_%s_pseudohap' "$ASSEMBLY_PREFIX" "$sample_id"
}

supernova_run_dir() {
    local fastq_sample="$1"
    printf '%s/%s' "$SUPERNOVA_RUN_DIR" "$(supernova_run_id "$fastq_sample")"
}

supernova_run_id() {
    local fastq_sample="$1"
    printf '%s_%s' "$SUPERNOVA_RUN_ID_PREFIX" "$fastq_sample"
}

supernova_asmdir() {
    local fastq_sample="$1"
    printf '%s/outs/assembly' "$(supernova_run_dir "$fastq_sample")"
}

ensure_supernova_runtime_libs() {
    local link_name
    local target_name
    local link_path
    local target_path
    local lib_file
    local soname

    [[ -d "$SUPERNOVA_LIB_DIR" ]] || die "Supernova runtime library directory not found: $SUPERNOVA_LIB_DIR"

    if truthy "${SUPERNOVA_PATCH_RUNTIME_LIBS:-1}"; then
        if command -v readelf >/dev/null 2>&1; then
            while IFS= read -r lib_file; do
                soname="$(readelf -d "$lib_file" 2>/dev/null | awk -F'[][]' '/SONAME/ { print $2; exit }' || true)"
                [[ -n "$soname" ]] || continue
                link_path="$SUPERNOVA_LIB_DIR/$soname"

                if [[ ! -e "$link_path" || -L "$link_path" ]]; then
                    ln -sfn "$(basename "$lib_file")" "$link_path"
                fi
            done < <(find "$SUPERNOVA_LIB_DIR" -maxdepth 1 -type f -name 'lib*.so*' | sort)
        fi

        for spec in \
            "libbz2.so.1.0:libbz2.so.1.0.6" \
            "libcurl.so.4:libcurl.so.4.5.0" \
            "libgfortran.so.4:libgfortran.so.4.0.0" \
            "libhts.so.2:libhts.so.1.7" \
            "liblzma.so.5:liblzma.so.5.2.4" \
            "libquadmath.so.0:libquadmath.so.0.0.0"
        do
            link_name="${spec%%:*}"
            target_name="${spec#*:}"
            link_path="$SUPERNOVA_LIB_DIR/$link_name"
            target_path="$SUPERNOVA_LIB_DIR/$target_name"

            if [[ -e "$link_path" && ! -L "$link_path" ]]; then
                continue
            fi

            if [[ ! -e "$target_path" ]]; then
                die "Supernova runtime library target missing for $link_name: $target_path"
            fi

            if [[ ! -e "$link_path" || -L "$link_path" ]]; then
                ln -sfn "$target_name" "$link_path"
            fi
        done
    fi

    for link_name in libbz2.so.1.0 libcurl.so.4 libgfortran.so.4 libhts.so.2 liblzma.so.5 libquadmath.so.0; do
        [[ -e "$SUPERNOVA_LIB_DIR/$link_name" ]] || die "Supernova runtime library missing: $SUPERNOVA_LIB_DIR/$link_name"
    done
    export LD_LIBRARY_PATH="$SUPERNOVA_LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
}

supernova_python_import_probe() {
    ensure_supernova_runtime_libs
    [[ -x "$SUPERNOVA_PYTHON_BIN" ]] || die "Supernova bundled Python not found: $SUPERNOVA_PYTHON_BIN"
    [[ -d "$SUPERNOVA_TENKIT_PYTHONPATH" ]] || die "Supernova tenkit Python path not found: $SUPERNOVA_TENKIT_PYTHONPATH"

    PYTHONPATH="$SUPERNOVA_TENKIT_PYTHONPATH${PYTHONPATH:+:$PYTHONPATH}" "$SUPERNOVA_PYTHON_BIN" - <<'PY'
import scipy.special
import pysam
import tenkit.bam
print("supernova python imports OK")
PY
}

pseudohap_prefix() {
    local sample_id="$1"
    printf '%s/%s' "$PSEUDOHAP_DIR" "$(assembly_stem "$sample_id")"
}

canonical_pseudohap() {
    local sample_id="$1"
    printf '%s.fasta.gz' "$(pseudohap_prefix "$sample_id")"
}

filtered_fasta() {
    local sample_id="$1"
    printf '%s/%s_filtered.fasta' "$FILTERED_DIR" "$(assembly_stem "$sample_id")"
}

quast_report_tsv() {
    printf '%s/report.tsv' "$QUAST_DIR"
}

busco_sample_dir() {
    local sample_id="$1"
    printf '%s/%s' "$BUSCO_DIR" "$(assembly_stem "$sample_id")"
}

repeatmodeler_workdir() {
    local sample_id="$1"
    printf '%s/%s' "$REPEAT_DATABASE_DIR" "$(assembly_stem "$sample_id")"
}

repeatmodeler_export_fasta() {
    local sample_id="$1"
    printf '%s/%s-classified-families.fa' "$REPEAT_FAMILY_EXPORT_DIR" "$(assembly_stem "$sample_id")"
}

repeatmasker_workdir() {
    local sample_id="$1"
    printf '%s/%s_%s' "$REPEATMASKER_DIR" "$ASSEMBLY_PREFIX" "$sample_id"
}

repeatmasker_final_masked() {
    local sample_id="$1"
    local sample_base
    sample_base="$(basename "$(filtered_fasta "$sample_id")")"
    printf '%s/%s.round4_unknown_repeats.masked' "$(repeatmasker_workdir "$sample_id")" "$sample_base"
}

annotation_sample_name_stem() {
    local sample_id="${1:-$ANNOTATION_SAMPLE_ID}"
    printf '%s_%s' "$ASSEMBLY_PREFIX" "$sample_id"
}

annotation_header_name_stem() {
    local sample_id="${1:-$ANNOTATION_SAMPLE_ID}"

    if [[ "$sample_id" == "$ANNOTATION_SAMPLE_ID" ]]; then
        printf '%s' "$ANNOTATION_HEADER_NAME_STEM"
    else
        printf '%s' "$(annotation_sample_name_stem "$sample_id")"
    fi
}

annotation_genome_base() {
    local sample_id="${1:-$ANNOTATION_SAMPLE_ID}"
    basename "$(filtered_fasta "$sample_id")" .fasta
}

annotation_masked_genome() {
    local sample_id="${1:-$ANNOTATION_SAMPLE_ID}"
    repeatmasker_final_masked "$sample_id"
}

annotation_simplified_genome() {
    local sample_id="${1:-$ANNOTATION_SAMPLE_ID}"
    printf '%s/%s_simplified.fasta' "$ANNOTATION_INPUT_DIR" "$(annotation_genome_base "$sample_id")"
}

annotation_header_map() {
    local sample_id="${1:-$ANNOTATION_SAMPLE_ID}"
    printf '%s/%s_header_map.txt' "$ANNOTATION_INPUT_DIR" "$(annotation_genome_base "$sample_id")"
}

annotation_restored_genome() {
    local sample_id="${1:-$ANNOTATION_SAMPLE_ID}"
    printf '%s/%s_with_original_headers.fasta' "$(annotation_original_headers_dir "$sample_id")" "$(annotation_genome_base "$sample_id")"
}

annotation_sample_output_dir() {
    local sample_id="${1:-$ANNOTATION_SAMPLE_ID}"
    printf '%s/%s' "$ANNOTATION_OUTPUT_DIR" "$sample_id"
}

annotation_original_headers_dir() {
    local sample_id="${1:-$ANNOTATION_SAMPLE_ID}"
    printf '%s/%s' "$ANNOTATION_ORIGINAL_HEADERS_DIR" "$sample_id"
}

annotation_predictor_link() {
    local predictor="$1"
    local sample_id="${2:-$ANNOTATION_SAMPLE_ID}"
    printf '%s/%s_current' "$(annotation_sample_output_dir "$sample_id")" "$predictor"
}

annotation_predictor_runs_dir() {
    local predictor="$1"
    local sample_id="${2:-$ANNOTATION_SAMPLE_ID}"
    printf '%s/%s_runs' "$(annotation_sample_output_dir "$sample_id")" "$predictor"
}

annotation_predictor_gtf() {
    local predictor="$1"
    local sample_id="${2:-$ANNOTATION_SAMPLE_ID}"
    case "$predictor" in
        galba)
            printf '%s/galba.gtf' "$(annotation_predictor_link "$predictor" "$sample_id")"
            ;;
        braker2|braker3)
            printf '%s/%s' "$(annotation_predictor_link "$predictor" "$sample_id")" "$BRAKER_GTF_BASENAME"
            ;;
        *)
            die "Unsupported predictor for GTF lookup: $predictor"
            ;;
    esac
}

annotation_predictor_hints() {
    local predictor="$1"
    local sample_id="${2:-$ANNOTATION_SAMPLE_ID}"
    printf '%s/hintsfile.gff' "$(annotation_predictor_link "$predictor" "$sample_id")"
}

is_supported_tsebra_source() {
    case "$1" in
        galba|braker2|braker3)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

predictor_enable_var() {
    case "$1" in
        galba)
            printf 'ENABLE_GALBA'
            ;;
        braker2)
            printf 'ENABLE_BRAKER2'
            ;;
        braker3)
            printf 'ENABLE_BRAKER3'
            ;;
        *)
            die "Unsupported predictor for enable lookup: $1"
            ;;
    esac
}

annotation_tsebra_runs_dir() {
    local sample_id="${1:-$ANNOTATION_SAMPLE_ID}"
    printf '%s/tsebra_runs' "$(annotation_sample_output_dir "$sample_id")"
}

annotation_tsebra_current_dir() {
    local sample_id="${1:-$ANNOTATION_SAMPLE_ID}"
    printf '%s/tsebra_current' "$(annotation_sample_output_dir "$sample_id")"
}

annotation_tsebra_run_dir() {
    local config_name="$1"
    local sample_id="${2:-$ANNOTATION_SAMPLE_ID}"
    printf '%s/%s' "$(annotation_tsebra_current_dir "$sample_id")" "$config_name"
}

annotation_tsebra_gtf() {
    local config_name="$1"
    local sample_id="${2:-$ANNOTATION_SAMPLE_ID}"
    printf '%s/tsebra_%s.gtf' "$(annotation_tsebra_run_dir "$config_name" "$sample_id")" "$config_name"
}

annotation_tsebra_prefix() {
    local config_name="$1"
    local sample_id="${2:-$ANNOTATION_SAMPLE_ID}"
    printf '%s/tsebra_%s' "$(annotation_tsebra_run_dir "$config_name" "$sample_id")" "$config_name"
}

annotation_isoform_root() {
    local sample_id="${1:-$ANNOTATION_SAMPLE_ID}"
    printf '%s/isoform_filtered_for_omark' "$(annotation_sample_output_dir "$sample_id")"
}

annotation_isoform_dir() {
    local model_name="$1"
    local sample_id="${2:-$ANNOTATION_SAMPLE_ID}"
    printf '%s/%s' "$(annotation_isoform_root "$sample_id")" "$model_name"
}

annotation_isoform_gtf() {
    local model_name="$1"
    local sample_id="${2:-$ANNOTATION_SAMPLE_ID}"
    printf '%s/%s_longest_isoform.gtf' "$(annotation_isoform_dir "$model_name" "$sample_id")" "$model_name"
}

annotation_isoform_prefix() {
    local model_name="$1"
    local sample_id="${2:-$ANNOTATION_SAMPLE_ID}"
    printf '%s/%s' "$(annotation_isoform_dir "$model_name" "$sample_id")" "$model_name"
}

annotation_isoform_aa() {
    local model_name="$1"
    local sample_id="${2:-$ANNOTATION_SAMPLE_ID}"
    printf '%s.aa' "$(annotation_isoform_prefix "$model_name" "$sample_id")"
}

annotation_interproscan_run_dir() {
    local sample_id="${1:-$ANNOTATION_SAMPLE_ID}"
    printf '%s/%s/%s' "$INTERPROSCAN_OUTPUT_DIR" "$sample_id" "$INTERPROSCAN_RUN_NAME"
}

known_repeat_library() {
    printf '%s/non_redundant_repeats.known_filtered.fa' "$REPEAT_LIBRARY_DIR"
}

unknown_repeat_library() {
    printf '%s/non_redundant_repeats.unknown_filtered.fa' "$REPEAT_LIBRARY_DIR"
}

sample_array_bounds() {
    local count
    count="$(sample_count)"
    (( count > 0 )) || die "No samples were found in $SAMPLES_TSV"
    printf '0-%d' "$((count - 1))"
}

annotation_sample_count() {
    case "${ANNOTATION_SAMPLE_MODE:-single}" in
        all)
            sample_count
            ;;
        single)
            printf '1\n'
            ;;
        *)
            die "Unsupported ANNOTATION_SAMPLE_MODE: ${ANNOTATION_SAMPLE_MODE:-}"
            ;;
    esac
}

annotation_sample_array_bounds() {
    local count
    count="$(annotation_sample_count)"
    (( count > 0 )) || die "No annotation samples were found."
    printf '0-%d' "$((count - 1))"
}

annotation_sample_id_by_index() {
    local index="$1"

    case "${ANNOTATION_SAMPLE_MODE:-single}" in
        all)
            sample_id_by_index "$index"
            ;;
        single)
            [[ "$index" == "0" ]] || die "Single annotation mode only supports array index 0."
            printf '%s\n' "$ANNOTATION_SAMPLE_ID"
            ;;
        *)
            die "Unsupported ANNOTATION_SAMPLE_MODE: ${ANNOTATION_SAMPLE_MODE:-}"
            ;;
    esac
}

current_annotation_sample_id() {
    local index="${SLURM_ARRAY_TASK_ID:-0}"
    annotation_sample_id_by_index "$index"
}

braker3_bam_glob_for_sample() {
    local sample_id="$1"
    local glob_template="$BRAKER3_BAM_GLOB_TEMPLATE"
    local stem

    if [[ "${ANNOTATION_SAMPLE_MODE:-single}" == "single" && -n "${BRAKER3_BAM_GLOB:-}" ]]; then
        printf '%s\n' "$BRAKER3_BAM_GLOB"
        return 0
    fi

    stem="$(assembly_stem "$sample_id")"
    glob_template="${glob_template//\{sample_id\}/$sample_id}"
    glob_template="${glob_template//\{assembly_stem\}/$stem}"
    printf '%s\n' "$glob_template"
}

rna_align_sample_bam_dir() {
    local sample_id="$1"
    printf '%s/%s' "$RNA_ALIGN_BAM_DIR" "$sample_id"
}

rna_align_sample_log_dir() {
    local sample_id="$1"
    printf '%s/%s' "$RNA_ALIGN_LOG_DIR" "$sample_id"
}

rna_align_sample_tmp_dir() {
    local sample_id="$1"
    printf '%s/%s' "$RNA_ALIGN_TMP_DIR" "$sample_id"
}

rna_align_sample_index_dir() {
    local sample_id="$1"
    printf '%s/%s' "$RNA_ALIGN_INDEX_DIR" "$sample_id"
}

rna_align_index_prefix() {
    local sample_id="$1"
    printf '%s/%s_hisat2_index' "$(rna_align_sample_index_dir "$sample_id")" "$sample_id"
}

rna_align_fastq_r1() {
    local library_id="$1"
    printf '%s/%s%s' "$RNA_ALIGN_FASTQ_DIR" "$library_id" "$RNA_ALIGN_R1_SUFFIX"
}

rna_align_fastq_r2() {
    local library_id="$1"
    printf '%s/%s%s' "$RNA_ALIGN_FASTQ_DIR" "$library_id" "$RNA_ALIGN_R2_SUFFIX"
}

rna_align_bam() {
    local sample_id="$1"
    local library_id="$2"
    printf '%s/%s_aligned_sorted.bam' "$(rna_align_sample_bam_dir "$sample_id")" "$library_id"
}

rna_align_flagstat() {
    local sample_id="$1"
    local library_id="$2"
    printf '%s/%s_alignment_stats.txt' "$(rna_align_sample_log_dir "$sample_id")" "$library_id"
}

rna_align_hisat2_log() {
    local sample_id="$1"
    local library_id="$2"
    printf '%s/%s_hisat2.log' "$(rna_align_sample_log_dir "$sample_id")" "$library_id"
}

assert_softmasked_fasta() {
    local fasta_file="$1"
    local lower_count

    [[ -f "$fasta_file" ]] || die "Softmask check input not found: $fasta_file"
    lower_count="$(awk '
        /^>/ { next }
        {
            for (i = 1; i <= length($0); i++) {
                c = substr($0, i, 1)
                if (c ~ /[acgtn]/) {
                    count++
                }
            }
        }
        END { print count + 0 }
    ' "$fasta_file")"

    (( lower_count > 0 )) || die "Genome FASTA has no lowercase bases; expected softmasked RepeatMasker output: $fasta_file"
}

count_fasta_records() {
    local fasta_file="$1"
    awk '/^>/{count++} END{print count + 0}' "$fasta_file"
}

load_module_support() {
    if command -v module >/dev/null 2>&1; then
        return 0
    fi

    if [[ -f /etc/profile.d/modules.sh ]]; then
        # shellcheck disable=SC1091
        source /etc/profile.d/modules.sh
        return 0
    fi

    if [[ -f /usr/share/Modules/init/bash ]]; then
        # shellcheck disable=SC1091
        source /usr/share/Modules/init/bash
        return 0
    fi

    return 1
}

load_anaconda() {
    if [[ -n "${ANACONDA_MODULE:-}" ]]; then
        load_module_support || die "The module command is not available, but ANACONDA_MODULE is set."
        module load "$ANACONDA_MODULE" >/dev/null
    fi

    if [[ -n "${ANACONDA_SH:-}" && -f "${ANACONDA_SH:-}" ]]; then
        # shellcheck disable=SC1090
        source "$ANACONDA_SH"
        return 0
    fi

    if command -v conda >/dev/null 2>&1; then
        eval "$(conda shell.bash hook)"
        return 0
    fi

    die "Unable to initialize conda. Set ANACONDA_SH or ensure conda is already on PATH."
}

activate_conda_env() {
    local env_name="$1"
    local env_prefix="${2:-}"
    load_anaconda

    if [[ -n "$env_prefix" && -d "$env_prefix" ]]; then
        conda activate "$env_prefix"
        return 0
    fi

    conda activate "$env_name"
}

load_module_if_available() {
    local module_name="$1"
    [[ -n "$module_name" ]] || return 0
    load_module_support || die "The module command is not available, but a module was requested: $module_name"
    module load "$module_name" >/dev/null
}

activate_quast_env() {
    if [[ -n "${QUAST_ENV_PREFIX:-}" && -d "${QUAST_ENV_PREFIX:-}" ]]; then
        [[ -f "$QUAST_ENV_PREFIX/bin/activate" ]] || die "QUAST activate script not found: $QUAST_ENV_PREFIX/bin/activate"
        # shellcheck disable=SC1090
        source "$QUAST_ENV_PREFIX/bin/activate"

        if [[ -x "$QUAST_ENV_PREFIX/bin/quast.py" ]]; then
            QUAST_BIN="$QUAST_ENV_PREFIX/bin/quast.py"
        fi
    elif [[ -n "${QUAST_VENV_ACTIVATE:-}" && -f "${QUAST_VENV_ACTIVATE:-}" ]]; then
        [[ -f "$QUAST_VENV_ACTIVATE" ]] || die "QUAST activate script not found: $QUAST_VENV_ACTIVATE"
        # shellcheck disable=SC1090
        source "$QUAST_VENV_ACTIVATE"
    else
        activate_conda_env "${QUAST_ENV:-quast_env}" "${QUAST_ENV_PREFIX:-}"
    fi

    if resolved_quast_bin="$(resolve_command_path "${QUAST_BIN:-}")"; then
        QUAST_BIN="$resolved_quast_bin"
        return 0
    fi

    if resolved_quast_bin="$(resolve_command_path quast.py)"; then
        QUAST_BIN="$resolved_quast_bin"
        return 0
    fi

    die "QUAST executable not found: ${QUAST_BIN:-quast.py}"
}

resolve_ncbi_datasets_bin() {
    if [[ -n "${DATASETS_ENV_PREFIX:-}" && -x "${DATASETS_ENV_PREFIX:-}/bin/datasets" ]]; then
        printf '%s\n' "$DATASETS_ENV_PREFIX/bin/datasets"
    elif [[ -n "${NCBI_DATASETS_BIN:-}" && "${NCBI_DATASETS_BIN:-}" != "datasets" && -x "${NCBI_DATASETS_BIN:-}" ]]; then
        printf '%s\n' "$NCBI_DATASETS_BIN"
    elif command -v datasets >/dev/null 2>&1; then
        printf 'datasets\n'
    else
        printf '%s\n' "$NCBI_DATASETS_BIN"
    fi
}
