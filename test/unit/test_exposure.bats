#!/usr/bin/env bats
# What the internet can reach. Each test is a hole that was open on a live box.

refute() { if "$@"; then echo "expected failure: $*"; return 1; fi; }

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
}

@test "keys-only SSH sorts ahead of cloud-init, because sshd keeps the first value" {
    local f
    f=$(grep -oE '/etc/ssh/sshd_config.d/[0-9]+-corex-auth.conf' "${REPO_ROOT}/lib/security.sh")
    [ -n "$f" ]
    [[ "$(basename "$f")" < "50-cloud-init.conf" ]]
    grep -q 'PasswordAuthentication no' "${REPO_ROOT}/lib/security.sh"
    # Never without a key: that is a lockout.
    grep -q 'authorized_keys' "${REPO_ROOT}/lib/security.sh"
    grep -q '_security_ssh_keys_only$' "${REPO_ROOT}/lib/security.sh"
}

@test "the IPv6 guard drops only new connections from global addresses, never ICMPv6" {
    local body
    body=$(sed -n '/^_security_ipv6_guard() {/,/^}/p' "${REPO_ROOT}/lib/security.sh")
    echo "$body" | grep -q -- '-t mangle'
    echo "$body" | grep -q -- '-s 2000::/3'
    echo "$body" | grep -q -- '! -p ipv6-icmp'
    echo "$body" | grep -q -- '--ctstate NEW'
    # Checked before inserted, so a re-run does not stack duplicates.
    echo "$body" | grep -q -- '-C PREROUTING'
    grep -q '_security_ipv6_guard$' "${REPO_ROOT}/lib/security.sh"
}

@test "vaultwarden's admin panel is LAN-only when the allowlist exists, and absent otherwise" {
    local work
    work=$(mktemp -d)
    mkdir -p "${work}/traefik/dynamic"
    DOCKER_ROOT="$work" DOMAIN=example.com
    source "${REPO_ROOT}/lib/services/vaultwarden.sh"
    run _vaultwarden_admin_labels
    [ -z "$output" ]
    touch "${work}/traefik/dynamic/corex-lan.yml"
    run _vaultwarden_admin_labels
    [[ "$output" == *'PathPrefix(`/admin`)'* ]]
    [[ "$output" == *'vw-admin.middlewares=corex-lan@file'* ]]
    [[ "$output" == *'Host(`vault.example.com`)'* ]]
    refute grep -q '\\`' <<< "$output"
    rm -rf "$work"
}

@test "crowdsec reads a real log, not the image's placeholder" {
    grep -q '_crowdsec_write_acquis$' "${REPO_ROOT}/lib/services/crowdsec.sh"
    grep -q '/var/log/auth.log' "${REPO_ROOT}/lib/services/crowdsec.sh"
    refute grep -q 'bouncers add.*--force' "${REPO_ROOT}/lib/services/crowdsec.sh"
}
