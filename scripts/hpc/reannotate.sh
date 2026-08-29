#!/usr/bin/env bash
# One-shot: rebuild the soft-masked genome, then re-run annotation on top of it.
#
# Everything heavy is submitted to SLURM, so this returns in seconds and the work
# survives you logging out. The annotation chain is submitted with
# --dependency=afterok on the rebuild, so if the rebuild fails or produces an
# implausibly masked genome, annotation never starts.
#
# Safe to re-run: the rebuild job exits early if the genome is already masked,
# and re-submitting simply queues a fresh chain.
#
#   bash scripts/hpc/reannotate.sh
#   SAMPLE_ID=0337 bash scripts/hpc/reannotate.sh      # a different sample
#   DRY_RUN=1      bash scripts/hpc/reannotate.sh      # show what would happen
#
# Site values can be overridden by exporting them before running.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$SCRIPT_DIR"

CONFIG_PATH="${CONFIG_PATH:-$SCRIPT_DIR/config/pipeline.env}"
SAMPLE_ID="${SAMPLE_ID:-0339}"
DRY_RUN="${DRY_RUN:-0}"

say () { printf '[reannotate] %s\n' "$*"; }
fail () { printf '[reannotate] ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 0. Make sure we are in the right repository. It is easy to be sitting in a
#    different project directory and not notice until something odd happens.
# ---------------------------------------------------------------------------
[[ -f "$CONFIG_PATH" ]] || fail "config not found: $CONFIG_PATH (are you in the akodon repo?)"
grep -q 'ASSEMBLY_PREFIX' "$CONFIG_PATH" \
    || fail "$CONFIG_PATH does not look like the akodon pipeline config"
[[ -f "$SCRIPT_DIR/scripts/qc/rebuild_softmask.sh" ]] \
    || fail "scripts/qc/rebuild_softmask.sh is missing - run 'git pull' first"
[[ -f "$SCRIPT_DIR/scripts/hpc/rebuild_softmask_job.sh" ]] \
    || fail "scripts/hpc/rebuild_softmask_job.sh is missing - run 'git pull' first"
command -v sbatch >/dev/null 2>&1 || fail "sbatch not on PATH - run this on the cluster"

# Content checks, not just existence. A half-updated checkout (files copied by
# hand, or a pull that did not take) otherwise fails four hours later inside a
# SLURM job instead of instantly here. The old rebuild backend accumulated each
# scaffold into one awk string, which does not finish on a 21.5 Mb scaffold.
grep -q 'masked_percent_of' "$SCRIPT_DIR/scripts/lib/common.sh" \
    || fail "scripts/lib/common.sh is stale (no masked_percent_of). Run 'git pull'."

# Match CODE, not prose. An earlier version of this guard grepped for a comment
# sentence that happens to wrap across two lines, so it never matched and
# rejected a perfectly good file. `seq = seq $0` is the quadratic accumulator's
# signature: it builds each scaffold as one growing awk string, which does not
# finish on a 21.5 Mb scaffold. The linear rewrite has no such accumulation.
if grep -q 'seq = seq \$0' "$SCRIPT_DIR/scripts/qc/rebuild_softmask.sh"; then
    fail "scripts/qc/rebuild_softmask.sh is the old quadratic backend, which will hit the walltime. Run 'git pull'."
fi

# In-flight guard. Stages 11/15/20 write FIXED paths, not per-run paths, so two
# overlapping chains would have two jobs writing the same 2.3 GB simplified
# genome with O_TRUNC. The result stays plausible enough to pass the soft-mask
# assertion, so GALBA and BRAKER3 would annotate a corrupted genome for 48 hours
# and nothing would look wrong until the models did. A file lock is useless here
# (this script exits in seconds while the jobs run for days), so ask SLURM.
if [[ "${REANNOTATE_FORCE:-0}" != "1" ]]; then
    inflight="$(squeue -u "$USER" -h -o '%i %j %T' 2>/dev/null \
        | awk '$2 ~ /^(akodon_rebuild|annotation_|galba|rna_align|braker|tsebra|isoform|restore)/ {printf "    %s  %-32s %s\n", $1, $2, $3}')"
    if [[ -n "$inflight" ]]; then
        printf '%s\n' "$inflight" >&2
        fail "pipeline jobs are already queued or running (above).
  Running a second chain would have two jobs writing the same output paths and
  can silently corrupt the annotation genome. Cancel the existing run first
  (scripts/cancel_submitted_run.sh <manifest>), or export REANNOTATE_FORCE=1 if
  you are certain those jobs are unrelated."
    fi
fi

say "repository : $SCRIPT_DIR"
say "config     : $CONFIG_PATH"
say "sample     : $SAMPLE_ID"

# ---------------------------------------------------------------------------
# 1. Site settings. These are the values this project actually uses; each is
#    still overridable from the environment.
# ---------------------------------------------------------------------------
export SBATCH_ACCOUNT="${SBATCH_ACCOUNT:-ACF-UTHSC0001}"
export ANNOTATION_SAMPLE_ID="${ANNOTATION_SAMPLE_ID:-$SAMPLE_ID}"
export ANNOTATION_SAMPLE_MODE="${ANNOTATION_SAMPLE_MODE:-single}"
export ENABLE_ANNOTATION="${ENABLE_ANNOTATION:-1}"
export ENABLE_INTERPROSCAN="${ENABLE_INTERPROSCAN:-0}"
export PIPELINE_START_STAGE="${PIPELINE_START_STAGE:-11}"
export PIPELINE_END_STAGE="${PIPELINE_END_STAGE:-20}"

case "$SBATCH_ACCOUNT" in
    *XXXX*) fail "SBATCH_ACCOUNT is still the placeholder ($SBATCH_ACCOUNT). Export your real allocation." ;;
