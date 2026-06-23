#!/usr/bin/env bash
# Prepare an external RepeatMasker FamDB directory with the rodentia partition.

set -euo pipefail

CONFIG_PATH="${1:-config/pipeline.env}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/scripts/lib/common.sh"
source_config "$CONFIG_PATH"

container_famdb="/opt/RepeatMasker/Libraries/famdb"
partition="${REPEATMASKER_FAMDB_PARTITION:-7}"
base_url="${DFAM_FAMDB_BASE_URL:-https://www.dfam.org/releases/Dfam_3.8/families/FamDB}"

[[ -f "$REPEATMODELER_IMAGE" ]] || die "RepeatModeler/RepeatMasker image not found: $REPEATMODELER_IMAGE"
command -v "$SINGULARITY_BIN" >/dev/null 2>&1 || die "Singularity executable not found: $SINGULARITY_BIN"
ensure_dir "$REPEATMASKER_FAMDB_DIR"

if ! find "$REPEATMASKER_FAMDB_DIR" -maxdepth 1 -type f -name '*.h5' | grep -q .; then
    log "Copying existing container FamDB files to $REPEATMASKER_FAMDB_DIR"
    "$SINGULARITY_BIN" exec "$REPEATMODELER_IMAGE" \
        bash -lc "cd '$container_famdb' && tar cf - ." | tar -C "$REPEATMASKER_FAMDB_DIR" -xf -
fi

root_file="$(find "$REPEATMASKER_FAMDB_DIR" -maxdepth 1 -type f -name '*_full.0.h5' | sort | head -n 1 || true)"
[[ -n "$root_file" ]] || die "Could not find root FamDB partition '*_full.0.h5' in $REPEATMASKER_FAMDB_DIR"

root_name="$(basename "$root_file")"
prefix="${root_name%.0.h5}"
target_h5="$REPEATMASKER_FAMDB_DIR/${prefix}.${partition}.h5"
target_gz="$target_h5.gz"

if [[ -s "$target_h5" ]]; then
    log "FamDB partition already present: $target_h5"
    exit 0
fi

download_url="$base_url/${prefix}.${partition}.h5.gz"
log "Downloading FamDB partition $partition from $download_url"

if command -v curl >/dev/null 2>&1; then
    curl -L --fail --retry 3 -o "$target_gz.tmp" "$download_url"
elif command -v wget >/dev/null 2>&1; then
    wget -O "$target_gz.tmp" "$download_url"
else
    die "Neither curl nor wget is available for downloading $download_url"
fi

mv -f "$target_gz.tmp" "$target_gz"
gunzip -f "$target_gz"
[[ -s "$target_h5" ]] || die "FamDB partition download did not create: $target_h5"

log "Prepared FamDB partition: $target_h5"
