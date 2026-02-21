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
_COREX_VERSION="2.0.0"

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
            cloudflare_tunnel_configured: false,
            services: {}
        }' > "$COREX_STATE_FILE"

    chmod 600 "$COREX_STATE_FILE"
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
    local key="$1"
    local value="$2"
    local tmp
    tmp="$(mktemp)"
    jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$COREX_STATE_FILE" > "$tmp" \
        && mv "$tmp" "$COREX_STATE_FILE"
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
    jq --arg svc "$svc" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '.services[$svc] = { installed: true, enabled: true, installed_at: $ts }' \
        "$COREX_STATE_FILE" > "$tmp" && mv "$tmp" "$COREX_STATE_FILE"
}

# ── state_service_removed ─────────────────────────────────────────────────────
# Mark a service as not installed.
#
# Usage: state_service_removed "nextcloud"
state_service_removed() {
    local svc="$1"
    local tmp
    tmp="$(mktemp)"
    jq --arg svc "$svc" \
        '.services[$svc] = { installed: false, enabled: false }' \
        "$COREX_STATE_FILE" > "$tmp" && mv "$tmp" "$COREX_STATE_FILE"
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
    jq --arg svc "$svc" '.services[$svc].enabled = true' "$COREX_STATE_FILE" > "$tmp" \
        && mv "$tmp" "$COREX_STATE_FILE"
}

state_service_disable() {
    local svc="$1"
    local tmp
    tmp="$(mktemp)"
    jq --arg svc "$svc" '.services[$svc].enabled = false' "$COREX_STATE_FILE" > "$tmp" \
        && mv "$tmp" "$COREX_STATE_FILE"
}
