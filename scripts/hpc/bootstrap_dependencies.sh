#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MODE="${1:-probe}"
CONFIG_PATH="${2:-$PROJECT_ROOT/config/bootstrap.env}"

# shellcheck source=../lib/common.sh
source "$PROJECT_ROOT/scripts/lib/common.sh"
source_config "$CONFIG_PATH"

ensure_dir "$BOOTSTRAP_DIR"
ensure_dir "$BOOTSTRAP_CACHE_DIR"

manual_actions=()
failed_actions=()

init_report() {
    printf 'dependency\tstatus\tpath\tdetail\n' > "$BOOTSTRAP_STATUS_TSV"
    : > "$BOOTSTRAP_SUMMARY_TXT"
}

record_status() {
    local dependency="$1"
    local status="$2"
    local path_value="${3:-}"
    local detail="${4:-}"

    printf '%s\t%s\t%s\t%s\n' "$dependency" "$status" "$path_value" "$detail" >> "$BOOTSTRAP_STATUS_TSV"
    printf '%-28s %-16s %s\n' "$dependency" "$status" "$detail" >> "$BOOTSTRAP_SUMMARY_TXT"

    case "$status" in
        manual_required)
            manual_actions+=("$dependency: $detail")
            ;;
        failed)
            failed_actions+=("$dependency: $detail")
            ;;
    esac
}

