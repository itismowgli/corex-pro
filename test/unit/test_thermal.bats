#!/usr/bin/env bats
# Unit tests for the thermal guardian.
#
# SERVICE_CATEGORY became load-bearing when lib/thermal.sh started deriving
# shed order from it (CLAUDE.md gotcha #17). A typo in a service module's
# category now means that service is shed at the wrong time — or never — so
# these tests guard the contract rather than the shell plumbing.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export REPO_ROOT
    THERMAL_LIB="${REPO_ROOT}/lib/thermal.sh"
    export THERMAL_LIB

    # The full set of categories the wizard and the guardian understand.
    VALID_CATEGORIES="core storage security productivity ai monitoring communication backup"
    export VALID_CATEGORIES
}

# ─── Module contract ──────────────────────────────────────────────────────────

@test "lib/thermal.sh exists and parses" {
    [ -f "$THERMAL_LIB" ]
    run bash -n "$THERMAL_LIB"
    [ "$status" -eq 0 ]
}

@test "lib/selfheal.sh exists and parses" {
    [ -f "${REPO_ROOT}/lib/selfheal.sh" ]
    run bash -n "${REPO_ROOT}/lib/selfheal.sh"
    [ "$status" -eq 0 ]
}

@test "thermal_install is defined" {
    # shellcheck disable=SC1090
    source "$THERMAL_LIB"
    run declare -f thermal_install
    [ "$status" -eq 0 ]
}

# ─── SERVICE_CATEGORY validity (the load-bearing contract) ────────────────────

