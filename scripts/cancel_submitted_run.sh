#!/usr/bin/env bash

set -euo pipefail

manifest="${1:-}"
[[ -n "$manifest" ]] || { echo "Usage: $0 <submission_manifest.tsv>" >&2; exit 1; }
[[ -f "$manifest" ]] || { echo "Manifest not found: $manifest" >&2; exit 1; }
command -v scancel >/dev/null 2>&1 || { echo "scancel was not found on PATH." >&2; exit 1; }

mapfile -t job_ids < <(awk -F '\t' 'NR > 1 && $3 != "" { print $3 }' "$manifest")

if (( ${#job_ids[@]} == 0 )); then
    echo "No job IDs found in manifest: $manifest"
    exit 0
fi

printf 'Canceling %d jobs from %s:\n' "${#job_ids[@]}" "$manifest"
printf '  %s\n' "${job_ids[@]}"
scancel "${job_ids[@]}"
