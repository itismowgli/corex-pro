#!/usr/bin/env bats
# A restart that comes back. On 2026-11-13 an ordinary reboot left the
# machine dark for seven hours, and a power-off with a clock alarm did not.

refute() { if "$@"; then echo "expected failure: $*"; return 1; fi; }

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    export POWER_CONF="${BATS_TEST_TMPDIR}/etc/power.conf"
    export POWER_RTC_ALARM="${BATS_TEST_TMPDIR}/wakealarm"
    : > "$POWER_RTC_ALARM"
    BIN="${BATS_TEST_TMPDIR}/bin"
    CALLS="${BATS_TEST_TMPDIR}/calls"
    mkdir -p "$BIN"
    : > "$CALLS"
    local t
    for t in rtcwake systemctl sync; do
        printf '#!/bin/bash\necho "%s $*" >> "%s"\nexit ${STUB_RC_%s:-0}\n' "$t" "$CALLS" "$t" > "${BIN}/${t}"
        chmod +x "${BIN}/${t}"
    done
    PATH="${BIN}:${PATH}"
    source "${REPO_ROOT}/lib/common.sh"
    source "${REPO_ROOT}/lib/power.sh"
}

@test "a restart is an ordinary reboot until the mode is set" {
    [ "$(power_restart_mode)" = "reboot" ]
    run power_restart
    grep -qx 'systemctl reboot' "$CALLS"
    refute grep -q '^rtcwake' "$CALLS"
}

@test "power-cycle switches off with the alarm set and does not reboot" {
    power_restart_mode_set power-cycle
    [ "$(power_restart_mode)" = "power-cycle" ]
    run power_restart
    [ "$status" -eq 0 ]
    grep -qx 'rtcwake -m off -s 300' "$CALLS"
    refute grep -q 'systemctl reboot' "$CALLS"
}

@test "what is on disk is flushed before the power goes" {
    power_restart_mode_set power-cycle
    run power_restart
    [ "$(grep -n '^sync' "$CALLS" | cut -d: -f1)" -lt "$(grep -n '^rtcwake' "$CALLS" | cut -d: -f1)" ]
}

@test "power-cycle is refused on a machine with no clock alarm" {
    rm -f "$POWER_RTC_ALARM"
    run power_restart_mode_set power-cycle
    [ "$status" -ne 0 ]
    [ "$(power_restart_mode)" = "reboot" ]
}

@test "an alarm that cannot be set falls back to a reboot, not to a power-off" {
    power_restart_mode_set power-cycle
    export STUB_RC_rtcwake=1
    run power_restart
    grep -qx 'systemctl reboot' "$CALLS"
}

@test "an alarm that has gone missing since falls back to a reboot" {
    power_restart_mode_set power-cycle
    rm -f "$POWER_RTC_ALARM"
    run power_restart
    grep -qx 'systemctl reboot' "$CALLS"
    refute grep -q '^rtcwake' "$CALLS"
}

@test "an unknown mode is refused and changes nothing" {
    power_restart_mode_set power-cycle
    run power_restart_mode_set halt
    [ "$status" -ne 0 ]
    [ "$(power_restart_mode)" = "power-cycle" ]
}

@test "changing the CPU settings file keeps the restart mode" {
    power_restart_mode_set power-cycle
    _power_cpu_read
    POWER_CPU_MAX_MHZ=3000
    _power_cpu_write_conf
    [ "$(power_restart_mode)" = "power-cycle" ]
    grep -q 'power_restart_mode\|_power_cpu_read' <<< "$(declare -f power_cpu_set)"
    grep -q '_power_cpu_read' <<< "$(declare -f power_cpu_reset)"
}

@test "the dashboard restart goes through the same command" {
    grep -q '"reboot":.*MANAGE, "power", "restart"' "${REPO_ROOT}/agent/corex-agent.py"
}
