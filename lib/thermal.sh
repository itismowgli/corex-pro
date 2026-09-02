#!/bin/bash
# lib/thermal.sh — CoreX Pro
# Thermal guardian: progressive load shedding instead of thermal shutdown.
#
# WHY THIS EXISTS:
#   Mini servers run mobile-class CPUs (Ryzen HX, Intel NUC) in small chassis
#   with marginal cooling. Under sustained container load they reach TjMax and
#   the CPU fires THERMTRIP — an instant hardware power cut. The kernel gets no
#   chance to log anything and no chance to flush, so you get a silent crash
#   plus a possibly-corrupt dpkg database and possibly-corrupt databases.
#
#   Load shedding is strictly better than thermal shutdown. Pausing Ollama for
#   ten minutes is a nuisance; a THERMTRIP mid-dpkg can leave the box unbootable.
#
# HOW IT DECIDES WHAT TO SHED:
#   It reuses SERVICE_CATEGORY, which every service module already declares, so
#   no service module needs changing. Shed order runs least-essential first, and
#   containers CoreX did not deploy (e.g. Coolify apps, which carry no resource
#   limits) are shed before any CoreX service, because they are the usual cause.
#
# See CLAUDE.md gotcha #17.

# ── Thresholds (degrees C). Overridable in /etc/corex/thermal.conf ───────────
THERMAL_WARN_C="${THERMAL_WARN_C:-80}"
THERMAL_SHED_C="${THERMAL_SHED_C:-85}"
THERMAL_CRITICAL_C="${THERMAL_CRITICAL_C:-90}"
THERMAL_EMERGENCY_C="${THERMAL_EMERGENCY_C:-97}"
# Restore only once comfortably back down, to avoid flapping.
THERMAL_RECOVER_C="${THERMAL_RECOVER_C:-72}"
# Containers restarted per guardian cycle when recovering. Restoring the whole
# shed list at once is what made a shed event self-sustaining: bringing 24
# containers back together took a measured box from 79C to 96C in under two
# minutes, one degree under the emergency threshold, which sheds them again.
THERMAL_RESTORE_BATCH="${THERMAL_RESTORE_BATCH:-3}"
# Consecutive samples required before acting (hysteresis).
THERMAL_CONFIRM_SAMPLES="${THERMAL_CONFIRM_SAMPLES:-3}"

thermal_install() {
    log_info "Installing thermal guardian..."

    mkdir -p /etc/corex /var/lib/corex

    # lib/thermal.sh lives at <repo>/lib/thermal.sh, so the repo root is two
    # levels up from this file. SCRIPT_DIR is set by the installer when
    # available; fall back to deriving it from BASH_SOURCE.
    local COREX_REPO_ROOT_DETECTED
    COREX_REPO_ROOT_DETECTED="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

    # ── Tunables live in a config file so an operator can adjust or disable
    #    without editing the generated script. ────────────────────────────────
    if [[ ! -f /etc/corex/thermal.conf ]]; then
        cat > /etc/corex/thermal.conf << TCEOF
# CoreX thermal guardian configuration.
# Set THERMAL_ENABLED=false to disable load shedding entirely.
THERMAL_ENABLED=true

# Temperature thresholds, degrees C.
THERMAL_WARN_C=${THERMAL_WARN_C}
THERMAL_SHED_C=${THERMAL_SHED_C}
THERMAL_CRITICAL_C=${THERMAL_CRITICAL_C}
THERMAL_EMERGENCY_C=${THERMAL_EMERGENCY_C}
THERMAL_RECOVER_C=${THERMAL_RECOVER_C}

# Consecutive samples above a threshold before acting (avoids reacting to
# momentary spikes from a compile or a backup run).
THERMAL_CONFIRM_SAMPLES=${THERMAL_CONFIRM_SAMPLES}

# Containers restarted per cycle while recovering. Raise it only if the
# machine has cooling headroom; restoring everything at once can push a
# marginal box straight back over the shed threshold.
THERMAL_RESTORE_BATCH=${THERMAL_RESTORE_BATCH}

# Categories shed at SHED level, in order. Space-separated.
THERMAL_SHED_TIER1="ai"
# Categories shed at CRITICAL level, in order.
THERMAL_SHED_TIER2="monitoring productivity storage backup"
# Categories never shed automatically — the box stays useful and reachable.
THERMAL_PROTECT="core security communication"
# Individual services never shed, regardless of category. 'ups' is monitoring
# by category, but shedding UPS monitoring during a thermal event would remove
# the very thing that protects against a concurrent power failure.
THERMAL_NEVER_SHED="ups"

# Where CoreX compose projects live; used to tell managed from unmanaged.
COREX_DOCKER_ROOT=${DOCKER_ROOT:-/mnt/corex-data/docker-configs}
# Where the CoreX repo is checked out (service modules are read from here to
# resolve SERVICE_CATEGORY). Detected at install time.
COREX_REPO_ROOT=${COREX_REPO_ROOT_DETECTED}
TCEOF
        log_success "Wrote /etc/corex/thermal.conf"
    else
        # Keep the operator's tuning, but add keys this version needs. A
        # config from an older CoreX is missing anything added since, and
        # leaving it stale is how a generated file drifts out of step with the
        # code that reads it (gotcha #22). Appending is safe: sourcing the
        # file later takes the last assignment, and nothing existing is
        # touched.
        local k
        for k in THERMAL_WARN_C THERMAL_SHED_C THERMAL_CRITICAL_C \
                 THERMAL_EMERGENCY_C THERMAL_RECOVER_C \
                 THERMAL_CONFIRM_SAMPLES THERMAL_RESTORE_BATCH; do
            grep -qE "^\s*${k}=" /etc/corex/thermal.conf && continue
            printf '%s=%s\n' "$k" "${!k}" >> /etc/corex/thermal.conf
            log_info "Added missing ${k} to thermal.conf"
        done
        log_info "Keeping existing /etc/corex/thermal.conf"
    fi

    _thermal_write_guard
    _thermal_write_units
    log_success "Thermal guardian active (sheds load instead of thermal-tripping)"
}

