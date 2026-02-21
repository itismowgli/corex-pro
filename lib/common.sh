#!/bin/bash
# lib/common.sh — CoreX Pro v2
# Shared logging, color, and utility functions.
# Source this at the top of every lib/*.sh and lib/services/*.sh file.
#
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'  # No Color / Reset

# ── Logging ───────────────────────────────────────────────────────────────────
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_step()    { echo -e "${CYAN}${BOLD}[STEP]${NC} $1"; }
log_success() { echo -e "${GREEN}[  OK]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[FAIL]${NC} $1" >&2; exit 1; }

# ── Utilities ─────────────────────────────────────────────────────────────────

# Generate a 24-char random password (alphanumeric, no special chars).
# Safe to use in YAML values and shell variables without quoting concerns.
generate_pass() { openssl rand -base64 24 | tr -d '/+=' | head -c 24; }

# Verify the script is running as root; exit with error if not.
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Run as root: sudo bash corex.sh"
    fi
    return 0
}

# Verify a required command is installed.
# Usage: require_cmd jq "Install with: apt-get install jq"
require_cmd() {
    local cmd="$1"
    local hint="${2:-}"
    if ! command -v "$cmd" &>/dev/null; then
        log_error "Required command not found: $cmd${hint:+. $hint}"
    fi
}

# Check if a docker container is currently running.
# Returns 0 if running, 1 if not.
container_running() {
    local name="$1"
    docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null | grep -q '^true$'
}

# Check if a docker container exists (running or stopped).
container_exists() {
    docker inspect "$1" &>/dev/null
}