print_report() {
    cat "$BOOTSTRAP_SUMMARY_TXT"

    if (( ${#manual_actions[@]} > 0 )); then
        printf '\nManual follow-up required:\n'
        printf '  - %s\n' "${manual_actions[@]}"
    fi

    if (( ${#failed_actions[@]} > 0 )); then
        printf '\nFailed items:\n'
        printf '  - %s\n' "${failed_actions[@]}"
    fi
}

find_download_tool() {
    if command -v curl >/dev/null 2>&1; then
        printf 'curl\n'
        return 0
    fi

    if command -v wget >/dev/null 2>&1; then
        printf 'wget\n'
        return 0
    fi

    return 1
}

download_url() {
    local url="$1"
    local output_file="$2"
    local tool

    tool="$(find_download_tool)" || return 1
    ensure_dir "$(dirname "$output_file")"

    case "$tool" in
        curl)
            curl -fsSL "$url" -o "$output_file"
            ;;
        wget)
            wget -qO "$output_file" "$url"
            ;;
    esac
}

container_runtime_bin() {
    if command -v "${SINGULARITY_BIN:-}" >/dev/null 2>&1; then
        printf '%s\n' "$SINGULARITY_BIN"
        return 0
    fi

    if command -v apptainer >/dev/null 2>&1; then
        printf 'apptainer\n'
        return 0
    fi

    if command -v singularity >/dev/null 2>&1; then
        printf 'singularity\n'
        return 0
    fi

    return 1
}

conda_solver_bin() {
    load_anaconda

    if command -v mamba >/dev/null 2>&1; then
        printf 'mamba\n'
    else
        printf 'conda\n'
    fi
}

path_is_url() {
    [[ "$1" == http://* || "$1" == https://* ]]
}

path_is_container_uri() {
    case "$1" in
        docker://*|library://*|oras://*|shub://*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

stage_file_asset() {
    local dependency="$1"
    local source_path="$2"
    local destination="$3"

    if [[ -f "$destination" ]]; then
        record_status "$dependency" "present" "$destination" "Already present."
        return 0
    fi

    if [[ -z "$source_path" ]]; then
        record_status "$dependency" "manual_required" "$destination" "No source configured."
        return 0
    fi

    ensure_dir "$(dirname "$destination")"

    if [[ -f "$source_path" ]]; then
        cp -f "$source_path" "$destination"
        record_status "$dependency" "installed" "$destination" "Copied from local source."
        return 0
    fi

    if path_is_url "$source_path"; then
        if download_url "$source_path" "$destination"; then
            record_status "$dependency" "installed" "$destination" "Downloaded from $source_path."
        else
            record_status "$dependency" "failed" "$destination" "Download failed for $source_path."
            return 1
        fi
        return 0
    fi

    record_status "$dependency" "failed" "$destination" "Unsupported source: $source_path"
    return 1
}

extract_archive_to_directory() {
    local archive_file="$1"
    local destination_dir="$2"
    local temp_extract
    local archive_basename

    temp_extract="$(mktemp -d "$BOOTSTRAP_CACHE_DIR/extract.XXXXXX")"
    archive_basename="$(basename "$archive_file")"

    case "$archive_basename" in
        *.tar.gz|*.tgz)
            tar -xzf "$archive_file" -C "$temp_extract"
            ;;
        *.tar)
            tar -xf "$archive_file" -C "$temp_extract"
            ;;
        *.zip)
            unzip -q "$archive_file" -d "$temp_extract"
            ;;
        *)
            rm -rf "$temp_extract"
            return 1
            ;;
    esac

    if [[ -d "$temp_extract/$(basename "$destination_dir")" ]]; then
        mkdir -p "$(dirname "$destination_dir")"
        cp -a "$temp_extract/$(basename "$destination_dir")" "$destination_dir"
    else
        mapfile -t extracted_dirs < <(find "$temp_extract" -mindepth 1 -maxdepth 1 -type d | sort)
        if (( ${#extracted_dirs[@]} == 1 )); then
            mkdir -p "$(dirname "$destination_dir")"
            cp -a "${extracted_dirs[0]}" "$destination_dir"
        else
            mkdir -p "$destination_dir"
            cp -a "$temp_extract"/. "$destination_dir"/
        fi
    fi

    rm -rf "$temp_extract"
}

stage_directory_asset() {
    local dependency="$1"
    local source_path="$2"
    local destination_dir="$3"
    local required_marker="$4"
    local cached_archive

    if [[ -e "$required_marker" ]]; then
        record_status "$dependency" "present" "$destination_dir" "Already present."
        return 0
    fi

    if [[ -z "$source_path" ]]; then
        record_status "$dependency" "manual_required" "$destination_dir" "No source configured."
        return 0
    fi

    if [[ -d "$source_path" ]]; then
        mkdir -p "$destination_dir"
        cp -a "$source_path"/. "$destination_dir"/
        record_status "$dependency" "installed" "$destination_dir" "Copied directory from local source."
        return 0
    fi

    if [[ -f "$source_path" ]]; then
        if extract_archive_to_directory "$source_path" "$destination_dir"; then
            record_status "$dependency" "installed" "$destination_dir" "Extracted local archive."
        else
            record_status "$dependency" "failed" "$destination_dir" "Unsupported archive format: $source_path"
            return 1
        fi
        return 0
    fi

    if path_is_url "$source_path"; then
        cached_archive="$BOOTSTRAP_CACHE_DIR/$(basename "$source_path")"
        if ! download_url "$source_path" "$cached_archive"; then
            record_status "$dependency" "failed" "$destination_dir" "Download failed for $source_path."
            return 1
        fi

        if extract_archive_to_directory "$cached_archive" "$destination_dir"; then
            record_status "$dependency" "installed" "$destination_dir" "Downloaded and extracted archive."
        else
            record_status "$dependency" "failed" "$destination_dir" "Unsupported archive format: $source_path"
            return 1
        fi
        return 0
    fi

    record_status "$dependency" "failed" "$destination_dir" "Unsupported source: $source_path"
    return 1
}

stage_container_asset() {
    local dependency="$1"
    local source_path="$2"
    local destination="$3"
    local runtime

    if [[ -f "$destination" ]]; then
        record_status "$dependency" "present" "$destination" "Already present."
        return 0
    fi

    if [[ -z "$source_path" ]]; then
        record_status "$dependency" "manual_required" "$destination" "No source configured."
        return 0
    fi

    ensure_dir "$(dirname "$destination")"

    if [[ -f "$source_path" ]]; then
        cp -f "$source_path" "$destination"
        record_status "$dependency" "installed" "$destination" "Copied local image."
        return 0
    fi

    if path_is_url "$source_path"; then
        if download_url "$source_path" "$destination"; then
            record_status "$dependency" "installed" "$destination" "Downloaded image from $source_path."
        else
            record_status "$dependency" "failed" "$destination" "Download failed for $source_path."
            return 1
        fi
        return 0
    fi

    if path_is_container_uri "$source_path"; then
        runtime="$(container_runtime_bin)" || {
            record_status "$dependency" "failed" "$destination" "No Singularity/Apptainer runtime available."
            return 1
        }

        if "$runtime" pull "$destination" "$source_path"; then
            record_status "$dependency" "installed" "$destination" "Pulled image from $source_path."
        else
            record_status "$dependency" "failed" "$destination" "Container pull failed for $source_path."
            return 1
        fi
        return 0
    fi

    record_status "$dependency" "failed" "$destination" "Unsupported source: $source_path"
    return 1
}

ensure_conda_env() {
    local dependency="$1"
    local env_prefix="$2"
    local expected_binary="$3"
    local package_list="$4"
    local solver

    if [[ -x "$expected_binary" ]]; then
        record_status "$dependency" "present" "$env_prefix" "Environment already present."
        return 0
    fi

    solver="$(conda_solver_bin)"
    IFS=' ' read -r -a packages <<< "$package_list"
    ensure_dir "$(dirname "$env_prefix")"

    if "$solver" create -y -p "$env_prefix" -c conda-forge -c bioconda "${packages[@]}"; then
        record_status "$dependency" "installed" "$env_prefix" "Created repo-local environment."
    else
        record_status "$dependency" "failed" "$env_prefix" "Conda environment creation failed."
        return 1
    fi
}

ensure_busco_lineage() {
    local download_root
    local busco_bin

    if [[ -d "$BUSCO_LINEAGE_DIR" ]]; then
        record_status "busco_lineage" "present" "$BUSCO_LINEAGE_DIR" "Lineage already present."
        return 0
    fi

    if [[ ! -x "$BUSCO_ENV_PREFIX/bin/busco" ]]; then
        record_status "busco_lineage" "failed" "$BUSCO_LINEAGE_DIR" "BUSCO environment is required before lineage download."
        return 1
    fi

    download_root="$(dirname "$(dirname "$BUSCO_LINEAGE_DIR")")"
    busco_bin="$BUSCO_ENV_PREFIX/bin/busco"
    ensure_dir "$download_root"

    if "$busco_bin" --download_path "$download_root" --download "$BUSCO_LINEAGE_NAME"; then
        record_status "busco_lineage" "installed" "$BUSCO_LINEAGE_DIR" "Downloaded lineage with BUSCO."
    else
        record_status "busco_lineage" "failed" "$BUSCO_LINEAGE_DIR" "BUSCO lineage download failed."
        return 1
    fi
}

report_path_status() {
    local dependency="$1"
    local target_path="$2"
    local detail_present="$3"
    local detail_missing="$4"

    if [[ -e "$target_path" ]]; then
        record_status "$dependency" "present" "$target_path" "$detail_present"
    else
        record_status "$dependency" "manual_required" "$target_path" "$detail_missing"
    fi
}

report_glob_status() {
    local dependency="$1"
    local glob_pattern="$2"
    local detail_present="$3"
    local detail_missing="$4"

    if compgen -G "$glob_pattern" >/dev/null 2>&1; then
        record_status "$dependency" "present" "$glob_pattern" "$detail_present"
    else
        record_status "$dependency" "manual_required" "$glob_pattern" "$detail_missing"
    fi
}

report_command_status() {
    local dependency="$1"
    local command_path="$2"
    local detail_present="$3"
    local detail_missing="$4"

    if command -v "$command_path" >/dev/null 2>&1; then
        record_status "$dependency" "present" "$command_path" "$detail_present"
    else
        record_status "$dependency" "manual_required" "$command_path" "$detail_missing"
    fi
}

run_probe() {
    local download_tool
    local runtime

    if download_tool="$(find_download_tool)"; then
        record_status "download_tool" "present" "$download_tool" "Download helper available."
    else
        record_status "download_tool" "failed" "" "Neither curl nor wget is available."
    fi

    if load_module_support; then
        record_status "module_support" "present" "module" "Environment modules are available."
    else
        record_status "module_support" "manual_required" "module" "Module support is not initialized on this node."
    fi

    if command -v conda >/dev/null 2>&1 || command -v mamba >/dev/null 2>&1; then
        record_status "conda_solver" "present" "$(command -v mamba || command -v conda)" "Conda solver available on PATH."
    elif [[ -n "${ANACONDA_SH:-}" && -f "${ANACONDA_SH:-}" ]]; then
        record_status "conda_solver" "present" "$ANACONDA_SH" "Configured Anaconda init script is available."
    elif [[ -n "${ANACONDA_MODULE:-}" ]] && load_module_support; then
        record_status "conda_solver" "present" "$ANACONDA_MODULE" "Configured Anaconda module can be loaded."
    else
        record_status "conda_solver" "manual_required" "" "Conda is not available yet; bootstrap install will need it."
    fi

    if runtime="$(container_runtime_bin)"; then
        record_status "container_runtime" "present" "$runtime" "Container runtime available."
    else
        record_status "container_runtime" "manual_required" "" "Singularity/Apptainer is not available on this node."
    fi

    if find_download_tool >/dev/null 2>&1; then
        if download_url "https://ftp.ncbi.nlm.nih.gov/README.ftp" "$BOOTSTRAP_CACHE_DIR/.internet_probe"; then
            rm -f "$BOOTSTRAP_CACHE_DIR/.internet_probe"
            record_status "internet_access" "present" "https://ftp.ncbi.nlm.nih.gov" "Internet download probe succeeded."
        else
            record_status "internet_access" "manual_required" "" "Outbound HTTP(S) probe failed."
        fi
    else
        record_status "internet_access" "manual_required" "" "No download tool available for probe."
    fi

    for target_dir in "$CONDA_ENV_ROOT" "$(dirname "$BUSCO_LINEAGE_DIR")" "$(dirname "$BRAKER_SIF")" "$(dirname "$INTERPROSCAN_SIF")"; do
        if mkdir -p "$target_dir" 2>/dev/null; then
            record_status "writable:$(basename "$target_dir")" "present" "$target_dir" "Writable target directory."
        else
            record_status "writable:$(basename "$target_dir")" "failed" "$target_dir" "Target directory is not writable."
        fi
    done
}

run_install() {
    ensure_conda_env "filter_env" "$FILTER_ENV_PREFIX" "$FILTER_ENV_PREFIX/bin/seqkit" "$FILTER_CONDA_PACKAGES"
    ensure_conda_env "busco_env" "$BUSCO_ENV_PREFIX" "$BUSCO_ENV_PREFIX/bin/busco" "$BUSCO_CONDA_PACKAGES"
    ensure_conda_env "multiqc_env" "$MULTIQC_ENV_PREFIX" "$MULTIQC_ENV_PREFIX/bin/multiqc" "$MULTIQC_CONDA_PACKAGES"
    ensure_conda_env "repeat_env" "$REPEAT_ENV_PREFIX" "$REPEAT_ENV_PREFIX/bin/cd-hit-est" "$REPEAT_CONDA_PACKAGES"
    ensure_conda_env "quast_env" "$QUAST_ENV_PREFIX" "$QUAST_ENV_PREFIX/bin/quast.py" "$QUAST_CONDA_PACKAGES"
    ensure_conda_env "datasets_env" "$DATASETS_ENV_PREFIX" "$DATASETS_ENV_PREFIX/bin/datasets" "$DATASETS_CONDA_PACKAGES"

    stage_file_asset "header_simplifier" "$HEADER_SIMPLIFIER_SOURCE" "$GENOME_HEADER_SIMPLIFIER"
    stage_file_asset "longest_isoform_script" "$LONGEST_ISOFORM_SCRIPT_SOURCE" "$ANNOTATION_LONGEST_ISOFORM_SCRIPT"

    ensure_busco_lineage

    stage_container_asset "repeatmodeler_image" "$REPEATMODELER_IMAGE_SOURCE" "$REPEATMODELER_IMAGE"
    stage_container_asset "braker_image" "$BRAKER_IMAGE_SOURCE" "$BRAKER_SIF"
    stage_container_asset "galba_image" "$GALBA_IMAGE_SOURCE" "$GALBA_SIF"
    stage_container_asset "interproscan_image" "$INTERPROSCAN_IMAGE_SOURCE" "$INTERPROSCAN_SIF"

    if [[ -x "$SUPERNOVA_BIN" ]]; then
        record_status "supernova" "present" "$SUPERNOVA_BIN" "Supernova executable already present."
    elif [[ -n "$SUPERNOVA_MANUAL_PATH" ]]; then
        stage_directory_asset "supernova" "$SUPERNOVA_MANUAL_PATH" "$(dirname "$SUPERNOVA_BIN")" "$SUPERNOVA_BIN"
    elif [[ -n "$SUPERNOVA_ARCHIVE_SOURCE" ]]; then
        stage_directory_asset "supernova" "$SUPERNOVA_ARCHIVE_SOURCE" "$(dirname "$SUPERNOVA_BIN")" "$SUPERNOVA_BIN"
    else
        record_status "supernova" "manual_required" "$SUPERNOVA_BIN" "Provide SUPERNOVA_MANUAL_PATH or SUPERNOVA_ARCHIVE_SOURCE."
    fi

    stage_directory_asset "interproscan_data" "$INTERPROSCAN_DATA_ARCHIVE_SOURCE" "$INTERPROSCAN_DATA_DIR" "$INTERPROSCAN_DATA_DIR/data"

    if compgen -G "$TSEBRA_CONFIG_GLOB" >/dev/null 2>&1; then
        record_status "tsebra_configs" "present" "$TSEBRA_CONFIG_GLOB" "TSEBRA config files already present."
    elif [[ -d "$TSEBRA_CONFIG_SOURCE_DIR" ]]; then
        ensure_dir "$ANNOTATION_INPUT_DIR"
        cp -a "$TSEBRA_CONFIG_SOURCE_DIR"/. "$ANNOTATION_INPUT_DIR"/
        record_status "tsebra_configs" "installed" "$TSEBRA_CONFIG_GLOB" "Copied TSEBRA config files from local source directory."
    elif [[ -n "${TSEBRA_CONFIG_1_SOURCE:-}" || -n "${TSEBRA_CONFIG_2_SOURCE:-}" || -n "${TSEBRA_CONFIG_3_SOURCE:-}" ]]; then
        ensure_dir "$ANNOTATION_INPUT_DIR"
        stage_file_asset "tsebra_config_1" "${TSEBRA_CONFIG_1_SOURCE:-}" "$ANNOTATION_INPUT_DIR/tsebra_config_1.cfg"
        stage_file_asset "tsebra_config_2" "${TSEBRA_CONFIG_2_SOURCE:-}" "$ANNOTATION_INPUT_DIR/tsebra_config_2.cfg"
        stage_file_asset "tsebra_config_3" "${TSEBRA_CONFIG_3_SOURCE:-}" "$ANNOTATION_INPUT_DIR/tsebra_config_3.cfg"
        if compgen -G "$TSEBRA_CONFIG_GLOB" >/dev/null 2>&1; then
            record_status "tsebra_configs" "installed" "$TSEBRA_CONFIG_GLOB" "Downloaded configured TSEBRA config files."
        else
            report_glob_status "tsebra_configs" "$TSEBRA_CONFIG_GLOB" "TSEBRA config files are present." "TSEBRA config files still need manual staging."
        fi
    else
        report_glob_status "tsebra_configs" "$TSEBRA_CONFIG_GLOB" "TSEBRA config files are present." "TSEBRA config files still need manual staging."
    fi

    if [[ -n "$BRAKER3_PROTEIN_FASTA_SOURCE" ]]; then
        stage_file_asset "braker3_proteins" "$BRAKER3_PROTEIN_FASTA_SOURCE" "$BRAKER3_PROTEIN_FASTA"
    else
        report_path_status "braker3_proteins" "$BRAKER3_PROTEIN_FASTA" "Protein FASTA already present." "BRAKER3/GALBA protein FASTA still needs manual staging."
    fi

    if [[ -n "$NCBI_DATASETS_TSV_SOURCE" ]]; then
        stage_file_asset "ncbi_dataset_tsv" "$NCBI_DATASETS_TSV_SOURCE" "$NCBI_DATASETS_TSV"
    else
        report_path_status "ncbi_dataset_tsv" "$NCBI_DATASETS_TSV" "NCBI datasets TSV already present." "Annotation download manifest still needs manual staging."
    fi
}

run_verify() {
    report_path_status "filter_env" "$FILTER_ENV_PREFIX/bin/seqkit" "Filter environment executable found." "Repo-local filter environment is missing."
    report_path_status "busco_env" "$BUSCO_ENV_PREFIX/bin/busco" "BUSCO executable found." "Repo-local BUSCO environment is missing."
    report_path_status "multiqc_env" "$MULTIQC_ENV_PREFIX/bin/multiqc" "MultiQC executable found." "Repo-local MultiQC environment is missing."
    report_path_status "repeat_env" "$REPEAT_ENV_PREFIX/bin/cd-hit-est" "Repeat helper executable found." "Repo-local repeat environment is missing."
    report_path_status "quast_env" "$QUAST_ENV_PREFIX/bin/quast.py" "QUAST executable found." "Repo-local QUAST environment is missing."
    report_command_status "datasets_env" "$(resolve_ncbi_datasets_bin)" "NCBI datasets CLI found." "NCBI datasets CLI is missing."
    report_path_status "header_simplifier" "$GENOME_HEADER_SIMPLIFIER" "Header simplifier found." "Header simplifier is missing."
    report_path_status "longest_isoform_script" "$ANNOTATION_LONGEST_ISOFORM_SCRIPT" "Longest isoform script found." "Longest isoform helper is missing."
    report_path_status "busco_lineage" "$BUSCO_LINEAGE_DIR" "BUSCO lineage found." "BUSCO lineage data is missing."
    report_path_status "supernova" "$SUPERNOVA_BIN" "Supernova executable found." "Supernova still needs manual staging."
    report_path_status "repeatmodeler_image" "$REPEATMODELER_IMAGE" "RepeatModeler image found." "RepeatModeler image is missing."
    report_path_status "braker_image" "$BRAKER_SIF" "BRAKER image found." "BRAKER image is missing."
    report_path_status "galba_image" "$GALBA_SIF" "GALBA image found." "GALBA image is missing."
    report_path_status "interproscan_image" "$INTERPROSCAN_SIF" "InterProScan image found." "InterProScan image is missing."
    report_path_status "interproscan_data" "$INTERPROSCAN_DATA_DIR/data" "InterProScan data found." "InterProScan data is missing."
    report_glob_status "tsebra_configs" "$TSEBRA_CONFIG_GLOB" "TSEBRA config files are present." "TSEBRA config files still need manual staging."
    report_path_status "braker3_proteins" "$BRAKER3_PROTEIN_FASTA" "Protein FASTA found." "BRAKER3/GALBA protein FASTA is missing."
    report_path_status "ncbi_dataset_tsv" "$NCBI_DATASETS_TSV" "NCBI datasets TSV found." "Annotation download manifest is missing."
}

init_report

case "$MODE" in
    probe)
        run_probe
        ;;
    install)
        run_install
        ;;
    verify)
        run_verify
        ;;
    *)
        die "Unsupported bootstrap mode: $MODE"
        ;;
esac

print_report

if (( ${#failed_actions[@]} > 0 )); then
    exit 1
fi
