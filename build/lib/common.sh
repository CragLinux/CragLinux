#!/bin/bash
# Astro Linux - Common shell library
# Sourced by build scripts, not executed directly.

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

die() {
    log_error "$1"
    exit 1
}

require_command() {
    if ! command -v "$1" &>/dev/null; then
        die "Required command not found: $1"
    fi
}

# Resolve the project root from any script location
# (the repo root is identified by sdk/build-toolchain.sh)
resolve_project_root() {
    local dir="$1"
    while [ "$dir" != "/" ]; do
        if [ -f "$dir/sdk/build-toolchain.sh" ]; then
            echo "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    die "Could not find project root (no sdk/build-toolchain.sh found)"
}
