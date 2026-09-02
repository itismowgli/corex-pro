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

# Generate a 32-char random password (alphanumeric, no special chars).
# Safe to use in YAML values and shell variables without quoting concerns.
# Uses 32 input bytes so that after stripping /+= we still get 32 chars.
# (Old approach used 24 bytes; stripping chars reduced entropy below 24.)
generate_pass() { openssl rand -base64 32 | tr -d '/+=' | head -c 32; }

# ── cred_get ──────────────────────────────────────────────────────────────────
# Read one value out of /root/corex-credentials.txt.
#
# Usage: cred_get "Immich DB:"        # uses $CRED_FILE
#        cred_get "Immich DB:" /path/to/file
#
# The file is column-aligned, so a value carries padding after the label:
#
#     Immich DB:       nJBrU8gc2EwCg384wv5FLLRb
#
# Everything after the first colon is the value, with surrounding whitespace
# trimmed and internal spaces kept. Both parts matter. Keeping the padding
# sends "      nJBrU8gc..." as the password, which fails authentication
# against a database initialised with the trimmed value. Splitting on
# whitespace instead truncates any password that contains a space.
#
# One helper, so the installer and corex-manage cannot disagree about what a
# credential is. They did, and Immich stopped being able to reach its own
# database on repair.
cred_get() {
    local label="$1"
    local file="${2:-${CRED_FILE:-/root/corex-credentials.txt}}"
    [[ -f "$file" ]] || return 1
    grep -m1 -F "$label" "$file" \
        | sed -e 's/^[^:]*:[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# ── ufw_revoke ────────────────────────────────────────────────────────────────
# Delete the UFW rules for one or more port specs.
#
# Usage: ufw_revoke "25/tcp" "587/tcp" "5353/udp"
#        ufw_revoke "from 192.168.1.0/24 to any port 11434 proto tcp"
#
# Each argument is a full `ufw allow` spec, because a scoped rule can only be
# deleted by repeating the spec it was added with; deleting by port alone does
# not match it.
#
# Removing a service used to leave its ports open forever. No <svc>_destroy
# revoked anything, so uninstalling Stalwart left 25, 143, 465, 587 and 993
# open to the whole internet with nothing listening behind them: all of the
# exposure and none of the service.
#
# Deleting by port removes every rule for that port, LAN-scoped ones included,
# which is what removal should do. Both address families are handled by ufw
# itself. Absent rules are not an error, so this is safe to call for a service
# that opened none.
ufw_revoke() {
    command -v ufw >/dev/null 2>&1 || return 0
    local spec
    for spec in "$@"; do
        [[ -n "$spec" ]] || continue
        # Unquoted on purpose: a spec such as
        # "from 10.0.0.0/8 to any port 445 proto tcp" has to reach ufw as
        # separate words.
        # shellcheck disable=SC2086
        ufw --force delete allow $spec >/dev/null 2>&1 || true
    done
}

# ── compose_up_enabled ────────────────────────────────────────────────────────
# `docker compose up -d` for a service, minus any component the operator turned
# off, and with those components stopped and set not to restart.
#
# Usage: compose_up_enabled monitoring /path/to/docker-compose.yml [extra args]
#
# A plain `up -d` starts every service in the file, so a repair silently
# restarted a component that had been deliberately stopped. Naming only the
# enabled ones is what makes a per-component choice survive a repair, an
# update and a reboot.
#
# With nothing disabled this behaves exactly like `up -d`.
compose_up_enabled() {
    local svc="$1" compose="$2"; shift 2
    local disabled=() enabled=() comp

    if declare -f state_component_list_disabled >/dev/null 2>&1; then
        mapfile -t disabled < <(state_component_list_disabled "$svc")
    fi

    if [[ ${#disabled[@]} -eq 0 ]]; then
        docker compose -f "$compose" up -d "$@"
        return $?
    fi

    while IFS= read -r comp; do
        [[ -n "$comp" ]] || continue
        local skip=0 d
        for d in "${disabled[@]}"; do [[ "$comp" == "$d" ]] && skip=1; done
        (( skip == 0 )) && enabled+=("$comp")
    done < <(docker compose -f "$compose" config --services 2>/dev/null)

    log_info "${svc}: skipping disabled component(s): ${disabled[*]}"
    local rc=0
    if [[ ${#enabled[@]} -gt 0 ]]; then
        docker compose -f "$compose" up -d "$@" "${enabled[@]}" || rc=$?
    fi

    # Stop anything disabled that is running, and clear restart=always so a
    # daemon restart does not bring it back.
    local ids
    ids=$(docker compose -f "$compose" ps -aq "${disabled[@]}" 2>/dev/null)
    if [[ -n "$ids" ]]; then
        echo "$ids" | xargs -r docker update --restart=no >/dev/null 2>&1 || true
        echo "$ids" | xargs -r docker stop >/dev/null 2>&1 || true
    fi
    return $rc
}

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
