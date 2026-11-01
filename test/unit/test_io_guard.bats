#!/usr/bin/env bats
# corex manage io-guard set: what it refuses, and what it writes.

refute() { if "$@"; then echo "expected failure: $*"; return 1; fi; }

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    WORK=$(mktemp -d /tmp/corex-ioguard-XXXXXX)
    export IO_GUARD_CONF="${WORK}/io-guard.conf"
    systemctl() { :; }
    source "${REPO_ROOT}/lib/io_guard.sh"
    log_success() { :; }
    log_warning() { echo "$*" >&2; }
}

teardown() { rm -rf "$WORK"; }

@test "io-guard set writes a valid value and leaves the rest of the file alone" {
    io_guard_set stall 300
    grep -qx 'IO_GUARD_STALL_SEC=300' "$IO_GUARD_CONF"
    grep -qx 'IO_GUARD_ACTION=reboot' "$IO_GUARD_CONF"
    io_guard_set action alert
    grep -qx 'IO_GUARD_ACTION=alert' "$IO_GUARD_CONF"
    io_guard_set action power-cycle
    grep -qx 'IO_GUARD_ACTION=power-cycle' "$IO_GUARD_CONF"
    io_guard_set action alert
    grep -qx 'IO_GUARD_STALL_SEC=300' "$IO_GUARD_CONF"
    io_guard_set enabled off
    grep -qx 'IO_GUARD_ENABLED=false' "$IO_GUARD_CONF"
    [ "$(grep -c '^IO_GUARD_STALL_SEC=' "$IO_GUARD_CONF")" -eq 1 ]
}

@test "io-guard set refuses a limit that would reboot on a slow write" {
    refute io_guard_set stall 5
    refute io_guard_set stall 99999
    refute io_guard_set grace 10
    refute io_guard_set action format
    refute io_guard_set enabled maybe
    refute io_guard_set nonsense 1
}

@test "io-guard set refuses a device list that is not plain names" {
    refute io_guard_set devices '../../etc'
    refute io_guard_set devices 'dm-0; reboot'
    io_guard_set devices 'dm-0 nvme0n1'
    grep -qx 'IO_GUARD_DEVICES="dm-0 nvme0n1"' "$IO_GUARD_CONF"
}

@test "the guard is installed with self-recovery and locks itself in memory" {
    grep -q 'io_guard_install' "${REPO_ROOT}/lib/recovery.sh"
    grep -q 'LimitMEMLOCK=infinity' "${REPO_ROOT}/lib/io_guard.sh"
    grep -q 'mlockall' "${REPO_ROOT}/agent/corex-io-guard.py"
}
