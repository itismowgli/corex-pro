#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export REPO_ROOT
    UPDATE_LIB="${REPO_ROOT}/lib/update-safety.sh"
    export UPDATE_LIB
}

_generated() {
    local marker="$1" file="$2"
    awk -v m="$marker" 'index($0, "<< \x27" m "\x27") { f = 1; next }
                        $0 == m { f = 0 }
                        f' "$file"
}

@test "update safety scripts parse" {
    run bash -n "$UPDATE_LIB"
    [ "$status" -eq 0 ]
    run bash -n "${REPO_ROOT}/corex-manage.sh"
    [ "$status" -eq 0 ]
    run bash -n "${REPO_ROOT}/lib/selfheal.sh"
    [ "$status" -eq 0 ]

    local recover="${BATS_TEST_TMPDIR}/recover.sh"
    _generated UREOF "${REPO_ROOT}/lib/selfheal.sh" > "$recover"
    run bash -n "$recover"
    [ "$status" -eq 0 ]
}

@test "hot update refuses before starting work" {
    # shellcheck disable=SC1090
    source "$UPDATE_LIB"
    update_cpu_temp() { echo 79; }
    COREX_UPDATE_MAX_TEMP_C=78
    run update_thermal_preflight "test update"
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing"* || "$output" == *"at or above"* ]]
}

@test "default update limit is proactive below the thermal warning band" {
    local conf="${BATS_TEST_TMPDIR}/thermal.conf"
    printf 'THERMAL_WARN_C=80\nTHERMAL_RECOVER_C=72\nTHERMAL_CLOCK_MIN_MHZ=1600\n' > "$conf"
    # shellcheck disable=SC1090
    source "$UPDATE_LIB"
    COREX_UPDATE_THERMAL_CONF="$conf"
    unset COREX_UPDATE_MAX_TEMP_C COREX_UPDATE_RESUME_TEMP_C
    _update_load_limits
    [ "$UPDATE_MAX_TEMP_C" -eq 78 ]
    [ "$UPDATE_RESUME_TEMP_C" -eq 70 ]
}

@test "governor pauses and resumes with hysteresis" {
    local seq="${BATS_TEST_TMPDIR}/temperatures" signals="${BATS_TEST_TMPDIR}/signals"
    printf '60\n79\n69\n60\n' > "$seq"
    : > "$signals"
    # shellcheck disable=SC1090
    source "$UPDATE_LIB"
    COREX_UPDATE_MAX_TEMP_C=78
    COREX_UPDATE_RESUME_TEMP_C=70
    COREX_UPDATE_POLL_SEC=0.02
    update_cpu_temp() {
        local first rest="${seq}.rest"
        first=$(head -1 "$seq")
        tail -n +2 "$seq" > "$rest"
        mv "$rest" "$seq"
        [[ -n "$first" ]] && echo "$first" || echo 60
    }
    _update_signal_tree() { echo "$2" >> "$signals"; }

    run update_run_governed "test pull" bash -c 'sleep 0.15'
    [ "$status" -eq 0 ]
    grep -q '^STOP$' "$signals"
    grep -q '^CONT$' "$signals"
}

@test "temporary CPU ceiling restores every policy exactly" {
    local root="${BATS_TEST_TMPDIR}/syscpu" state="${BATS_TEST_TMPDIR}/ceiling.state"
    mkdir -p "$root/cpu0/cpufreq" "$root/cpu7/cpufreq"
    printf '3200000\n' > "$root/cpu0/cpufreq/scaling_max_freq"
    printf '2750000\n' > "$root/cpu7/cpufreq/scaling_max_freq"
    # shellcheck disable=SC1090
    source "$UPDATE_LIB"
    COREX_CPU_SYSFS_ROOT="$root"
    COREX_UPDATE_CEILING_STATE="$state"
    COREX_UPDATE_CPU_MAX_MHZ=1600

    update_cpu_ceiling_begin
    [ "$(cat "$root/cpu0/cpufreq/scaling_max_freq")" = "1600000" ]
    [ "$(cat "$root/cpu7/cpufreq/scaling_max_freq")" = "1600000" ]
    update_cpu_ceiling_restore
    [ "$(cat "$root/cpu0/cpufreq/scaling_max_freq")" = "3200000" ]
    [ "$(cat "$root/cpu7/cpufreq/scaling_max_freq")" = "2750000" ]
    [ ! -e "$state" ]
}