@test "every service module declares a SERVICE_CATEGORY" {
    local missing=""
    for f in "${REPO_ROOT}"/lib/services/*.sh; do
        grep -q '^SERVICE_CATEGORY=' "$f" || missing+=" $(basename "$f")"
    done
    [ -z "$missing" ] || {
        echo "modules missing SERVICE_CATEGORY:$missing"
        false
    }
}

@test "every SERVICE_CATEGORY is one of the known categories" {
    local bad=""
    for f in "${REPO_ROOT}"/lib/services/*.sh; do
        local cat
        cat=$(grep -m1 '^SERVICE_CATEGORY=' "$f" | cut -d'"' -f2)
        [ -z "$cat" ] && continue
        if [[ " $VALID_CATEGORIES " != *" $cat "* ]]; then
            bad+=" $(basename "$f")=$cat"
        fi
    done
    [ -z "$bad" ] || {
        echo "invalid categories:$bad"
        echo "valid: $VALID_CATEGORIES"
        false
    }
}

# ─── Shed tiers must partition cleanly ────────────────────────────────────────

@test "shed tiers and protected categories do not overlap" {
    # Mirrors the defaults written into /etc/corex/thermal.conf.
    local tier1="ai"
    local tier2="monitoring productivity storage backup"
    local protect="core security communication"

    for c in $tier1 $tier2; do
        [[ " $protect " != *" $c "* ]] || {
            echo "category '$c' is both shed and protected"
            false
        }
    done
}

@test "shed tiers plus protected cover every valid category" {
    local covered="ai monitoring productivity storage backup core security communication"
    for c in $VALID_CATEGORIES; do
        [[ " $covered " == *" $c "* ]] || {
            echo "category '$c' is in neither a shed tier nor the protect list"
            false
        }
    done
}

@test "core and security are never in a shed tier" {
    # A box that sheds Traefik or Vaultwarden becomes unreachable, which
    # defeats the purpose of shedding at all.
    local tier1="ai"
    local tier2="monitoring productivity storage backup"
    for c in $tier1 $tier2; do
        [ "$c" != "core" ]
        [ "$c" != "security" ]
    done
}

# ─── Threshold sanity ────────────────────────────────────────────────────────

@test "thermal thresholds are strictly increasing" {
    # shellcheck disable=SC1090
    source "$THERMAL_LIB"
    [ "$THERMAL_RECOVER_C" -lt "$THERMAL_WARN_C" ]
    [ "$THERMAL_WARN_C"    -lt "$THERMAL_SHED_C" ]
    [ "$THERMAL_SHED_C"    -lt "$THERMAL_CRITICAL_C" ]
    [ "$THERMAL_CRITICAL_C" -lt "$THERMAL_EMERGENCY_C" ]
}

@test "emergency threshold leaves headroom below typical TjMax (100C)" {
    # shellcheck disable=SC1090
    source "$THERMAL_LIB"
    [ "$THERMAL_EMERGENCY_C" -lt 100 ]
}

@test "recover threshold is well below shed to prevent flapping" {
    # shellcheck disable=SC1090
    source "$THERMAL_LIB"
    local gap=$(( THERMAL_SHED_C - THERMAL_RECOVER_C ))
    [ "$gap" -ge 8 ]
}

@test "confirm samples is at least 2 so a single spike cannot shed load" {
    # shellcheck disable=SC1090
    source "$THERMAL_LIB"
    [ "$THERMAL_CONFIRM_SAMPLES" -ge 2 ]
}

# ─── Generated guard script ──────────────────────────────────────────────────

@test "generated thermal guard script is valid bash" {
    # Extract the heredoc body written by _thermal_write_guard and parse it.
    local out="${BATS_TEST_TMPDIR:-/tmp}/guard.sh"
    awk "/cat > \/usr\/local\/bin\/corex-thermal-guard.sh << 'TGEOF'/{f=1;next} /^TGEOF$/{f=0} f" \
        "$THERMAL_LIB" > "$out"
    [ -s "$out" ]
    run bash -n "$out"
    [ "$status" -eq 0 ]
}

@test "generated guard never hardcodes an install path" {
    local out="${BATS_TEST_TMPDIR:-/tmp}/guard2.sh"
    awk "/cat > \/usr\/local\/bin\/corex-thermal-guard.sh << 'TGEOF'/{f=1;next} /^TGEOF$/{f=0} f" \
        "$THERMAL_LIB" > "$out"
    run grep -c "/opt/corex-pro" "$out"
    [ "$output" = "0" ]
}

@test "generated boot-repair script is valid bash" {
    local out="${BATS_TEST_TMPDIR:-/tmp}/repair.sh"
    awk "/cat > \/usr\/local\/bin\/corex-boot-repair.sh << 'BREOF'/{f=1;next} /^BREOF$/{f=0} f" \
        "${REPO_ROOT}/lib/selfheal.sh" > "$out"
    [ -s "$out" ]
    run bash -n "$out"
    [ "$status" -eq 0 ]
}

# ─── Never-shed protection ───────────────────────────────────────────────────

@test "ups is protected from thermal shedding despite monitoring category" {
    # UPS monitoring is what protects against a power failure. Shedding it
    # during a thermal event removes exactly the wrong thing.
    grep -q 'THERMAL_NEVER_SHED="ups"' "$THERMAL_LIB"
    # And the guard must actually honour the list.
    local out="${BATS_TEST_TMPDIR:-/tmp}/guard3.sh"
    awk "/cat > \/usr\/local\/bin\/corex-thermal-guard.sh << 'TGEOF'/{f=1;next} /^TGEOF$/{f=0} f" \
        "$THERMAL_LIB" > "$out"
    grep -q 'THERMAL_NEVER_SHED' "$out"
}

# ─── Unattended-upgrades kernel exclusion (gotcha #18) ───────────────────────

@test "kernel and libc are blacklisted from unattended upgrades" {
    local sec="${REPO_ROOT}/lib/security.sh"
    grep -q 'Unattended-Upgrade::Package-Blacklist' "$sec"
    for pkg in 'linux-image-' 'linux-headers-' 'libc6' 'systemd'; do
        grep -q "\"$pkg\"" "$sec" || {
            echo "missing blacklist entry: $pkg"
            false
        }
    done
}

@test "unattended upgrades does not auto-remove kernels" {
    grep -q 'Remove-Unused-Kernel-Packages "false"' "${REPO_ROOT}/lib/security.sh"
}

# ─── Recovery must be reachable and gradual ──────────────────────────────────

@test "recovery happens below WARN, not only at RECOVER_C" {
    # THERMAL_RECOVER_C is absolute. On a machine whose idle temperature sits
    # above it the shed list is never drained: a box idling at 79C to 84C with
    # a 72C recover threshold left 24 containers stopped indefinitely, with no
    # error, because the guardian waited for a temperature the hardware never
    # reaches.
    local out="${BATS_TEST_TMPDIR:-/tmp}/guard-recover.sh"
    awk "/cat > \/usr\/local\/bin\/corex-thermal-guard.sh << 'TGEOF'/{f=1;next} /^TGEOF$/{f=0} f" \
        "$THERMAL_LIB" > "$out"
    [ -s "$out" ]
    grep -qE '^\s*normal\|recover\)' "$out"
}

@test "recovery restores a bounded batch per cycle" {
    # Restoring the whole shed list at once took a measured box from 79C to
    # 96C in under two minutes, one degree below the emergency threshold,
    # which sheds everything again.
    # shellcheck disable=SC1090
    source "$THERMAL_LIB"
    [ -n "$THERMAL_RESTORE_BATCH" ]
    [ "$THERMAL_RESTORE_BATCH" -ge 1 ]
    [ "$THERMAL_RESTORE_BATCH" -le 10 ]

    local out="${BATS_TEST_TMPDIR:-/tmp}/guard-batch.sh"
    awk "/cat > \/usr\/local\/bin\/corex-thermal-guard.sh << 'TGEOF'/{f=1;next} /^TGEOF$/{f=0} f" \
        "$THERMAL_LIB" > "$out"
    grep -q 'THERMAL_RESTORE_BATCH' "$out"
    # The batch must actually cap the loop, not just be read.
    grep -qE 'restored >= batch' "$out"
}

@test "restore batch is written into the config file" {
    # Otherwise an operator cannot tune it on a box with more cooling.
    grep -q 'THERMAL_RESTORE_BATCH=\${THERMAL_RESTORE_BATCH}' "$THERMAL_LIB"
}

# ─── A config from an older CoreX must not break the guardian ────────────────

@test "generated guard defaults every setting after sourcing the config" {
    # The guard runs under set -u. A config written by an older CoreX lacks
    # keys added since, so referencing one directly aborts the guardian, and
    # a guardian that aborts sheds nothing at all.
    local out="${BATS_TEST_TMPDIR:-/tmp}/guard-defaults.sh"
    awk "/cat > \/usr\/local\/bin\/corex-thermal-guard.sh << 'TGEOF'/{f=1;next} /^TGEOF$/{f=0} f" \
        "$THERMAL_LIB" > "$out"
    [ -s "$out" ]
    for v in THERMAL_WARN_C THERMAL_SHED_C THERMAL_CRITICAL_C THERMAL_EMERGENCY_C \
             THERMAL_RECOVER_C THERMAL_CONFIRM_SAMPLES THERMAL_RESTORE_BATCH \
             THERMAL_SHED_TIER1 THERMAL_SHED_TIER2 THERMAL_PROTECT THERMAL_NEVER_SHED; do
        grep -qE "^${v}=\"\\\$\{${v}:-" "$out" || {
            echo "guard has no default for $v"
            false
        }
    done
}

@test "guard survives a config that predates the newest settings" {
    local out="${BATS_TEST_TMPDIR:-/tmp}/guard-run.sh"
    awk "/cat > \/usr\/local\/bin\/corex-thermal-guard.sh << 'TGEOF'/{f=1;next} /^TGEOF$/{f=0} f" \
        "$THERMAL_LIB" > "$out"
    # An old config: thresholds only, none of the newer keys.
    local conf="${BATS_TEST_TMPDIR}/thermal.conf"
    printf 'THERMAL_ENABLED=true\nTHERMAL_WARN_C=80\nTHERMAL_SHED_C=85\n' > "$conf"
    # Point the script at the fixture and stub out everything that touches the
    # host, so this exercises variable handling only.
    sed -i.bak "s|^CONF=.*|CONF=${conf}|" "$out"
    run bash -uo pipefail -c "
        read_temp() { echo 75; }
        docker() { return 0; }
        logger() { return 0; }
        sensors() { return 1; }
        source '$out'
    "
    # It must not abort on an unbound variable.
    [[ "$output" != *"unbound variable"* ]]
}

@test "thermal_install adds settings missing from an existing config" {
    # Leaving a generated config stale is how it drifts out of step with the
    # code that reads it (gotcha #22), while regenerating it would discard the
    # operator's tuning.
    grep -q 'Added missing ${k} to thermal.conf' "$THERMAL_LIB"
    grep -qE 'for k in THERMAL_WARN_C' "$THERMAL_LIB"
}

@test "the guardian does not restart a deliberately disabled service" {
    # It restarts whatever is on its shed list and knew nothing about the
    # disabled flag, so it resurrected services that had been switched off.
    # Prometheus came back and burned 49% CPU, a large share of the heat that
    # caused the shed in the first place: the guardian was fighting the
    # operator and losing to itself.
    local out="${BATS_TEST_TMPDIR:-/tmp}/guard-disabled.sh"
    awk "/cat > \/usr\/local\/bin\/corex-thermal-guard.sh << 'TGEOF'/{f=1;next} /^TGEOF$/{f=0} f" \
        "$THERMAL_LIB" > "$out"
    [ -s "$out" ]
    grep -q '_disabled_containers' "$out"
    # It must read both the module flag and the component list.
    grep -q 'enabled == false' "$out"
    grep -q 'disabled_components' "$out"
    # And restore() must consult it.
    awk '/^restore\(\)/,/^}/' "$out" | grep -q 'disabled'
}

@test "a skipped container is dropped from the shed list, not deferred" {
    # Deferring it means the guardian retries a container it must never start
    # for as long as the list lives.
    local out="${BATS_TEST_TMPDIR:-/tmp}/guard-drop.sh"
    awk "/cat > \/usr\/local\/bin\/corex-thermal-guard.sh << 'TGEOF'/{f=1;next} /^TGEOF$/{f=0} f" \
        "$THERMAL_LIB" > "$out"
    local body
    body=$(awk '/^restore\(\)/,/^}/' "$out")
    # The disabled branch continues without appending to remaining.
    echo "$body" | grep -A 2 'disabled by the operator' | grep -q 'continue'
    echo "$body" | grep -A 2 'disabled by the operator' | grep -qv 'remaining+='
}
