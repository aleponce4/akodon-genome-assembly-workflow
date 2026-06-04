#!/usr/bin/env bash

set -euo pipefail

resources_mode=0
if [[ "${1:-}" == "--resources" ]]; then
    resources_mode=1
    shift
fi

manifest="${1:-}"
[[ -n "$manifest" ]] || { echo "Usage: $0 [--resources] <submission_manifest.tsv>" >&2; exit 1; }
[[ -f "$manifest" ]] || { echo "Manifest not found: $manifest" >&2; exit 1; }

status_for_job() {
    local job_id="$1"

    if [[ -z "$job_id" ]]; then
        printf 'NOT_SUBMITTED\tNA\tNA\n'
        return 0
    fi

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

resource_for_job() {
    local job_id="$1"

    if [[ -z "$job_id" ]]; then
        printf 'NA\tNA\tNA\tNA\n'
        return 0
    fi

    if ! command -v sacct >/dev/null 2>&1; then
        printf 'NA\tNA\tNA\tNA\n'
        return 0
    fi

    local line
    line="$(sacct -n -P -j "$job_id" --format=JobID,AllocCPUS,ReqMem,MaxRSS,TotalCPU 2>/dev/null \
        | awk -F '|' -v id="$job_id" '
            $1 == id {
                print $2 "\t" $3 "\t" $4 "\t" $5
                found = 1
                exit
            }
            $1 !~ /\./ && candidate == "" {
                candidate = $2 "\t" $3 "\t" $4 "\t" $5
            }
            END {
                if (!found && candidate != "") {
                    print candidate
                }
            }
        ')"

    if [[ -n "$line" ]]; then
        printf '%s\n' "$line"
    else
        printf 'NA\tNA\tNA\tNA\n'
    fi
}

if (( resources_mode )); then
    printf 'stage_id\tstage_name\tjob_id\tstate\texit_code\telapsed\talloc_cpus\treq_mem\tmax_rss\ttotal_cpu\tstderr\n'
else
    printf 'stage_id\tstage_name\tjob_id\tstate\texit_code\telapsed\tstderr\n'
fi

awk -F '\t' 'NR > 1 { print $1 "\034" $2 "\034" $3 "\034" $7 }' "$manifest" |
while IFS=$'\034' read -r stage_id stage_name job_id stderr_path; do
    IFS=$'\t' read -r state exit_code elapsed < <(status_for_job "$job_id")
    if (( resources_mode )); then
        IFS=$'\t' read -r alloc_cpus req_mem max_rss total_cpu < <(resource_for_job "$job_id")
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$stage_id" "$stage_name" "$job_id" "$state" "$exit_code" "$elapsed" \
            "$alloc_cpus" "$req_mem" "$max_rss" "$total_cpu" "$stderr_path"
    else
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$stage_id" "$stage_name" "$job_id" "$state" "$exit_code" "$elapsed" "$stderr_path"
    fi
done