esac

# Check the inputs that actually have to exist, not the sample table. In single
# mode nothing downstream reads samples.tsv -- annotation_sample_id_by_index just
# echoes ANNOTATION_SAMPLE_ID -- so a repo shipping placeholder rows would abort
# a perfectly valid run, while a sample present in the table but missing its
# RepeatMasker output would sail through. Resolve the real paths via the config.
resolve_path() {
    bash -c 'source "$1/scripts/lib/common.sh"; source_config "$2"; '"$3"' "$4"' \
        _ "$SCRIPT_DIR" "$CONFIG_PATH" "$SAMPLE_ID" 2>/dev/null
}
rm_dir_check="$(resolve_path repeatmasker_workdir)"
asm_check="$(resolve_path filtered_fasta)"
[[ -n "$rm_dir_check" && -d "$rm_dir_check" ]] \
    || fail "no RepeatMasker output directory for sample '$SAMPLE_ID': ${rm_dir_check:-<unresolved>}"
[[ -n "$asm_check" && -f "$asm_check" ]] \
    || fail "no filtered assembly for sample '$SAMPLE_ID': ${asm_check:-<unresolved>}"
out_files="$(find "$rm_dir_check" -maxdepth 1 -name '*.out' | wc -l)"
(( out_files > 0 )) \
    || fail "no RepeatMasker .out files in $rm_dir_check - the mask rebuild has nothing to work from"
say "inputs     : $out_files RepeatMasker .out file(s), assembly $(basename "$asm_check")"

if [[ "$ANNOTATION_SAMPLE_MODE" != "single" ]]; then
    grep -qE "^${SAMPLE_ID}[[:space:]]" "$SCRIPT_DIR/config/samples.tsv" \
        || fail "mode is '$ANNOTATION_SAMPLE_MODE' and sample '$SAMPLE_ID' is not in config/samples.tsv"
fi

say "account    : $SBATCH_ACCOUNT"
say "stages     : $PIPELINE_START_STAGE-$PIPELINE_END_STAGE  (mode=$ANNOTATION_SAMPLE_MODE)"

mkdir -p logs/slurm

# ---------------------------------------------------------------------------
# 2. Report what the RNA evidence looks like. If BAMs already exist stage 15
#    skips them, which is the difference between minutes and a day.
# ---------------------------------------------------------------------------
bam_dir="$SCRIPT_DIR/RNA_seq/bam_files/$SAMPLE_ID"
bam_count=0
[[ -d "$bam_dir" ]] && bam_count="$(find "$bam_dir" -maxdepth 1 -name '*.bam' | wc -l)"
# Serial critical path, summing the configured walltime LIMITS. Jobs are chained
# with afterok, so each queues independently -- add real queue wait on top.
if (( bam_count > 0 )); then
    say "RNA BAMs   : $bam_count present in RNA_seq/bam_files/$SAMPLE_ID (stage 15 will skip them)"
    say "ETA        : up to ~39 h of walltime limits, plus queue wait"
    say "             (rebuild 4 + preprocess 4 + GALBA/BRAKER3 24 + tsebra 1 + isoform 2 + headers 4)"
