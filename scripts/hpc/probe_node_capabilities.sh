#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_PATH="${1:-$PROJECT_ROOT/config/bootstrap.env}"

bash "$SCRIPT_DIR/bootstrap_dependencies.sh" probe "$CONFIG_PATH"
