#!/bin/bash
# lib/state.sh — CoreX Pro v2
# Read/write /etc/corex/state.json.
# Tracks installed services, mode, domain, and server configuration.
#
# Requires: jq (installed via apt-get in Phase 2)
# State file: /etc/corex/state.json (or $COREX_STATE_FILE for testing)
#
# Usage: source lib/state.sh

# Allow tests to override the state file path via env var
COREX_STATE_FILE="${COREX_STATE_FILE:-/etc/corex/state.json}"
_COREX_VERSION="3.8.0"

# ── state_init ────────────────────────────────────────────────────────────────
# Create a fresh state.json with default structure.
# Safe to call on re-runs — only writes if the file doesn't exist.
state_init() {
    local state_dir
    state_dir="$(dirname "$COREX_STATE_FILE")"
    mkdir -p "$state_dir"

    if [[ -f "$COREX_STATE_FILE" ]]; then
        return 0  # Already initialized
    fi

    jq -n \
        --arg version "$_COREX_VERSION" \
        --arg installed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            version: $version,
            installed_at: $installed_at,
            mode: "with-domain",
            domain: "",
            server_ip: "",
            email: "",
            ssh_port: "22",
            timezone: "UTC",
            cloudflare_tunnel_configured: false,
            services: {}
        }' > "$COREX_STATE_FILE"

    chmod 644 "$COREX_STATE_FILE"
}

# ── The no-secrets invariant ──────────────────────────────────────────────────
# state.json is mode 0644 and is bind-mounted read-only into the dashboard
# container, so it MUST NOT hold credentials. It once held
# cloudflare_tunnel_token, which put a live tunnel credential inside a
# web-facing container; the token now lives in a 0600 dotfile beside the
# service that needs it, the way every other CoreX secret does.
#
# state_set enforces this rather than trusting callers to remember.
_COREX_STATE_SECRET_KEYS="token secret password passwd pass key credential"

_state_is_secret_key() {
    local key="$1" pat
    for pat in $_COREX_STATE_SECRET_KEYS; do
        [[ "$key" == *"$pat"* ]] && return 0
    done
    return 1
}

# ── state_strip_secrets ───────────────────────────────────────────────────────
# Remove any secret-looking key left in an existing state.json by a CoreX
# version that predates the invariant above. Callers migrate the value
# somewhere safe first; this only deletes.
state_strip_secrets() {
    [[ -f "$COREX_STATE_FILE" ]] || return 0
    local key found=0
    for key in $(jq -r 'keys[]' "$COREX_STATE_FILE" 2>/dev/null); do
        _state_is_secret_key "$key" || continue
        local tmp
        tmp="$(mktemp)"
        jq --arg k "$key" 'del(.[$k])' "$COREX_STATE_FILE" > "$tmp" \
            && mv "$tmp" "$COREX_STATE_FILE" && chmod 644 "$COREX_STATE_FILE"
        rm -f "$tmp"
        found=1
    done
    [[ "$found" == "1" ]] && return 0
    return 0
}

# ── state_get ─────────────────────────────────────────────────────────────────
# Read a top-level field from state.json.
# Prints the value (or "null" if missing). Returns 0 always.
#
# Usage: value=$(state_get "domain")
state_get() {
    local key="$1"
    jq -r ".$key // \"null\"" "$COREX_STATE_FILE" 2>/dev/null || echo "null"
}

# ── state_set ─────────────────────────────────────────────────────────────────
# Write a top-level string field to state.json.
#
# Usage: state_set "domain" "example.com"
state_set() {
    # Strip double quotes from the value. A v1 migration regex once captured
    # the quotes around a YAML field, so state.json held
    # domain="\"example.com\"". Everything reading it then built URLs like
    # https://sub."example.com", which is how every dashboard link broke.
    set -- "$1" "${2//\"/}"
    local key="$1"
    local value="$2"

    # Refuse to write a credential. See the no-secrets invariant above.
    if _state_is_secret_key "$key"; then
        echo "state_set: refusing to write secret-looking key '$key' to state.json" >&2
        return 1
    fi

    local tmp
    tmp="$(mktemp)"
    trap 'rm -f "${tmp:-}"' RETURN
    # mv preserves mktemp's 0600, which would make state.json unreadable to
    # the dashboard container on the next write. Restore the mode explicitly.
    jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$COREX_STATE_FILE" > "$tmp" \
        && mv "$tmp" "$COREX_STATE_FILE" \
        && chmod 644 "$COREX_STATE_FILE"
}

# ── state_service_installed ───────────────────────────────────────────────────
# Mark a service as installed in state.json. Sets installed=true and
# records the current timestamp as installed_at.
#
# Usage: state_service_installed "nextcloud"
state_service_installed() {
    local svc="$1"
    local tmp
    tmp="$(mktemp)"
    trap 'rm -f "${tmp:-}"' RETURN
    jq --arg svc "$svc" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '.services[$svc] = { installed: true, enabled: true, installed_at: $ts }' \
        "$COREX_STATE_FILE" > "$tmp" && mv "$tmp" "$COREX_STATE_FILE" \
        && chmod 644 "$COREX_STATE_FILE"
}

# ── state_service_removed ─────────────────────────────────────────────────────
# Mark a service as not installed.
#
# Usage: state_service_removed "nextcloud"
state_service_removed() {
    local svc="$1"
    local tmp
    tmp="$(mktemp)"
    trap 'rm -f "${tmp:-}"' RETURN
    jq --arg svc "$svc" \
        '.services[$svc] = { installed: false, enabled: false }' \
        "$COREX_STATE_FILE" > "$tmp" && mv "$tmp" "$COREX_STATE_FILE" \
        && chmod 644 "$COREX_STATE_FILE"
}

# ── state_service_is_installed ────────────────────────────────────────────────
# Returns 0 (true) if the service is marked installed, non-zero otherwise.
#
# Usage: if state_service_is_installed "nextcloud"; then ...
state_service_is_installed() {
    local svc="$1"
    local val
    val=$(jq -r ".services[\"$svc\"].installed // false" "$COREX_STATE_FILE" 2>/dev/null)
    [[ "$val" == "true" ]]
}

# ── state_list_installed ──────────────────────────────────────────────────────
# Print a newline-separated list of all installed service names.
# Prints nothing if nothing is installed.
#
# Usage: state_list_installed
state_list_installed() {
    jq -r '.services | to_entries[] | select(.value.installed == true) | .key' \
        "$COREX_STATE_FILE" 2>/dev/null || true
}

# ── state_service_enable / disable ────────────────────────────────────────────
state_service_enable() {
    local svc="$1"
    local tmp
    tmp="$(mktemp)"
    trap 'rm -f "${tmp:-}"' RETURN
    jq --arg svc "$svc" '.services[$svc].enabled = true' "$COREX_STATE_FILE" > "$tmp" \
        && mv "$tmp" "$COREX_STATE_FILE" \
        && chmod 644 "$COREX_STATE_FILE"
}

state_service_disable() {
    local svc="$1"
    local tmp
    tmp="$(mktemp)"
    trap 'rm -f "${tmp:-}"' RETURN
    jq --arg svc "$svc" '.services[$svc].enabled = false' "$COREX_STATE_FILE" > "$tmp" \
        && mv "$tmp" "$COREX_STATE_FILE" \
        && chmod 644 "$COREX_STATE_FILE"
}
