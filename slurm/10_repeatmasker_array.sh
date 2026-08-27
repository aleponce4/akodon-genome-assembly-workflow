#!/usr/bin/env bash
# Stage 10: mask filtered assemblies with Dfam and the custom repeat libraries.

set -euo pipefail

CONFIG_PATH="${1:-${CONFIG:-}}"
[[ -n "$CONFIG_PATH" ]] || { echo "ERROR: config path is required" >&2; exit 1; }
CONFIG_DIR="$(cd "$(dirname "$CONFIG_PATH")" && pwd)"
PIPELINE_ROOT="$(cd "$CONFIG_DIR/.." && pwd)"

# shellcheck source=scripts/lib/common.sh
source "$PIPELINE_ROOT/scripts/lib/common.sh"
source_config "$CONFIG_PATH"
ensure_base_dirs

rename_repeatmasker_outputs() {
    local output_dir="$1"
    local source_base="$2"
    local target_base="$3"
    local ext

    for ext in cat cat.gz masked out tbl out.gff; do
        if [[ -f "$output_dir/$source_base.$ext" ]]; then
            mv "$output_dir/$source_base.$ext" "$output_dir/$target_base.$ext"
        fi
    done

    [[ -f "$output_dir/$target_base.masked" ]] || die "RepeatMasker masked output was not found after renaming: $output_dir/$target_base.masked"
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
repeatmasker_alloc_cpus="${SLURM_CPUS_PER_TASK:-$REPEATMASKER_CPUS}"
# RepeatMasker's -pa counts parallel batch JOBS, not threads: each rmblast job
# takes ~4 cores of its own. Passing the raw CPU count oversubscribes the
# allocation roughly four-fold, so the kernel time-slices ~96 threads over 24
# cores and the run gets slower, not faster - which on a 2.6 Gb genome across
# four rounds is a real walltime-death risk. Never drop below one job.
repeatmasker_threads=$(( repeatmasker_alloc_cpus / 4 ))
(( repeatmasker_threads >= 1 )) || repeatmasker_threads=1
final_masked_output="$(repeatmasker_final_masked "$sample_id")"

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

if [[ -s "$final_masked_output" && "${REPEATMASKER_OVERWRITE:-0}" != "1" ]]; then
    log "Final RepeatMasker output already exists for sample $sample_id; skipping. Set REPEATMASKER_OVERWRITE=1 to rerun."
    exit 0
fi

[[ -f "$input_fasta" ]] || die "Filtered FASTA not found: $input_fasta"
[[ -f "$REPEATMODELER_IMAGE" ]] || die "RepeatMasker image not found: $REPEATMODELER_IMAGE"
command -v "$SINGULARITY_BIN" >/dev/null 2>&1 || die "Singularity executable not found: $SINGULARITY_BIN"

repeatmasker_container_args=(exec)
if [[ -n "${REPEATMASKER_FAMDB_DIR:-}" && -d "${REPEATMASKER_FAMDB_DIR:-}" ]]; then
    repeatmasker_container_args+=(--bind "$REPEATMASKER_FAMDB_DIR:/opt/RepeatMasker/Libraries/famdb")
elif truthy "$REPEATMASKER_ENABLE_DFAM_ROUNDS"; then
    die "RepeatMasker Dfam rounds are enabled, but REPEATMASKER_FAMDB_DIR is missing: ${REPEATMASKER_FAMDB_DIR:-unset}"
fi

# Rounds 3 and 4 should not repeat the low-complexity/simple-repeat search that
# round 1 already did: re-running it costs a full TRF pass over the genome each
# time and reports the same intervals in three separate .out/.tbl sets, so any
# sum across rounds double- or triple-counts the simple-repeat fraction.
#
# But round 1 only happens when the Dfam rounds are enabled. With
# REPEATMASKER_ENABLE_DFAM_ROUNDS=0 (a supported mode) rounds 1 and 2 are
# replaced by a plain copy, which makes rounds 3 and 4 the ONLY place low
# complexity is ever masked. Suppressing it there would hand GALBA/BRAKER a
# genome with no low-complexity masking at all and produce spurious gene models
# -- a worse outcome than the double-counting. So gate the flag on round 1
# having actually run.
# Always carries -xsmall/-gff so the array is never empty: under `set -u`,
# expanding an empty array as "${arr[@]}" is an unbound-variable error on
# bash < 4.4, which some cluster images still ship.
if truthy "$REPEATMASKER_ENABLE_DFAM_ROUNDS"; then
    repeatmasker_lib_round_flags=(-nolow -xsmall -gff)
else
    repeatmasker_lib_round_flags=(-xsmall -gff)
fi

cd "$masker_output_dir"
if truthy "$REPEATMASKER_ENABLE_DFAM_ROUNDS"; then
    log "RepeatMasker round 1 for sample $sample_id"
    "$SINGULARITY_BIN" "${repeatmasker_container_args[@]}" "$REPEATMODELER_IMAGE" RepeatMasker \
        -pa "$repeatmasker_threads" \
        -noint \
        -xsmall \
        -gff \
        -species "$REPEATMASKER_SPECIES" \
        -dir "$masker_output_dir" \
        "$input_fasta"
    rename_repeatmasker_outputs "$masker_output_dir" "$sample_base" "$sample_base.round1_simple_dfam"

    round2_input="$masker_output_dir/$sample_base.round1_simple_dfam.masked"
    round2_source="$(basename "$round2_input")"

    log "RepeatMasker round 2 for sample $sample_id"
    "$SINGULARITY_BIN" "${repeatmasker_container_args[@]}" "$REPEATMODELER_IMAGE" RepeatMasker \
        -pa "$repeatmasker_threads" \
        -nolow \
        -xsmall \
        -gff \
        -species "$REPEATMASKER_SPECIES" \
        -dir "$masker_output_dir" \
        "$round2_input"
    rename_repeatmasker_outputs "$masker_output_dir" "$round2_source" "$sample_base.round2_complex_dfam"
else
    log "Skipping RepeatMasker Dfam species rounds for sample $sample_id"
    skip_library_round "$input_fasta" "$sample_base.round1_simple_dfam" "Dfam species rounds disabled; source FamDB partition is unavailable."
    skip_library_round "$masker_output_dir/$sample_base.round1_simple_dfam.masked" "$sample_base.round2_complex_dfam" "Dfam species rounds disabled; source FamDB partition is unavailable."
fi

round3_input="$masker_output_dir/$sample_base.round2_complex_dfam.masked"
round3_source="$(basename "$round3_input")"
round3_target="$sample_base.round3_known_repeats"

if [[ -s "$known_repeats" ]]; then
    log "RepeatMasker round 3 for sample $sample_id"
    "$SINGULARITY_BIN" "${repeatmasker_container_args[@]}" "$REPEATMODELER_IMAGE" RepeatMasker \
        -pa "$repeatmasker_threads" \
        "${repeatmasker_lib_round_flags[@]}" \
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
    "$SINGULARITY_BIN" "${repeatmasker_container_args[@]}" "$REPEATMODELER_IMAGE" RepeatMasker \
        -pa "$repeatmasker_threads" \
        "${repeatmasker_lib_round_flags[@]}" \
        -lib "$unknown_repeats" \
        -dir "$masker_output_dir" \
        "$round4_input"
    rename_repeatmasker_outputs "$masker_output_dir" "$round4_source" "$round4_target"
else
    log "Skipping RepeatMasker round 4 because the unknown repeat library is empty"
    skip_library_round "$round4_input" "$round4_target" "Unknown repeat library was empty; round skipped."
fi

[[ -e "$final_masked_output" ]] || die "RepeatMasker final masked output was not created: $final_masked_output"

# Every round above can legitimately be skipped (Dfam rounds disabled, or an
# empty RepeatModeler library), and each skip copies its input forward with
# `cp -f`. So the "final masked" genome can be a byte-identical copy of the
# UNMASKED assembly while this stage still exits 0. Nothing in stages 11-13 or 15
# inspects sequence case, so an unmasked genome would get a HISAT2 index built
# over it and every RNA library aligned to it before stage 14/16/17 finally
# objected -- and that error names the *simplified* FASTA, three stages
# downstream of the actual problem. Assert here instead.
assert_softmasked_fasta "$final_masked_output"
