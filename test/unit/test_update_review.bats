#!/usr/bin/env bats
# Regressions found reviewing the update-safety and security-audit work.


# `! cmd` cannot fail a bats test unless it is the last line: set -e ignores a
# negated command. refute fails wherever it appears.
refute() {
    if "$@"; then
        echo "expected to fail: $*" >&2
        return 1
    fi
}

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export REPO_ROOT
}

# A function body with comment lines and log calls removed, so an assertion
# reads the code that runs rather than the prose describing it (gotcha #71).
_body() {
    awk -v fn="$1" '$0 ~ "^"fn"\\(\\) \\{" {f=1} f {print} f && /^}/ {exit}' "$2" \
        | grep -vE '^[[:space:]]*#|^[[:space:]]*log_(info|warning|success|step)'
}

_nc_fixture() {
    local root="$1" maint="$2" installed="$3" code="$4"
    mkdir -p "${root}/nextcloud-html/config"
    cat > "${root}/nextcloud-html/config/config.php" <<PHP
<?php
\$CONFIG = array (
  'instanceid' => 'abc',
  'maintenance' => ${maint},
  'version' => '${installed}',
);
PHP
    echo "<?php
\$OC_Version = array(${code});
\$OC_VersionString = '34.0.1';" > "${root}/nextcloud-html/version.php"
}

_nc_state() {
    log_info() { :; }; log_warning() { :; }; log_success() { :; }; log_step() { :; }
    # shellcheck disable=SC1090
    source "${REPO_ROOT}/lib/services/nextcloud.sh"
    _nextcloud_upgrade_state
}

@test "nextcloud state: current install reads ok without occ" {
    DATA_ROOT="$BATS_TEST_TMPDIR"
    _nc_fixture "$DATA_ROOT" false 34.0.1.2 "34, 0, 1, 2"
    run _nc_state
    [ "$output" = "ok" ]
}

@test "nextcloud state: pending schema upgrade is detected from files" {
    DATA_ROOT="$BATS_TEST_TMPDIR"
    _nc_fixture "$DATA_ROOT" false 34.0.0.9 "34,0,1,2"
    run _nc_state
    [ "$output" = "upgrade" ]
}

@test "nextcloud state: maintenance mode is detected from config.php" {
    DATA_ROOT="$BATS_TEST_TMPDIR"
    _nc_fixture "$DATA_ROOT" true 34.0.1.2 "34,0,1,2"
    run _nc_state
    [ "$output" = "maintenance" ]
}

@test "nextcloud state: unreadable files fall back to unknown" {
    DATA_ROOT="${BATS_TEST_TMPDIR}/absent"
    run _nc_state
    [ "$output" = "unknown" ]
}

@test "nextcloud upgrade lowers priority inside the container, not on the client" {
    local f="${REPO_ROOT}/lib/services/nextcloud.sh"
    refute grep -q 'taskset -c' "$f"
    grep -q "exec nice -n 19 php occ upgrade" "$f"
}

@test "updating a disabled service never runs a repair or touches containers" {
    local body
    body=$(_body _update_single_disabled "${REPO_ROOT}/corex-manage.sh")
    [ -n "$body" ]
    refute grep -q '_run_service_fn' <<< "$body"
    refute grep -qE 'compose[^|]* (up|stop|start|restart)' <<< "$body"
}

@test "coolify_update never runs the Coolify installer" {
    local body
    body=$(_body coolify_update "${REPO_ROOT}/lib/services/coolify.sh")
    [ -n "$body" ]
    refute grep -qE 'curl|upgrade\.sh|^ *bash ' <<< "$body"
}

@test "ups_update does not run apt inside the update window" {
    local body
    body=$(_body ups_update "${REPO_ROOT}/lib/services/ups.sh")
    [ -n "$body" ]
    refute grep -q 'apt-get' <<< "$body"
}

@test "security apply neither upgrades the OS nor resets the firewall" {
    local body
    body=$(_body security_apply "${REPO_ROOT}/lib/security.sh")
    [ -n "$body" ]
    refute grep -q 'phase2_security' <<< "$body"
    refute grep -q 'ufw --force reset' <<< "$body"
    refute grep -q 'apt-get' <<< "$body"
    refute grep -qE 'sshd_config|systemctl (restart|reload) ssh' <<< "$body"
}

@test "an inactive firewall is not reported as active" {
    local sec="${REPO_ROOT}/lib/security.sh"
    refute grep -q '== \*"active"\*' "$sec"
    grep -q '"Status: active"' "$sec"
}

@test "watchdog audit checks the device, not just the config file" {
    local body
    body=$(_body security_check "${REPO_ROOT}/lib/security.sh")
    grep -q '/dev/watchdog0' <<< "$body"
}

@test "rewriting jail.local keeps the operator's ignoreip allowlist" {
    local body
    body=$(_body _security_fail2ban "${REPO_ROOT}/lib/security.sh")
    grep -q 'grep -m1 -E .*ignoreip' <<< "$body"
    grep -qx '\${ignoreip}' <<< "$body"
}

@test "the watchdog driver is loaded past Ubuntu's deny-list, not via modules-load.d" {
    # systemd-modules-load honours the kmod deny-list, so a modules-load.d
    # entry for sp5100_tco loads nothing; only an explicit modprobe does.
    local rec="${REPO_ROOT}/lib/recovery.sh"
    refute grep -qE '>[[:space:]]*/etc/modules-load\.d/' "$rec"
    grep -q 'ExecStart=/usr/local/bin/corex-watchdog-load.sh load' "$rec"
    grep -q 'Before=sysinit.target' "$rec"
    grep -q 'corex-watchdog-load.sh arm' "$rec"
    local gen="${BATS_TEST_TMPDIR}/wl.sh"
    awk 'index($0, "<< WLEOF") {f=1; next} $0 == "WLEOF" {f=0} f' "$rec" \
        | sed 's/\\\$/$/g' > "$gen"
    [ -s "$gen" ]
    bash -n "$gen"
    grep -q 'modprobe "$MOD"' "$gen"
}
