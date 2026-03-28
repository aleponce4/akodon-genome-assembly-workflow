#!/usr/bin/env bash
# Stage 09: merge RepeatModeler outputs, collapse redundancy, and split known/unknown repeats.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="${1:-${CONFIG:-}}"

# shellcheck source=../scripts/lib/common.sh
source "$SCRIPT_DIR/../scripts/lib/common.sh"
source_config "$CONFIG_PATH"
ensure_base_dirs

find_classified_repeat_file() {
    local search_dir="$1"
    local candidate

    candidate="$(find "$search_dir" -type f -name 'consensi.fa.classified' | sort | head -n 1 || true)"
    if [[ -n "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
    fi

    candidate="$(find "$search_dir" -type f -name '*classified-families.fa' | sort | head -n 1 || true)"
    if [[ -n "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
    fi

    candidate="$(find "$search_dir" -type f -name '*-families.fa' | sort | head -n 1 || true)"
    if [[ -n "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
    fi

    return 1
}

merged_repeats="$REPEAT_LIBRARY_DIR/merged_repeats.fa"
non_redundant_repeats="$REPEAT_LIBRARY_DIR/non_redundant_repeats.fa"
known_repeats="$(known_repeat_library)"
unknown_repeats="$(unknown_repeat_library)"
stats_file="$REPEAT_LIBRARY_DIR/repeat_library_stats.tsv"

if smoke_mode; then
    log "Smoke mode: creating mock repeat libraries"
    write_smoke_fasta "$merged_repeats" "repeat_known#DNA" "ATGCGTATGCGTATGCGTATGCGTATGCGT"
    cat "$merged_repeats" > "$non_redundant_repeats"
    write_smoke_fasta "$known_repeats" "repeat_known#DNA" "ATGCGTATGCGTATGCGTATGCGTATGCGT"
    write_smoke_fasta "$unknown_repeats" "repeat_unknown#Unknown" "ATGCGTATGCGTATGCGTATGCGTATGCGT"
    printf 'label\tsequence_count\n' > "$stats_file"
    printf '%s\t1\n' "$(basename "$non_redundant_repeats")" >> "$stats_file"
    printf '%s\t1\n' "$(basename "$known_repeats")" >> "$stats_file"
    printf '%s\t1\n' "$(basename "$unknown_repeats")" >> "$stats_file"
    exit 0
fi

activate_conda_env "$REPEAT_ENV" "${REPEAT_ENV_PREFIX:-}"

: > "$merged_repeats"
printf 'label\tsequence_count\n' > "$stats_file"

sample_total="$(sample_count)"
for ((idx = 0; idx < sample_total; idx++)); do
    sample_id="$(sample_id_by_index "$idx")"
    workdir="$(repeatmodeler_workdir "$sample_id")"
    export_path="$(repeatmodeler_export_fasta "$sample_id")"
    export_name="$(basename "$export_path")"
    classified_file="$(find_classified_repeat_file "$workdir")" || die "No classified repeat file found in $workdir"

    cp -f "$classified_file" "$export_path"
    cat "$export_path" >> "$merged_repeats"
    printf '%s\t%s\n' "$export_name" "$(count_fasta_records "$export_path")" >> "$stats_file"
done

log "Collapsing redundant repeat families with CD-HIT-EST"
cd-hit-est \
    -i "$merged_repeats" \
    -o "$non_redundant_repeats" \
    -c "$CD_HIT_IDENTITY" \
    -n "$CD_HIT_WORD_SIZE" \
    -T "${SLURM_CPUS_PER_TASK:-$REPEAT_LIBRARY_CPUS}" \
    -M "$CD_HIT_MEMORY_MB"

seqkit fx2tab "$non_redundant_repeats" | awk -F '\t' '$1 !~ /Unknown/' | seqkit tab2fx > "$known_repeats"
seqkit fx2tab "$non_redundant_repeats" | awk -F '\t' '$1 ~ /Unknown/' | seqkit tab2fx > "$unknown_repeats"

printf '%s\t%s\n' "$(basename "$non_redundant_repeats")" "$(count_fasta_records "$non_redundant_repeats")" >> "$stats_file"
printf '%s\t%s\n' "$(basename "$known_repeats")" "$(count_fasta_records "$known_repeats")" >> "$stats_file"
printf '%s\t%s\n' "$(basename "$unknown_repeats")" "$(count_fasta_records "$unknown_repeats")" >> "$stats_file"

[[ -s "$non_redundant_repeats" ]] || die "Merged repeat library is missing or empty: $non_redundant_repeats"
[[ -e "$known_repeats" ]] || die "Known repeat library was not created: $known_repeats"
[[ -e "$unknown_repeats" ]] || die "Unknown repeat library was not created: $unknown_repeats"
