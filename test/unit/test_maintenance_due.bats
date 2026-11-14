#!/usr/bin/env bats
# When a scheduled maintenance task is due. due() lives inside the generated
# runner, so it is taken out of the heredoc and run against a fixed clock.

refute() { if "$@"; then echo "expected failure: $*"; return 1; fi; }

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    eval "$(sed -n '/^due() {/,/^}/p' "${REPO_ROOT}/lib/maintenance.sh")"
    declare -f due >/dev/null || { echo "due() not found"; false; }
    NOW=1800000000
    HOUR=3
    date() { if [[ "${1:-}" == "+%s" ]]; then echo "$NOW"; else echo "$HOUR"; fi; }
    state_get_last() { echo "$LAST"; }
    MAINTENANCE_BACKUP_ENABLED=true
    MAINTENANCE_BACKUP_INTERVAL_H=24
    MAINTENANCE_BACKUP_HOUR=3
}

@test "a backup 18 hours after an off-schedule run still runs at its hour" {
    LAST=$(( NOW - 18 * 3600 ))
    due backup
}

@test "a backup that ran an hour ago does not run again at its hour" {
    LAST=$(( NOW - 3600 ))
    refute due backup
}

@test "away from its hour a task waits until it is half an interval overdue" {
    HOUR=14
    LAST=$(( NOW - 30 * 3600 ))
    refute due backup
    LAST=$(( NOW - 36 * 3600 ))
    due backup
}

@test "an any-hour task needs its whole interval" {
    MAINTENANCE_UPDATES_ENABLED=true
    MAINTENANCE_UPDATES_INTERVAL_H=6
    MAINTENANCE_UPDATES_HOUR='*'
    LAST=$(( NOW - 5 * 3600 ))
    refute due updates
    LAST=$(( NOW - 6 * 3600 ))
    due updates
}

@test "a disabled task is never due" {
    MAINTENANCE_BACKUP_ENABLED=false
    LAST=0
    refute due backup
}