# The guard script is intentionally self-contained: it must run from systemd
# with no CoreX libraries sourced, and must never fail in a way that leaves
# containers stopped with no record of why.
_thermal_write_guard() {
    cat > /usr/local/bin/corex-thermal-guard.sh << 'TGEOF'
#!/bin/bash
# CoreX thermal guardian. Sheds container load as temperature rises and
# restores it as temperature falls. Runs from corex-thermal.timer.
set -uo pipefail

CONF=/etc/corex/thermal.conf
STATE=/var/lib/corex/thermal.state
SHED_LIST=/var/lib/corex/thermal-shed.list
LOG=/mnt/corex-data/blackbox.log

[[ -r "$CONF" ]] || exit 0
# shellcheck disable=SC1090
source "$CONF"
[[ "${THERMAL_ENABLED:-true}" == "true" ]] || exit 0

# Defaults for every setting, applied after the config is sourced. A config
# written by an older CoreX will not contain keys added since, and this script
# runs under `set -u`, so referencing one directly would abort the guardian on
# a box that had been upgraded. Silence there means no shedding at all.
THERMAL_WARN_C="${THERMAL_WARN_C:-80}"
THERMAL_SHED_C="${THERMAL_SHED_C:-85}"
THERMAL_CRITICAL_C="${THERMAL_CRITICAL_C:-90}"
THERMAL_EMERGENCY_C="${THERMAL_EMERGENCY_C:-97}"
THERMAL_RECOVER_C="${THERMAL_RECOVER_C:-72}"
THERMAL_CONFIRM_SAMPLES="${THERMAL_CONFIRM_SAMPLES:-3}"
THERMAL_RESTORE_BATCH="${THERMAL_RESTORE_BATCH:-3}"
THERMAL_SHED_TIER1="${THERMAL_SHED_TIER1:-ai}"
THERMAL_SHED_TIER2="${THERMAL_SHED_TIER2:-monitoring productivity storage backup}"
THERMAL_PROTECT="${THERMAL_PROTECT:-core security communication}"
THERMAL_NEVER_SHED="${THERMAL_NEVER_SHED:-ups}"

mkdir -p "$(dirname "$STATE")" "$(dirname "$LOG")" 2>/dev/null
touch "$SHED_LIST" 2>/dev/null

say() {
    printf '%s thermal: %s\n' "$(date -Is)" "$1" >> "$LOG" 2>/dev/null
    logger -t corex-thermal "$1" 2>/dev/null || true
}

# ── Read the hottest relevant sensor ────────────────────────────────────────
# Prefer the CPU package sensor; fall back through coretemp and thermal zones.
read_temp() {
    local t=""
    if command -v sensors &>/dev/null; then
        # AMD Tctl / Tdie, then Intel Package id.
        t=$(sensors -u 2>/dev/null \
            | awk '/^(Tctl|Tdie|Package id 0):/{getline; print $2; exit}')
        [[ -z "$t" ]] && t=$(sensors -u 2>/dev/null \
            | awk '/_input:/{print $2}' | sort -rn | head -1)
    fi
    if [[ -z "$t" ]]; then
        local best=0 v
        for z in /sys/class/thermal/thermal_zone*/temp; do
            [[ -r "$z" ]] || continue
            v=$(( $(cat "$z" 2>/dev/null || echo 0) / 1000 ))
            (( v > best )) && best=$v
        done
        (( best > 0 )) && t=$best
    fi
    # Integer degrees only; awk may hand back "95.625".
    printf '%.0f' "${t:-0}" 2>/dev/null || echo 0
}

# ── Classify running containers ─────────────────────────────────────────────
# A container is "managed" if its compose project matches a directory under
# COREX_DOCKER_ROOT. Anything else was deployed outside CoreX (Coolify, manual
# docker run) and typically carries no resource limits, so it sheds first.
list_unmanaged() {
    local name proj
    docker ps --format '{{.Names}}' 2>/dev/null | while read -r name; do
        [[ -z "$name" ]] && continue
        proj=$(docker inspect -f \
            '{{index .Config.Labels "com.docker.compose.project"}}' \
            "$name" 2>/dev/null)
        if [[ -z "$proj" || ! -d "${COREX_DOCKER_ROOT}/${proj}" ]]; then
            echo "$name"
        fi
    done
}

# Containers belonging to CoreX services in the given categories.
list_by_category() {
    local want="$1" svc svc_cat dir w
    for dir in "${COREX_DOCKER_ROOT}"/*/; do
        [[ -d "$dir" ]] || continue
        svc=$(basename "$dir")
        # Explicit opt-out wins over category membership.
        [[ " ${THERMAL_NEVER_SHED:-} " == *" ${svc} "* ]] && continue
        # Read SERVICE_CATEGORY without sourcing the module (avoids side effects).
        svc_cat=$(grep -m1 '^SERVICE_CATEGORY=' \
            "${COREX_REPO_ROOT}/lib/services/${svc}.sh" 2>/dev/null \
            | cut -d'"' -f2)
        [[ -z "$svc_cat" ]] && continue
        for w in $want; do
            if [[ "$svc_cat" == "$w" ]]; then
                docker compose -f "${dir}docker-compose.yml" ps \
                    --format '{{.Name}}' 2>/dev/null
            fi
        done
    done
}

shed() {
    local reason="$1"; shift
    local c stopped=0
    for c in "$@"; do
        [[ -z "$c" ]] && continue
        grep -qxF "$c" "$SHED_LIST" 2>/dev/null && continue
        if timeout 45 docker stop --time 25 "$c" >/dev/null 2>&1; then
            echo "$c" >> "$SHED_LIST"
            stopped=$((stopped+1))
        fi
    done
    (( stopped > 0 )) && say "SHED ($reason): stopped $stopped container(s)"
}

# Restart at most $1 shed containers, oldest entry first. Anything not started
# this cycle stays on the list, so the next sample sees the new temperature
# before more load returns. Restoring the full list in one pass is what turned
# a single shed event into a loop.
# Containers belonging to a service, or component, the operator disabled.
#
# The guardian restarts whatever is on its shed list, and knew nothing about
# the disabled flag, so it resurrected services that had been deliberately
# switched off. Observed: Prometheus and cAdvisor were brought back and
# Prometheus alone then burned 49% CPU, which is a large share of the heat that
# caused the shed in the first place. The guardian was fighting the operator
# and losing to itself.
_disabled_containers() {
    [[ -r /etc/corex/state.json ]] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    jq -r '[ .services | to_entries[]
             | (if (.value.enabled == false) then .key else empty end),
               ((.value.disabled_components // [])[]) ] | unique[]' \
        /etc/corex/state.json 2>/dev/null || true
}

restore() {
    [[ -s "$SHED_LIST" ]] || return 0
    local batch="${1:-$THERMAL_RESTORE_BATCH}"
    local c restored=0 remaining=""
    local disabled
    disabled=$(_disabled_containers)
    while read -r c; do
        [[ -z "$c" ]] && continue
        # Drop it from the list rather than deferring it, or the guardian
        # retries a container it must never start for as long as the list
        # lives.
        if [[ -n "$disabled" ]] && printf '%s\n' "$disabled" | grep -qxF "$c"; then
            say "SKIP ${c}: disabled by the operator, not restarting"
            continue
        fi
        if (( restored >= batch )); then
            remaining+="${c}"$'\n'
            continue
        fi
        if timeout 60 docker start "$c" >/dev/null 2>&1; then
            restored=$((restored+1))
        else
            remaining+="${c}"$'\n'
        fi
    done < "$SHED_LIST"
    printf '%s' "$remaining" > "$SHED_LIST"
    local left
    left=$(grep -c . "$SHED_LIST" 2>/dev/null) || left=0
    (( restored > 0 )) && \
        say "RECOVERED at ${temp}C: restarted $restored container(s), $left still shed"
}

# ── Hysteresis: count consecutive samples in the same band ──────────────────
temp=$(read_temp)
(( temp <= 0 )) && exit 0   # No usable sensor; do nothing rather than guess.

prev_band=""; prev_count=0
[[ -r "$STATE" ]] && read -r prev_band prev_count < "$STATE" 2>/dev/null
prev_count=${prev_count:-0}

if   (( temp >= THERMAL_EMERGENCY_C )); then band="emergency"
elif (( temp >= THERMAL_CRITICAL_C ));  then band="critical"
elif (( temp >= THERMAL_SHED_C ));      then band="shed"
elif (( temp >= THERMAL_WARN_C ));      then band="warn"
elif (( temp <= THERMAL_RECOVER_C ));   then band="recover"
else band="normal"; fi

if [[ "$band" == "$prev_band" ]]; then
    count=$((prev_count + 1))
else
    count=1
fi
echo "$band $count" > "$STATE"

# Emergency acts immediately — there is no time to confirm at TjMax.
if [[ "$band" == "emergency" ]]; then
    say "EMERGENCY ${temp}C >= ${THERMAL_EMERGENCY_C}C — graceful shutdown to avoid THERMTRIP"
    timeout 90 docker stop --time 20 $(docker ps -q 2>/dev/null) >/dev/null 2>&1 || true
    sync
    /sbin/shutdown -h now "CoreX thermal emergency: ${temp}C"
    exit 0
fi

(( count < THERMAL_CONFIRM_SAMPLES )) && exit 0

case "$band" in
    critical)
        say "CRITICAL ${temp}C — shedding tier1+tier2"
        mapfile -t u < <(list_unmanaged)
        shed "unmanaged @ ${temp}C" "${u[@]:-}"
        mapfile -t t1 < <(list_by_category "${THERMAL_SHED_TIER1}")
        shed "tier1 @ ${temp}C" "${t1[@]:-}"
        mapfile -t t2 < <(list_by_category "${THERMAL_SHED_TIER2}")
        shed "tier2 @ ${temp}C" "${t2[@]:-}"
        ;;
    shed)
        say "HIGH ${temp}C — shedding unmanaged + tier1"
        mapfile -t u < <(list_unmanaged)
        shed "unmanaged @ ${temp}C" "${u[@]:-}"
        mapfile -t t1 < <(list_by_category "${THERMAL_SHED_TIER1}")
        shed "tier1 @ ${temp}C" "${t1[@]:-}"
        ;;
    warn)
        say "WARN ${temp}C (no action; shed threshold ${THERMAL_SHED_C}C)"
        ;;
    normal|recover)
        # Recovery cannot depend on reaching THERMAL_RECOVER_C. That is an
        # absolute value, and on a machine whose idle temperature sits above
        # it the shed list is never drained: a box measured idling at 79C to
        # 84C with a recover threshold of 72C left 24 containers stopped
        # indefinitely, with no error anywhere, because the guardian was
        # waiting for a temperature the hardware never reaches.
        #
        # Anything below THERMAL_WARN_C is cool enough to take load back. The
        # gap to THERMAL_SHED_C plus THERMAL_CONFIRM_SAMPLES supplies the
        # hysteresis, and the batch limit keeps each step small. Below
        # THERMAL_RECOVER_C there is real headroom, so recover faster.
        if [[ "$band" == "recover" ]]; then
            restore $(( THERMAL_RESTORE_BATCH * 2 ))
        else
            restore "$THERMAL_RESTORE_BATCH"
        fi
        ;;
esac
TGEOF
    chmod 750 /usr/local/bin/corex-thermal-guard.sh
}

_thermal_write_units() {
    cat > /etc/systemd/system/corex-thermal.service << TSEOF
[Unit]
Description=CoreX thermal guardian (progressive load shedding)
After=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/corex-thermal-guard.sh
TSEOF

    cat > /etc/systemd/system/corex-thermal.timer << TTEOF
[Unit]
Description=Run the CoreX thermal guardian every 30s

[Timer]
OnBootSec=45s
OnUnitActiveSec=30s
AccuracySec=5s

[Install]
WantedBy=timers.target
TTEOF

    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now corex-thermal.timer 2>/dev/null || true
}