@test "CPU ceiling deduplicates symlinks to one shared policy" {
    local root="${BATS_TEST_TMPDIR}/shared-syscpu" state="${BATS_TEST_TMPDIR}/shared.state"
    mkdir -p "$root/cpufreq/policy0" "$root/cpu0" "$root/cpu1"
    printf '3000000\n' > "$root/cpufreq/policy0/scaling_max_freq"
    ln -s ../cpufreq/policy0 "$root/cpu0/cpufreq"
    ln -s ../cpufreq/policy0 "$root/cpu1/cpufreq"
    # shellcheck disable=SC1090
    source "$UPDATE_LIB"
    COREX_CPU_SYSFS_ROOT="$root"
    COREX_UPDATE_CEILING_STATE="$state"
    COREX_UPDATE_CPU_MAX_MHZ=1600

    update_cpu_ceiling_begin
    [ "$(wc -l < "$state" | tr -d ' ')" = "1" ]
    [ "$(cat "$root/cpufreq/policy0/scaling_max_freq")" = "1600000" ]
    update_cpu_ceiling_restore
    [ "$(cat "$root/cpufreq/policy0/scaling_max_freq")" = "3000000" ]
}

@test "update session uses a nonblocking global flock" {
    local body
    body=$(sed -n '/^_update_lock_acquire()/,/^}/p' "$UPDATE_LIB")
    echo "$body" | grep -q 'COREX_UPDATE_LOCK'
    echo "$body" | grep -q 'flock -n 8'
    grep -q 'update-everything) update_locked_exec_run' "${REPO_ROOT}/corex-manage.sh"
}

@test "update session restores CPU ceilings when the command fails" {
    command -v flock >/dev/null 2>&1 || skip "flock unavailable on this test host"
    local root="${BATS_TEST_TMPDIR}/session-syscpu"
    mkdir -p "$root/cpu0/cpufreq"
    printf '3100000\n' > "$root/cpu0/cpufreq/scaling_max_freq"
    # shellcheck disable=SC1090
    source "$UPDATE_LIB"
    COREX_CPU_SYSFS_ROOT="$root"
    COREX_UPDATE_CEILING_STATE="${BATS_TEST_TMPDIR}/session.state"
    COREX_UPDATE_LOCK="${BATS_TEST_TMPDIR}/update.lock"
    COREX_UPDATE_CPU_MAX_MHZ=1600
    update_cpu_temp() { echo 60; }

    run update_session_run "failing update" bash -c 'exit 7'
    [ "$status" -eq 7 ]
    [ "$(cat "$root/cpu0/cpufreq/scaling_max_freq")" = "3100000" ]
    [ ! -e "$COREX_UPDATE_CEILING_STATE" ]
}

@test "dashboard timeout terminates the entire governed process session" {
    local agent="${REPO_ROOT}/agent/corex-agent.py"
    grep -q 'start_new_session=True' "$agent"
    grep -q 'os.killpg(proc.pid, signal.SIGTERM)' "$agent"
    grep -q 'os.killpg(proc.pid, signal.SIGKILL)' "$agent"
}

@test "update marker is durable until explicitly completed" {
    # shellcheck disable=SC1090
    source "$UPDATE_LIB"
    COREX_UPDATE_STATE_DIR="${BATS_TEST_TMPDIR}/markers"
    update_mark_begin nextcloud
    [ -s "$COREX_UPDATE_STATE_DIR/nextcloud" ]
    grep -q '^nextcloud' "$COREX_UPDATE_STATE_DIR/nextcloud"
    update_mark_done nextcloud
    [ ! -e "$COREX_UPDATE_STATE_DIR/nextcloud" ]
}

@test "service pulls are serialized and recreation is marked" {
    local body
    body=$(sed -n '/^_update_single()/,/^}/p' "${REPO_ROOT}/corex-manage.sh")
    echo "$body" | grep -q 'COMPOSE_PARALLEL_LIMIT=1'
    local mark up
    mark=$(echo "$body" | grep -n 'update_mark_begin "\$svc"' | tail -1 | cut -d: -f1)
    up=$(echo "$body" | grep -n 'compose_up_enabled' | head -1 | cut -d: -f1)
    [ -n "$mark" ] && [ -n "$up" ] && [ "$mark" -lt "$up" ]
    echo "$body" | grep -q 'update_mark_done "\$svc"'
}

