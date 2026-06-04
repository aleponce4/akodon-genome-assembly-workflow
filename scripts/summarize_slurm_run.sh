#!/usr/bin/env bash

set -euo pipefail

manifest="${1:-}"
[[ -n "$manifest" ]] || { echo "Usage: $0 <submission_manifest.tsv>" >&2; exit 1; }
[[ -f "$manifest" ]] || { echo "Manifest not found: $manifest" >&2; exit 1; }

status_for_job() {
    local job_id="$1"

    if ! command -v sacct >/dev/null 2>&1; then
        printf 'NA\tNA\tNA\n'
        return 0
    fi

    local line
    line="$(sacct -n -P -j "$job_id" --format=JobID,State,ExitCode,Elapsed 2>/dev/null \
        | awk -F '|' '$1 !~ /\./ { print $2 "\t" $3 "\t" $4; exit }')"

    if [[ -n "$line" ]]; then
        printf '%s\n' "$line"
    else
        printf 'UNKNOWN\tNA\tNA\n'
    fi
}

printf 'stage_id\tstage_name\tjob_id\tstate\texit_code\telapsed\tstderr\n'

awk -F '\t' 'NR > 1 { print $1 "\t" $2 "\t" $3 "\t" $7 }' "$manifest" |
while IFS=$'\t' read -r stage_id stage_name job_id stderr_path; do
    IFS=$'\t' read -r state exit_code elapsed < <(status_for_job "$job_id")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$stage_id" "$stage_name" "$job_id" "$state" "$exit_code" "$elapsed" "$stderr_path"
done