else
    say "RNA BAMs   : NONE - stage 15 must align 10 libraries first, which is the long pole"
    say "ETA        : up to ~63 h of walltime limits, plus queue wait"
    say "             (rebuild 4 + preprocess 4 + RNA align 24 + BRAKER3 24 + tsebra 1 + isoform 2 + headers 4)"
    say ""
    say "WARNING    : 63 h does NOT fit a Friday-evening to Monday-morning window,"
    say "             and that assumes zero queue time across 7 chained jobs."
    say "             To finish sooner, run the RNA alignment on its own FIRST:"
    say "                 PIPELINE_START_STAGE=15 PIPELINE_END_STAGE=15 \\"
    say "                   ANNOTATION_SAMPLE_MODE=single ANNOTATION_SAMPLE_ID=$SAMPLE_ID \\"
    say "                   ENABLE_ANNOTATION=1 bash run_pipeline.sh config/pipeline.env"
    say "             It does not depend on the mask rebuild -- soft-masking only"
    say "             changes letter case, and HISAT2 is case-insensitive."
    if [[ "${ACKNOWLEDGE_LONG_RUN:-0}" != "1" ]]; then
        fail "refusing to submit a ~63 h chain unattended by default.
  Re-run with ACKNOWLEDGE_LONG_RUN=1 to proceed anyway, or pre-align the RNA as shown above."
    fi
fi

if [[ "$DRY_RUN" != "0" ]]; then
    say "DRY_RUN set - stopping before submission"
    exit 0
fi

# ---------------------------------------------------------------------------
# 3. Submit the soft-mask rebuild.
# ---------------------------------------------------------------------------
say "submitting soft-mask rebuild"
rebuild_job="$(sbatch --parsable \
    --account="$SBATCH_ACCOUNT" \
    --job-name="akodon_rebuild_${SAMPLE_ID}" \
    --partition="${REBUILD_PARTITION:-${REPEATMASKER_PARTITION:-campus}}" \
    --qos="${REBUILD_QOS:-${REPEATMASKER_QOS:-campus}}" \
    --time="${REBUILD_TIME:-04:00:00}" \
    --cpus-per-task="${REBUILD_CPUS:-4}" \
    --mem="${REBUILD_MEM:-32G}" \
    --output="logs/slurm/rebuild_softmask_%j.out" \
    --error="logs/slurm/rebuild_softmask_%j.err" \
    "$SCRIPT_DIR/scripts/hpc/rebuild_softmask_job.sh" "$CONFIG_PATH" "$SAMPLE_ID")" \
    || fail "failed to submit the rebuild job"

[[ -n "$rebuild_job" ]] || fail "sbatch returned an empty job id for the rebuild"
say "rebuild job: $rebuild_job"

# ---------------------------------------------------------------------------
# 4. Submit the annotation chain, gated on the rebuild succeeding.
#    run_pipeline.sh gives its first stage this dependency (afterok), so a
#    failed or implausible rebuild prevents annotation from starting at all.
# ---------------------------------------------------------------------------
export PIPELINE_DEPENDENCY_JOB_ID="$rebuild_job"
say "submitting annotation stages, gated on afterok:$rebuild_job"
bash "$SCRIPT_DIR/run_pipeline.sh" "$CONFIG_PATH"

manifest="$(find logs/slurm/submissions -maxdepth 1 -name 'run_*_jobs.tsv' -newermt '-10 minutes' 2>/dev/null | sort | tail -1)"
echo
say "SUBMITTED. You can log out now."
if [[ -n "$manifest" ]]; then
    say "manifest : $manifest"
    say "progress : bash scripts/summarize_slurm_run.sh $manifest"
    say "cancel   : bash scripts/cancel_submitted_run.sh $manifest"
fi
say "queue    : squeue -u \$USER"
say "logs     : logs/slurm/"
