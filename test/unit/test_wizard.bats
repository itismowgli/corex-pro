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

# This test used to be named "includes all services" and checked three of
# them. The name promised coverage the body did not deliver, which is why the
# dashboard, the shared login and the UPS monitor sat in no preset at all
# while it passed.
@test "apply_profile full includes every service module" {
    declare -a SELECTED_SERVICES=()
    apply_profile "full"
    local name
    while read -r name; do
        [[ -z "$name" ]] && continue
        [[ " ${SELECTED_SERVICES[*]} " == *" $name "* ]] \
            || { echo "the full preset omits $name"; return 1; }
    done < <(all_service_names)
}

# The preset test below iterates all_service_names, which sources each module
# with stderr discarded and emits nothing when SERVICE_NAME comes back empty.
# A module that cannot be read is therefore absent from that list, and every
# test built on the list passes while saying nothing at all. These two count
# the files on disk instead, so an unreadable module is a failure.
#
# What actually hides a module, measured rather than assumed: a syntax error
# positioned before the SERVICE_NAME assignment, and a file of binary
# rubbish. A syntax error after the assignment hides nothing, because bash
# executes a sourced file a command at a time and the name is already set by
# the time the parse fails.
@test "every service module file declares a name when sourced" {
    local dir f base name
    dir="${REPO_DIR}/lib/services"
    for f in "${dir}"/*.sh; do
        [[ -f "$f" ]] || continue
        base="$(basename "$f")"
        name=$(bash -c "source '$f' 2>/dev/null; echo \"\${SERVICE_NAME:-}\"")
        [[ -n "$name" ]] \
            || { echo "$base sets no SERVICE_NAME, so discovery cannot see it at all"; return 1; }
    done
}

@test "discovery finds every module file that is not hidden" {
    local dir f base hidden on_disk=0 discovered
    dir="${REPO_DIR}/lib/services"
    for f in "${dir}"/*.sh; do
        [[ -f "$f" ]] || continue
        hidden=$(bash -c "source '$f' 2>/dev/null; echo \"\${SERVICE_HIDDEN:-false}\"")
        [[ "$hidden" == "true" ]] && continue
        on_disk=$(( on_disk + 1 ))
    done
    discovered=$(all_service_names | grep -c .)
    [[ "$discovered" -eq "$on_disk" ]] \
        || { echo "$on_disk visible module files on disk, $discovered discovered: one fails to source"; return 1; }
}

# A macOS tar or SMB share leaves ._name.sh beside the real module, and it is
# binary. Bash never sees it, because *.sh does not match a leading dot, so
# the loops above cannot check for one and neither can the wizard. The agent
# reads the same directory from Python, where iterdir and listdir do return
# it, and one of these killed service discovery with a UnicodeDecodeError. So
# the check has to name dotfiles explicitly to exist at all.
@test "no AppleDouble sidecar sits beside a service module" {
    local found
    found=$(find "${REPO_DIR}/lib/services" -maxdepth 1 -name '._*' -print)
    [[ -z "$found" ]] \
        || { echo "AppleDouble sidecars present, invisible to bash and binary to Python:"; echo "$found"; return 1; }
}

@test "every service module appears in at least one preset" {
    local name p found
    while read -r name; do
        [[ -z "$name" ]] && continue
        found=false
        for p in minimal full privacy dev nodomain; do
            declare -a SELECTED_SERVICES=()
            apply_profile "$p"
            if [[ " ${SELECTED_SERVICES[*]} " == *" $name "* ]]; then
                found=true
                break
            fi
        done
        [[ "$found" == "true" ]] \
            || { echo "$name is offered by no preset, so only a custom install can reach it"; return 1; }
    done < <(all_service_names)
}

@test "the LAN-only preset holds nothing that needs a domain" {
    declare -a SELECTED_SERVICES=()
    apply_profile "nodomain"
    local s
    for s in "${SELECTED_SERVICES[@]}"; do
        service_works_without_domain "$s" \
            || { echo "$s needs a domain and is in the LAN-only preset"; return 1; }
    done
    # And it is not empty, which would pass the loop above trivially.
    [ "${#SELECTED_SERVICES[@]}" -gt 3 ]
}

@test "a LAN-only install drops services that need a domain" {
    declare -a SELECTED_SERVICES=(traefik adguard nextcloud calcom timemachine)
    filter_services_for_mode "local-only"
    [[ " ${SELECTED_SERVICES[*]} " == *" traefik "* ]]
    [[ " ${SELECTED_SERVICES[*]} " == *" timemachine "* ]]
    [[ " ${SELECTED_SERVICES[*]} " != *" nextcloud "* ]]
    [[ " ${SELECTED_SERVICES[*]} " != *" calcom "* ]]
}

@test "a with-domain install drops nothing" {
    declare -a SELECTED_SERVICES=(traefik nextcloud calcom)
    filter_services_for_mode "with-domain"
    [[ " ${SELECTED_SERVICES[*]} " == *" nextcloud "* ]]
    [[ " ${SELECTED_SERVICES[*]} " == *" calcom "* ]]
}

# Traefik creates proxy-net and owns the routing every other web service
# registers with, and the installer deploys in array order, so this is the one
# ordering fact that cannot be got wrong.
@test "traefik is deployed first whatever the preset" {
    local p
    for p in minimal full privacy dev nodomain; do
        declare -a SELECTED_SERVICES=()
        apply_profile "$p"
        order_services_for_deploy
        [[ "${SELECTED_SERVICES[0]}" == "traefik" ]] \
            || { echo "$p starts with ${SELECTED_SERVICES[0]}, not traefik"; return 1; }
    done
}

# A router naming a middleware that is not defined yet answers 404 rather than
# falling back, so the module that defines one deploys before the modules that
# reference it.
@test "authelia is deployed before the services it protects" {
    declare -a SELECTED_SERVICES=(n8n monitoring authelia portainer traefik)
    order_services_for_deploy
    local i auth=-1 n8n=-1 mon=-1
    for i in "${!SELECTED_SERVICES[@]}"; do
        [[ "${SELECTED_SERVICES[$i]}" == "authelia" ]] && auth=$i
        [[ "${SELECTED_SERVICES[$i]}" == "n8n" ]] && n8n=$i
        [[ "${SELECTED_SERVICES[$i]}" == "monitoring" ]] && mon=$i
    done
    [ "$auth" -ge 0 ]
    [ "$auth" -lt "$n8n" ]
    [ "$auth" -lt "$mon" ]
}

@test "ordering keeps every selected service" {
    declare -a SELECTED_SERVICES=()
    apply_profile "full"
    local before="${#SELECTED_SERVICES[@]}"
    order_services_for_deploy
    [ "${#SELECTED_SERVICES[@]}" -eq "$before" ]
}

# SERVICE_NEEDS_DOMAIN was declared by all eighteen modules and read by
# nothing for the life of the project, so a LAN-only install cheerfully
# selected services that answer on a hostname it does not have.
@test "SERVICE_NEEDS_DOMAIN is read by something" {
    # maxdepth 1 is what excludes lib/services, where every module declares
    # it. find rather than grep --include, because the test image is BusyBox.
    find "${REPO_DIR}/lib" -maxdepth 1 -name "*.sh" -exec grep -l "SERVICE_NEEDS_DOMAIN" {} + \
        | grep -q .
}
