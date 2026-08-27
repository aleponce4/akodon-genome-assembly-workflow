#!/usr/bin/env bash
# Restore Supernova's outs/report.txt and outs/summary.csv from the Martian
# run-info tarball (<run_id>.mri.tgz) that sits beside each run directory.
#
# WHY THIS EXISTS
# outs/ holds only small text files, so it is exactly what a transfer drops when
# it fails partway through the small-file phase -- while the multi-megabyte
# .mri.tgz beside it, which embeds copies of the same files, comes through. The
# report carries the input-quality metrics (coverage, molecule length, P10,
# barcode fraction, heterozygosity, genome-size estimate) that a genome paper's
# methods section needs and that cannot be derived from the assembly FASTA.
#
# Restores in place so the run directory matches what a complete transfer would
# have produced, which keeps collect_run_metrics.sh and any downstream tooling
# working without special cases. Never overwrites an existing non-empty file.
#
# Usage: recover_supernova_reports.sh <supernova_run_dir_root> [--dry-run]

set -uo pipefail

ROOT="${1:?usage: recover_supernova_reports.sh <supernova_runs_dir> [--dry-run]}"
DRY="${2:-}"

[[ -d "$ROOT" ]] || { echo "ERROR: not a directory: $ROOT" >&2; exit 1; }

recovered=0
skipped=0
failed=0

for run_dir in "$ROOT"/*/; do
    [[ -d "$run_dir" ]] || continue
    run_id="$(basename "$run_dir")"
    tgz="$(find "$run_dir" -maxdepth 1 -name '*.mri.tgz' | head -1)"

    if [[ -z "$tgz" ]]; then
        echo "$run_id: no .mri.tgz - cannot recover"
        failed=$((failed+1))
        continue
    fi

    if [[ -s "$run_dir/outs/report.txt" ]]; then
        echo "$run_id: outs/report.txt already present - skipping"
        skipped=$((skipped+1))
        continue
    fi

    if [[ "$DRY" == "--dry-run" ]]; then
        echo "$run_id: would extract from $(basename "$tgz")"
        continue
    fi

    mkdir -p "$run_dir/outs"
    # Paths inside the tarball are <run_id>/outs/<file>; strip the first two
    # components so they land directly in outs/.
    tar xzf "$tgz" -C "$run_dir/outs" --strip-components=2 \
        "$run_id/outs/report.txt" "$run_id/outs/summary.csv" 2>/dev/null

    if [[ -s "$run_dir/outs/report.txt" ]]; then
        echo "$run_id: recovered report.txt ($(wc -c < "$run_dir/outs/report.txt") b), summary.csv ($(wc -c < "$run_dir/outs/summary.csv" 2>/dev/null || echo 0) b)"
        recovered=$((recovered+1))
    else
        echo "$run_id: extraction produced nothing - the tarball may predate the SUMMARIZE stage"
        failed=$((failed+1))
    fi
done

echo
echo "recovered=$recovered skipped=$skipped failed=$failed"
[[ "$failed" -eq 0 ]]
