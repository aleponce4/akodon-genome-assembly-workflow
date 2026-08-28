#!/usr/bin/env bash
# SLURM job: rebuild the soft-masked genome for one sample and install it as the
# stage 10 final output, so stage 11 picks it up unchanged.
#
# Runs as its own job rather than on the login node: it streams ~1.5 GB of
# RepeatMasker .out files and a 2.2 GB assembly, which is not login-node work.
#
# It EXITS NON-ZERO if the rebuilt genome is not plausibly masked. Downstream
# stages are submitted with --dependency=afterok, so a bad rebuild stops the
# annotation from ever starting on a broken genome rather than quietly
# producing thousands of spurious gene models over a weekend.
#
# Usage: sbatch scripts/hpc/rebuild_softmask_job.sh <config> <sample_id>

set -euo pipefail

CONFIG_PATH="${1:?usage: rebuild_softmask_job.sh <config> <sample_id>}"
SAMPLE_ID="${2:?sample_id required}"

CONFIG_DIR="$(cd "$(dirname "$CONFIG_PATH")" && pwd)"
PIPELINE_ROOT="$(cd "$CONFIG_DIR/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$PIPELINE_ROOT/scripts/lib/common.sh"
source_config "$CONFIG_PATH"

MIN_PCT="${SOFTMASK_MIN_PERCENT:-20}"
EXPECT_PCT="${SOFTMASK_EXPECT_PERCENT:-40}"

rm_dir="$(repeatmasker_workdir "$SAMPLE_ID")"
assembly="$(filtered_fasta "$SAMPLE_ID")"
final="$(repeatmasker_final_masked "$SAMPLE_ID")"
tmp_out="$rm_dir/.rebuilt_softmask.$$.fasta"

log "Sample            : $SAMPLE_ID"
log "RepeatMasker dir  : $rm_dir"
log "Source assembly   : $assembly"
log "Target final mask : $final"

[[ -d "$rm_dir"   ]] || die "RepeatMasker directory not found: $rm_dir"
[[ -f "$assembly" ]] || die "Filtered assembly not found: $assembly"

out_count="$(find "$rm_dir" -maxdepth 1 -name '*.out' | wc -l)"
(( out_count > 0 )) || die "No RepeatMasker .out files in $rm_dir - nothing to rebuild from"
log "Found $out_count RepeatMasker .out file(s)"

# Already rebuilt? Leave it alone so the job is safe to resubmit.
if [[ -s "$final" ]]; then
    current="$(masked_percent_of "$final")"
    if awk -v p="$current" -v e="$EXPECT_PCT" 'BEGIN { exit !(p >= e) }'; then
        log "Final masked genome is already ${current}% soft-masked (>= ${EXPECT_PCT}%) - nothing to do"
        exit 0
    fi
    log "Existing final masked genome is only ${current}% soft-masked - rebuilding"
fi

trap 'rm -f "$tmp_out"' EXIT

log "Rebuilding soft-mask as the union of all RepeatMasker rounds"
bash "$PIPELINE_ROOT/scripts/qc/rebuild_softmask.sh" "$rm_dir" "$assembly" "$tmp_out"

pct="$(masked_percent_of "$tmp_out")"
log "Rebuilt genome is ${pct}% soft-masked"

if awk -v p="$pct" -v m="$MIN_PCT" 'BEGIN { exit !(p < m) }'; then
    die "Rebuilt genome is only ${pct}% soft-masked (minimum ${MIN_PCT}%). Refusing to install it; annotation will not run."
fi
if awk -v p="$pct" -v e="$EXPECT_PCT" 'BEGIN { exit !(p < e) }'; then
    log "WARNING: ${pct}% is below the ${EXPECT_PCT}% expected for a rodent, but above the hard minimum. Continuing."
fi

# Record counts so the swap can be verified afterwards.
src_records="$(count_fasta_records "$assembly")"
new_records="$(count_fasta_records "$tmp_out")"
[[ "$src_records" == "$new_records" ]] \
    || die "Rebuilt genome has $new_records records but the source assembly has $src_records - refusing to install"
log "Record count matches source assembly: $new_records"

if [[ -s "$final" ]]; then
    backup="$final.pre_rebuild_$(date +%Y%m%d_%H%M%S)"
    log "Preserving the previous final masked genome as $(basename "$backup")"
    mv -f "$final" "$backup"
fi

mv -f "$tmp_out" "$final"
trap - EXIT

log "Installed rebuilt soft-masked genome: $final"
assert_softmasked_fasta "$final"
log "Rebuild complete for sample $SAMPLE_ID"