@test "boot recovery starts an enabled interrupted service and clears its marker" {
    local script="${BATS_TEST_TMPDIR}/recover.sh" bin="${BATS_TEST_TMPDIR}/bin"
    local marks="${BATS_TEST_TMPDIR}/marks" root="${BATS_TEST_TMPDIR}/docker" log="${BATS_TEST_TMPDIR}/docker.log"
    mkdir -p "$bin" "$marks" "$root/n8n"
    _generated UREOF "${REPO_ROOT}/lib/selfheal.sh" > "$script"
    chmod +x "$script"
    touch "$marks/n8n" "$root/n8n/docker-compose.yml"
    printf 'DOCKER_ROOT=%q\n' "$root" > "${BATS_TEST_TMPDIR}/corex.conf"
    printf '{"services":{"n8n":{"installed":true,"enabled":true,"disabled_components":[]}}}\n' \
        > "${BATS_TEST_TMPDIR}/state.json"
    cat > "$bin/sensors" <<'EOF'
#!/bin/bash
echo 'Tctl:         +60.0°C'
EOF
    cat > "$bin/docker" <<EOF
#!/bin/bash
echo "parallel=\${COMPOSE_PARALLEL_LIMIT:-} \$*" >> "$log"
[[ "\$1" == "info" ]] && exit 0
[[ "\$*" == *"config --services"* ]] && { echo app; exit 0; }
exit 0
EOF
    chmod +x "$bin/sensors" "$bin/docker"

    run env PATH="$bin:$PATH" COREX_UPDATE_STATE_DIR="$marks" \
        COREX_STATE_FILE="${BATS_TEST_TMPDIR}/state.json" \
        COREX_CONFIG_FILE="${BATS_TEST_TMPDIR}/corex.conf" \
        COREX_UPDATE_THERMAL_CONF="${BATS_TEST_TMPDIR}/missing-thermal.conf" \
        COREX_BLACKBOX_LOG="${BATS_TEST_TMPDIR}/blackbox.log" bash "$script"
    [ "$status" -eq 0 ]
    [ ! -e "$marks/n8n" ]
    grep -q 'parallel=1 compose .* up -d app' "$log"
}

@test "boot recovery never starts an intentionally disabled service" {
    local script="${BATS_TEST_TMPDIR}/recover-disabled.sh" bin="${BATS_TEST_TMPDIR}/bin-disabled"
    local marks="${BATS_TEST_TMPDIR}/marks-disabled" root="${BATS_TEST_TMPDIR}/docker-disabled" log="${BATS_TEST_TMPDIR}/disabled.log"
    mkdir -p "$bin" "$marks" "$root/n8n"
    _generated UREOF "${REPO_ROOT}/lib/selfheal.sh" > "$script"
    touch "$marks/n8n" "$root/n8n/docker-compose.yml"
    printf '{"services":{"n8n":{"installed":true,"enabled":false}}}\n' \
        > "${BATS_TEST_TMPDIR}/state-disabled.json"
    cat > "$bin/sensors" <<'EOF'
#!/bin/bash
echo 'Tctl:         +60.0°C'
EOF
    cat > "$bin/docker" <<EOF
#!/bin/bash
echo "\$*" >> "$log"
[[ "\$1" == "info" ]] && exit 0
exit 0
EOF
    chmod +x "$bin/sensors" "$bin/docker"

    run env PATH="$bin:$PATH" COREX_UPDATE_STATE_DIR="$marks" \
        COREX_STATE_FILE="${BATS_TEST_TMPDIR}/state-disabled.json" DOCKER_ROOT="$root" \
        COREX_CONFIG_FILE="${BATS_TEST_TMPDIR}/missing.conf" \
        COREX_UPDATE_THERMAL_CONF="${BATS_TEST_TMPDIR}/missing-thermal.conf" \
        COREX_BLACKBOX_LOG="${BATS_TEST_TMPDIR}/blackbox-disabled.log" bash "$script"
    [ "$status" -eq 0 ]
    [ ! -e "$marks/n8n" ]
    ! grep -q ' up -d' "$log"
}

@test "interrupted-update recovery is ordered after Docker and retried" {
    grep -q 'After=docker.service corex-boot-repair.service' "${REPO_ROOT}/lib/selfheal.sh"
    grep -q 'OnBootSec=90s' "${REPO_ROOT}/lib/selfheal.sh"
    grep -q 'OnUnitActiveSec=5min' "${REPO_ROOT}/lib/selfheal.sh"
}

@test "interrupted-update recovery defers while a normal update holds the lock" {
    local script="${BATS_TEST_TMPDIR}/recover-locked.sh"
    _generated UREOF "${REPO_ROOT}/lib/selfheal.sh" > "$script"
    grep -q 'COREX_UPDATE_LOCK:-/run/corex/update.lock' "$script"
    grep -q 'flock -n 9' "$script"
    grep -q 'an update is still active; recovery deferred' "$script"
}

@test "normal updates refresh the generated recovery worker on existing hosts" {
    local body
    body=$(sed -n '/^cmd_update()/,/^}/p' "${REPO_ROOT}/corex-manage.sh")
    echo "$body" | grep -q 'selfheal_install_update_recovery'
}
