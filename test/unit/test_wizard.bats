#!/usr/bin/env bats
# test/unit/test_wizard.bats
# Unit tests for wizard input validation functions from lib/wizard.sh.
# These test pure bash validation logic — no UI, no whiptail, no stdin.
#
# Run: bats test/unit/test_wizard.bats
# Note: lib/wizard.sh is created in Phase D. These tests are specs that
# define expected validation behavior before implementation.

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
WIZARD_LIB="${REPO_DIR}/lib/wizard.sh"

setup() {
    if [[ ! -f "$WIZARD_LIB" ]]; then
        skip "lib/wizard.sh not yet created (Phase D)"
    fi
    # shellcheck disable=SC1090
    source "$WIZARD_LIB"
}

# ─── IP Address Validation ────────────────────────────────────────────────────

@test "validate_ip accepts valid IPv4 address" {
    run validate_ip "192.168.1.100"
    [ "$status" -eq 0 ]
}

@test "validate_ip accepts another valid IPv4 address" {
    run validate_ip "10.0.0.1"
    [ "$status" -eq 0 ]
}

@test "validate_ip rejects non-numeric octets" {
    run validate_ip "192.168.abc.1"
    [ "$status" -ne 0 ]
}

@test "validate_ip rejects missing octets" {
    run validate_ip "192.168.1"
    [ "$status" -ne 0 ]
}

@test "validate_ip rejects out-of-range octet" {
    run validate_ip "192.168.1.300"
    [ "$status" -ne 0 ]
}

@test "validate_ip rejects empty string" {
    run validate_ip ""
    [ "$status" -ne 0 ]
}

# ─── Domain Validation ────────────────────────────────────────────────────────

@test "validate_domain accepts valid domain" {
    run validate_domain "example.com"
    [ "$status" -eq 0 ]
}

@test "validate_domain accepts subdomain" {
    run validate_domain "home.example.com"
    [ "$status" -eq 0 ]
}

@test "validate_domain rejects domain without TLD" {
    run validate_domain "localhost"
    [ "$status" -ne 0 ]
}

@test "validate_domain rejects empty string" {
    run validate_domain ""
    [ "$status" -ne 0 ]
}

@test "validate_domain rejects domain with spaces" {
    run validate_domain "my domain.com"
    [ "$status" -ne 0 ]
}

@test "validate_domain rejects domain starting with dot" {
    run validate_domain ".example.com"
    [ "$status" -ne 0 ]
}

# ─── Email Validation ─────────────────────────────────────────────────────────

@test "validate_email accepts valid email" {
    run validate_email "admin@example.com"
    [ "$status" -eq 0 ]
}

@test "validate_email accepts email with subdomain" {
    run validate_email "user@mail.example.com"
    [ "$status" -eq 0 ]
}

@test "validate_email rejects email without @" {
    run validate_email "adminexample.com"
    [ "$status" -ne 0 ]
}

@test "validate_email rejects email without domain" {
    run validate_email "admin@"
    [ "$status" -ne 0 ]
}

@test "validate_email rejects empty string" {
    run validate_email ""
    [ "$status" -ne 0 ]
}

# ─── Service Category Grouping ────────────────────────────────────────────────

@test "get_services_in_category returns services for storage category" {
    if ! declare -f get_services_in_category &>/dev/null; then
        skip "get_services_in_category not implemented yet"
    fi
    run get_services_in_category "storage"
    [ "$status" -eq 0 ]
    [[ "$output" == *"nextcloud"* || "$output" == *"immich"* ]]
}

@test "get_services_in_category returns services for core category" {
    if ! declare -f get_services_in_category &>/dev/null; then
        skip "get_services_in_category not implemented yet"
    fi
    run get_services_in_category "core"
    [ "$status" -eq 0 ]
    [[ "$output" == *"traefik"* ]]
}

# ─── Profile Selection ────────────────────────────────────────────────────────

@test "apply_profile minimal includes vaultwarden" {
    if ! declare -f apply_profile &>/dev/null; then
        skip "apply_profile not implemented yet"
    fi
    declare -a SELECTED_SERVICES=()
    apply_profile "minimal"
    [[ " ${SELECTED_SERVICES[*]} " == *" vaultwarden "* ]]
}

@test "apply_profile full includes all services" {
    if ! declare -f apply_profile &>/dev/null; then
        skip "apply_profile not implemented yet"
    fi
    declare -a SELECTED_SERVICES=()
    apply_profile "full"
    [[ " ${SELECTED_SERVICES[*]} " == *" nextcloud "* ]]
    [[ " ${SELECTED_SERVICES[*]} " == *" immich "* ]]
    [[ " ${SELECTED_SERVICES[*]} " == *" ai "* ]]
}
