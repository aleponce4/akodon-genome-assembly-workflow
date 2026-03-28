#!/usr/bin/env bash
# Stage 10: mask filtered assemblies with Dfam and the custom repeat libraries.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="${1:-${CONFIG:-}}"

# shellcheck source=../scripts/lib/common.sh
source "$SCRIPT_DIR/../scripts/lib/common.sh"
source_config "$CONFIG_PATH"
ensure_base_dirs

rename_repeatmasker_outputs() {
    local output_dir="$1"
    local source_base="$2"
    local target_base="$3"

    mv "$output_dir/$source_base.cat" "$output_dir/$target_base.cat"
    mv "$output_dir/$source_base.masked" "$output_dir/$target_base.masked"
    mv "$output_dir/$source_base.out" "$output_dir/$target_base.out"
    mv "$output_dir/$source_base.tbl" "$output_dir/$target_base.tbl"
}

skip_library_round() {
    local input_masked="$1"
    local target_base="$2"
    local note="$3"

    cp -f "$input_masked" "$masker_output_dir/$target_base.masked"
    printf '%s\n' "$note" > "$masker_output_dir/$target_base.skipped.txt"
}

sample_index="${SLURM_ARRAY_TASK_ID:?SLURM_ARRAY_TASK_ID is required}"
sample_id="$(sample_id_by_index "$sample_index")"
input_fasta="$(filtered_fasta "$sample_id")"
sample_base="$(basename "$input_fasta")"
masker_output_dir="$(repeatmasker_workdir "$sample_id")"
known_repeats="$(known_repeat_library)"
unknown_repeats="$(unknown_repeat_library)"
repeatmasker_threads="${SLURM_CPUS_PER_TASK:-$REPEATMASKER_CPUS}"

ensure_dir "$masker_output_dir"

if smoke_mode; then
    log "Smoke mode: creating mock RepeatMasker outputs"
    for round_name in round1_simple_dfam round2_complex_dfam round3_known_repeats round4_unknown_repeats; do
        printf 'cat\n' > "$masker_output_dir/$sample_base.${round_name}.cat"
        write_smoke_fasta "$masker_output_dir/$sample_base.${round_name}.masked" "${sample_base}_${round_name}" "atgcgtatgcgtatgcgtatgcgtatgcgt"
        printf 'out\n' > "$masker_output_dir/$sample_base.${round_name}.out"
        printf 'tbl\n' > "$masker_output_dir/$sample_base.${round_name}.tbl"
    done
    final_masked_output="$(repeatmasker_final_masked "$sample_id")"
    [[ -e "$final_masked_output" ]] || die "RepeatMasker final masked output was not created: $final_masked_output"
    exit 0
fi

[[ -f "$input_fasta" ]] || die "Filtered FASTA not found: $input_fasta"
[[ -f "$REPEATMODELER_IMAGE" ]] || die "RepeatMasker image not found: $REPEATMODELER_IMAGE"
command -v "$SINGULARITY_BIN" >/dev/null 2>&1 || die "Singularity executable not found: $SINGULARITY_BIN"

log "RepeatMasker round 1 for sample $sample_id"
"$SINGULARITY_BIN" exec "$REPEATMODELER_IMAGE" RepeatMasker \
    -pa "$repeatmasker_threads" \
    -noint \
    -xsmall \
    -species "$REPEATMASKER_SPECIES" \
    -dir "$masker_output_dir" \
    "$input_fasta"
rename_repeatmasker_outputs "$masker_output_dir" "$sample_base" "$sample_base.round1_simple_dfam"

round2_input="$masker_output_dir/$sample_base.round1_simple_dfam.masked"
round2_source="$(basename "$round2_input")"

log "RepeatMasker round 2 for sample $sample_id"
"$SINGULARITY_BIN" exec "$REPEATMODELER_IMAGE" RepeatMasker \
    -pa "$repeatmasker_threads" \
    -nolow \
    -xsmall \
    -species "$REPEATMASKER_SPECIES" \
    -dir "$masker_output_dir" \
    "$round2_input"
rename_repeatmasker_outputs "$masker_output_dir" "$round2_source" "$sample_base.round2_complex_dfam"

round3_input="$masker_output_dir/$sample_base.round2_complex_dfam.masked"
round3_source="$(basename "$round3_input")"
round3_target="$sample_base.round3_known_repeats"

if [[ -s "$known_repeats" ]]; then
    log "RepeatMasker round 3 for sample $sample_id"
    "$SINGULARITY_BIN" exec "$REPEATMODELER_IMAGE" RepeatMasker \
        -pa "$repeatmasker_threads" \
        -xsmall \
        -lib "$known_repeats" \
        -dir "$masker_output_dir" \
        "$round3_input"
    rename_repeatmasker_outputs "$masker_output_dir" "$round3_source" "$round3_target"
else
    log "Skipping RepeatMasker round 3 because the known repeat library is empty"
    skip_library_round "$round3_input" "$round3_target" "Known repeat library was empty; round skipped."
fi

round4_input="$masker_output_dir/$round3_target.masked"
round4_source="$(basename "$round4_input")"
round4_target="$sample_base.round4_unknown_repeats"

if [[ -s "$unknown_repeats" ]]; then
    log "RepeatMasker round 4 for sample $sample_id"
    "$SINGULARITY_BIN" exec "$REPEATMODELER_IMAGE" RepeatMasker \
        -pa "$repeatmasker_threads" \
        -xsmall \
        -lib "$unknown_repeats" \
        -dir "$masker_output_dir" \
        "$round4_input"
    rename_repeatmasker_outputs "$masker_output_dir" "$round4_source" "$round4_target"
else
    log "Skipping RepeatMasker round 4 because the unknown repeat library is empty"
    skip_library_round "$round4_input" "$round4_target" "Unknown repeat library was empty; round skipped."
fi

final_masked_output="$(repeatmasker_final_masked "$sample_id")"
[[ -e "$final_masked_output" ]] || die "RepeatMasker final masked output was not created: $final_masked_output"
