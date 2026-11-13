#!/usr/bin/env bats
# corex manage heartbeat: what URL it accepts, and when a beat is not sent.

refute() { if "$@"; then echo "expected failure: $*"; return 1; fi; }

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    WORK=$(mktemp -d /tmp/corex-heartbeat-XXXXXX)
    export HEARTBEAT_CONF="${WORK}/heartbeat.conf"
    export HEARTBEAT_BIN="${WORK}/corex-heartbeat.sh"
    export HEARTBEAT_STATE="${WORK}/heartbeat.last"
    source "${REPO_ROOT}/lib/heartbeat.sh"
    log_success() { :; }
    log_info() { :; }
    log_warning() { echo "$*" >&2; }
    # Stand-ins on PATH, so the generated script runs for real.
    mkdir -p "${WORK}/bin"
    printf '#!/bin/bash\necho "$@" >> "%s/curl.log"\nexit "${CURL_RC:-0}"\n' "$WORK" > "${WORK}/bin/curl"
    printf '#!/bin/bash\nexit "${DOCKER_RC:-0}"\n' > "${WORK}/bin/docker"
    # GNU timeout is absent on macOS. Without a stand-in every check fails on
    # "command not found" and the refusal tests pass for the wrong reason.
    printf '#!/bin/bash\nshift\nexec "$@"\n' > "${WORK}/bin/timeout"
    chmod +x "${WORK}/bin/curl" "${WORK}/bin/docker" "${WORK}/bin/timeout"
    PATH="${WORK}/bin:${PATH}"
}

teardown() { rm -rf "$WORK"; }

write_conf() { printf 'HEARTBEAT_URL="%s"\n' "$1" > "$HEARTBEAT_CONF"; }

@test "heartbeat accepts an https check URL and nothing else" {
    heartbeat_valid_url 'https://hc-ping.com/1b2c3d4e-0000-4000-8000-123456789abc'
    heartbeat_valid_url 'https://kuma.example.org/api/push/AbC123?status=up&msg=OK'
    refute heartbeat_valid_url 'http://hc-ping.com/abc'
    refute heartbeat_valid_url 'https://hc-ping.com/a b'
    refute heartbeat_valid_url 'https://hc-ping.com/$(id)'
    refute heartbeat_valid_url 'https://hc-ping.com/`id`'
    refute heartbeat_valid_url 'https://hc-ping.com/a";rm -rf /'
    refute heartbeat_valid_url ''
}

@test "heartbeat never prints the token in the URL" {
    write_conf 'https://hc-ping.com/1b2c3d4e-secret'
    [ "$(heartbeat_url_masked)" = "https://hc-ping.com/..." ]
    refute grep -q 'secret' <<< "$(heartbeat_status 2>&1 || true)"
}

@test "a beat is sent when the disk and Docker answer, and its time is recorded" {
    write_conf 'https://hc-ping.com/abc'
    _heartbeat_write_script
    "$HEARTBEAT_BIN"
    grep -q 'https://hc-ping.com/abc' "${WORK}/curl.log"
    [[ "$(cat "$HEARTBEAT_STATE")" =~ ^[0-9]+$ ]]
}

@test "no beat is sent when Docker does not answer" {
    write_conf 'https://hc-ping.com/abc'
    _heartbeat_write_script
    DOCKER_RC=1 run "$HEARTBEAT_BIN"
    [ "$status" -ne 0 ]
    refute grep -q 'command not found' <<< "$output"
    [ ! -e "${WORK}/curl.log" ]
    [ ! -e "$HEARTBEAT_STATE" ]
}

@test "no beat is sent when the disk cannot be written" {
    write_conf 'https://hc-ping.com/abc'
    _heartbeat_write_script
    HEARTBEAT_STATE="${WORK}/no-such-dir/heartbeat.last" run "$HEARTBEAT_BIN"
    [ "$status" -ne 0 ]
    refute grep -q 'command not found' <<< "$output"
    [ ! -e "${WORK}/curl.log" ]
}

@test "a refused beat is not recorded as sent" {
    write_conf 'https://hc-ping.com/abc'
    _heartbeat_write_script
    CURL_RC=22 run "$HEARTBEAT_BIN"
    [ "$status" -ne 0 ]
    [ ! -e "$HEARTBEAT_STATE" ]
}

@test "the request carries nothing about this machine" {
    grep -q -- '-A "corex-heartbeat"' "${REPO_ROOT}/lib/heartbeat.sh"
    refute grep -qE 'hostname|SERVER_IP|DOMAIN' "${REPO_ROOT}/lib/heartbeat.sh"
}

@test "self-recovery regenerates the heartbeat and says when there is none" {
    grep -q 'heartbeat_setup' "${REPO_ROOT}/lib/recovery.sh"
    grep -q 'No outside heartbeat' "${REPO_ROOT}/lib/recovery.sh"
}
