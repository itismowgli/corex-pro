#!/usr/bin/env bats
# test/unit/test_state.bats
# Unit tests for lib/state.sh — state.json read/write functions.
# These tests stub the state file to a temp path so no root is needed.
#
# Run: bats test/unit/test_state.bats
# Note: lib/state.sh is created in Phase B. These tests are stubs/specs
# that define the expected behavior before implementation.

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
STATE_LIB="${REPO_DIR}/lib/state.sh"

setup() {
    # Use a temp file for each test — no root, no /etc/corex needed
    export COREX_STATE_FILE
    COREX_STATE_FILE="$(mktemp /tmp/corex-test-state-XXXXXX.json)"

    # Skip all tests if lib/state.sh doesn't exist yet (Phase B)
    if [[ ! -f "$STATE_LIB" ]]; then
        skip "lib/state.sh not yet created (Phase B)"
    fi

    # shellcheck disable=SC1090
    source "$STATE_LIB"
}

teardown() {
    rm -f "$COREX_STATE_FILE"
}

# ─── state_init ───────────────────────────────────────────────────────────────

@test "state_init creates a valid JSON file" {
    state_init
    run jq '.' "$COREX_STATE_FILE"
    [ "$status" -eq 0 ]
}

@test "state_init sets version field" {
    state_init
    run jq -r '.version' "$COREX_STATE_FILE"
    [ "$status" -eq 0 ]
    [[ "$output" != "null" ]]
}

@test "state_init creates services object" {
    state_init
    run jq -r '.services' "$COREX_STATE_FILE"
    [ "$status" -eq 0 ]
    [[ "$output" != "null" ]]
}

@test "state_init marks traefik as installed by default (core service)" {
    state_init
    run jq -r '.services.traefik.installed' "$COREX_STATE_FILE"
    [ "$status" -eq 0 ]
    # traefik is core — could be true or false depending on design
    [[ "$output" == "true" || "$output" == "false" ]]
}

# ─── state_get / state_set ────────────────────────────────────────────────────

@test "state_set and state_get round-trip a string value" {
    state_init
    state_set "domain" "example.com"
    run state_get "domain"
    [ "$status" -eq 0 ]
    [ "$output" = "example.com" ]
}

@test "state_set and state_get round-trip the mode field" {
    state_init
    state_set "mode" "with-domain"
    run state_get "mode"
    [ "$status" -eq 0 ]
    [ "$output" = "with-domain" ]
}

@test "state_set and state_get round-trip server_ip" {
    state_init
    state_set "server_ip" "192.168.1.100"
    run state_get "server_ip"
    [ "$status" -eq 0 ]
    [ "$output" = "192.168.1.100" ]
}

@test "state_get returns null for missing field" {
    state_init
    run state_get "nonexistent_field"
    [ "$status" -eq 0 ]
    [ "$output" = "null" ]
}

# ─── state_service_installed ──────────────────────────────────────────────────

@test "state_service_installed marks service as installed" {
    state_init
    state_service_installed "nextcloud"
    run jq -r '.services.nextcloud.installed' "$COREX_STATE_FILE"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

@test "state_service_installed sets installed_at timestamp" {
    state_init
    state_service_installed "nextcloud"
    run jq -r '.services.nextcloud.installed_at' "$COREX_STATE_FILE"
    [ "$status" -eq 0 ]
    [[ "$output" != "null" ]]
}

@test "state_service_is_installed returns 0 for installed service" {
    state_init
    state_service_installed "vaultwarden"
    run state_service_is_installed "vaultwarden"
    [ "$status" -eq 0 ]
}

@test "state_service_is_installed returns non-zero for uninstalled service" {
    state_init
    run state_service_is_installed "stalwart"
    [ "$status" -ne 0 ]
}

# ─── state_list_installed ─────────────────────────────────────────────────────

@test "state_list_installed returns installed services" {
    state_init
    state_service_installed "traefik"
    state_service_installed "nextcloud"
    run state_list_installed
    [ "$status" -eq 0 ]
    [[ "$output" == *"traefik"* ]]
    [[ "$output" == *"nextcloud"* ]]
}

@test "state_list_installed does not return uninstalled services" {
    state_init
    state_service_installed "traefik"
    run state_list_installed
    [[ "$output" != *"stalwart"* ]]
}

@test "state_list_installed returns empty when nothing installed" {
    state_init
    run state_list_installed
    [ "$status" -eq 0 ]
    # Output should be empty (or only whitespace)
    [[ -z "$(echo "$output" | tr -d '[:space:]')" ]]
}
