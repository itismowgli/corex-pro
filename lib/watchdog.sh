#!/bin/bash
# lib/watchdog.sh — CoreX Pro
# Resource watchdog: turns host conditions into Uptime Kuma push heartbeats.
#
# WHY THIS EXISTS:
#   The HTTP monitors answer one question: does the URL respond. That misses
#   every failure that degrades the box without taking a URL offline, which on
#   this hardware is most of them. A container OOM-killed and restarting, a
#   disk filling, the thermal guardian shedding services, a background container
#   pinning five cores: all of these are invisible to a 200 OK.
#
#   It also misses containers that have no URL at all. nextcloud-cron,
#   immich-redis and nextcloud-db have no HTTP endpoint, so an HTTP-only setup
#   reports a healthy Nextcloud while its cron has been dead for a week.
#
# WHY NOT PROMETHEUS AND GRAFANA:
#   That stack is the textbook answer and the wrong one here. Prometheus was
#   measured holding 13GB of TSDB and burning 49% of a core on a box that
#   thermal-trips, so the observability was itself a load source, and its
#   alerting still needs a separate route to reach a phone. This script reads
#   /proc and one `docker inspect`, costs no measurable CPU, and reuses the
#   Telegram notifier Kuma already has configured.
#
# DIVISION OF LABOUR:
#   This script only measures and decides up/down. Kuma owns retry, dedupe,
#   re-notify intervals, history and delivery. Nothing here sends a message.
#
# ATTRIBUTION:
#   Every alert names the containers responsible, because "the box is hot" is
#   not actionable and "immich-ml at 190%" is. `docker stats` is the expensive
#   call (roughly a second with 19 containers), so it runs only when a threshold
#   has actually tripped, never on the healthy path.

# ── Thresholds. Overridable in /etc/corex/watchdog.conf ──────────────────────
# CPU temperature that counts as a problem. Matches THERMAL_WARN_C by default:
# the guardian starts paying attention here, so you should too.

# shellcheck source=lib/common.sh
# Sourced explicitly rather than left to the caller. These files depend on
# log_info and install_script, and a missing install_script is silent in the
# worst way: the generated script is simply never written, so the guardian or
# the recorder does not exist and nothing says so.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
WATCHDOG_TEMP_C="${WATCHDOG_TEMP_C:-80}"
# 5-minute load average per core. 1.5 tolerates a backup or a photo import
# without alerting; sustained above it means something is genuinely stuck.
WATCHDOG_LOAD_RATIO="${WATCHDOG_LOAD_RATIO:-1.5}"
# Percent of RAM that must stay available.
WATCHDOG_MEM_AVAIL_PCT="${WATCHDOG_MEM_AVAIL_PCT:-15}"
# Swap in use at all is worth knowing on a 31GB box; 25% means real pressure.
WATCHDOG_SWAP_USED_PCT="${WATCHDOG_SWAP_USED_PCT:-25}"
# Free space floors. The OS disk gets the tighter one: dpkg needs room and a
# full root breaks Docker itself, not just one service.
WATCHDOG_OS_FREE_PCT="${WATCHDOG_OS_FREE_PCT:-10}"
WATCHDOG_SSD_FREE_PCT="${WATCHDOG_SSD_FREE_PCT:-15}"
# Restarts within one cycle that count as a crash loop rather than a restart.
WATCHDOG_RESTART_THRESHOLD="${WATCHDOG_RESTART_THRESHOLD:-2}"
WATCHDOG_KUMA_URL="${WATCHDOG_KUMA_URL:-http://127.0.0.1:3001}"

# The checks this module creates in Kuma, as `key|Display Name|description`.
# Adding a line here and re-running `watchdog_install` creates the monitor;
# the generated script dispatches on the key.
WATCHDOG_CHECKS=(
    "temp|CPU Temperature|Thermal headroom. Names the hottest containers when it trips."
    "load|CPU Load|Sustained load per core. Leading indicator of a thermal event."
    "memory|Memory Pressure|Available RAM and swap use. Names the largest consumers."
    "disk|Disk Space|Free space on the OS disk and the data SSD."
    "containers|Container Health|Containers that should be running and are not, are unhealthy, were OOM-killed, or are restart-looping."
    "shed|Thermal Shedding|Whether the thermal guardian currently has services stopped."
)

watchdog_install() {
    log_info "Installing resource watchdog..."
    mkdir -p /etc/corex /var/lib/corex

    _watchdog_write_conf
    _watchdog_write_script
    _watchdog_write_setup_helper
    _watchdog_write_logrotate
    _watchdog_write_units

    # Register the push monitors in Kuma. Skipped silently when the monitoring
    # module is not installed, so this module is safe to install unconditionally.
    if [[ -f "${DATA_ROOT:-/mnt/corex-data/service-data}/uptime-kuma/kuma.db" ]]; then
        watchdog_seed_monitors
    else
        log_info "Uptime Kuma not installed, watchdog will idle until it is"
    fi

    log_success "Resource watchdog installed (runs every 60s)"
}

# ── Config file ──────────────────────────────────────────────────────────────
# Written only when absent: it holds the push tokens, which must survive a
# re-run. _watchdog_sync_conf backfills keys added by a later version.
_watchdog_write_conf() {
    if [[ ! -f /etc/corex/watchdog.conf ]]; then
        cat > /etc/corex/watchdog.conf << WCEOF
# CoreX resource watchdog configuration.
# Set WATCHDOG_ENABLED=false to stop pushing without uninstalling.
WATCHDOG_ENABLED=true

WATCHDOG_KUMA_URL=${WATCHDOG_KUMA_URL}

# Thresholds. See lib/watchdog.sh for why each default is what it is.
WATCHDOG_TEMP_C=${WATCHDOG_TEMP_C}
WATCHDOG_LOAD_RATIO=${WATCHDOG_LOAD_RATIO}
WATCHDOG_MEM_AVAIL_PCT=${WATCHDOG_MEM_AVAIL_PCT}
WATCHDOG_SWAP_USED_PCT=${WATCHDOG_SWAP_USED_PCT}
WATCHDOG_OS_FREE_PCT=${WATCHDOG_OS_FREE_PCT}
WATCHDOG_SSD_FREE_PCT=${WATCHDOG_SSD_FREE_PCT}
WATCHDOG_RESTART_THRESHOLD=${WATCHDOG_RESTART_THRESHOLD}

# Data root, for locating the Kuma database and the SSD mount.
COREX_DATA_ROOT=${DATA_ROOT:-/mnt/corex-data/service-data}
COREX_SSD_MOUNT=/mnt/corex-data

# Push tokens, filled in by the setup helper. One per check.
WCEOF
        chmod 640 /etc/corex/watchdog.conf
    fi
    _watchdog_sync_conf
}

# Append any threshold key the running config predates. Same reasoning as
# thermal.conf: an operator's edits must survive an upgrade, but a new tunable
# must not read as empty under `set -u`.
_watchdog_sync_conf() {
    local k
    for k in WATCHDOG_ENABLED WATCHDOG_KUMA_URL WATCHDOG_TEMP_C \
             WATCHDOG_LOAD_RATIO WATCHDOG_MEM_AVAIL_PCT \
             WATCHDOG_SWAP_USED_PCT WATCHDOG_OS_FREE_PCT \
             WATCHDOG_SSD_FREE_PCT WATCHDOG_RESTART_THRESHOLD; do
        grep -q "^${k}=" /etc/corex/watchdog.conf 2>/dev/null && continue
        echo "${k}=${!k:-true}" >> /etc/corex/watchdog.conf
    done
}

# ── The watchdog script itself ───────────────────────────────────────────────
# Self-contained on purpose: it runs from systemd with no CoreX libraries
# sourced, exactly like the thermal guardian.
_watchdog_write_script() {
    install_script /usr/local/bin/corex-watchdog.sh 750 << 'WGEOF'
#!/bin/bash
# CoreX resource watchdog. Generated by lib/watchdog.sh, do not edit in place.
# Thresholds and push tokens live in /etc/corex/watchdog.conf.
#
# No `set -e`: a failing check must not prevent the remaining checks from
# reporting. That is the whole point of a watchdog.
set -uo pipefail

CONF=/etc/corex/watchdog.conf
STATE_DIR=/var/lib/corex
LOG=/var/log/corex-watchdog.log
STATS_CACHE=""

# shellcheck source=/dev/null
[[ -r "$CONF" ]] && . "$CONF"

# Default everything after sourcing. A conf file written by an older version is
# missing later keys, and under `set -u` an unset threshold aborts the run.
: "${WATCHDOG_ENABLED:=true}"
: "${WATCHDOG_KUMA_URL:=http://127.0.0.1:3001}"
: "${WATCHDOG_TEMP_C:=80}"
: "${WATCHDOG_LOAD_RATIO:=1.5}"
: "${WATCHDOG_MEM_AVAIL_PCT:=15}"
: "${WATCHDOG_SWAP_USED_PCT:=25}"
: "${WATCHDOG_OS_FREE_PCT:=10}"
: "${WATCHDOG_SSD_FREE_PCT:=15}"
: "${WATCHDOG_RESTART_THRESHOLD:=2}"
: "${COREX_SSD_MOUNT:=/mnt/corex-data}"

[[ "$WATCHDOG_ENABLED" == "true" ]] || exit 0

mkdir -p "$STATE_DIR" 2>/dev/null

say() {
    printf '%s watchdog: %s\n' "$(date -Is)" "$1" >> "$LOG" 2>/dev/null
    logger -t corex-watchdog "$1" 2>/dev/null || true
}

cleanup() { [[ -n "$STATS_CACHE" ]] && rm -f "$STATS_CACHE"; }
trap cleanup EXIT

# ── Push one heartbeat ──────────────────────────────────────────────────────
# A check with no token configured is a no-op, so the script is harmless before
# `corex manage watchdog-setup` has run or when Kuma is not installed.
push() {
    local key="$1" status="$2" msg="$3" ping="${4:-}"
    local var="WATCHDOG_TOKEN_${key^^}" token
    token="${!var:-}"
    [[ -n "$token" ]] || return 0

    local -a extra=()
    [[ -n "$ping" ]] && extra=(--data-urlencode "ping=${ping}")

    curl -fsS -G --max-time 10 -o /dev/null \
        --data-urlencode "status=${status}" \
        --data-urlencode "msg=${msg}" \
        "${extra[@]}" \
        "${WATCHDOG_KUMA_URL}/api/push/${token}" 2>/dev/null \
        || say "push failed for ${key}: is Kuma reachable at ${WATCHDOG_KUMA_URL}?"

    # The log stays one line per finding so `watchdog show` and grep remain
    # useful; only the notification gets the multi-line form.
    [[ "$status" == "down" ]] && say "${key} DOWN: ${msg//$'\n'/ | }"
    return 0
}

# ── Attribution ─────────────────────────────────────────────────────────────
# `docker stats` costs roughly a second with twenty containers, so it is
# collected once per run and only when a check has already tripped. An alert
# that says "the box is hot" is not actionable; one that names immich-ml at
# 190% is.
collect_stats() {
    [[ -n "$STATS_CACHE" ]] && return 0
    STATS_CACHE=$(mktemp /tmp/corex-watchdog-stats.XXXXXX) || { STATS_CACHE=""; return 1; }
    docker stats --no-stream --format '{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}' \
        > "$STATS_CACHE" 2>/dev/null || true
}

# Top three containers by CPU, as "name 190%, name 52%, name 31%".
top_cpu() {
    collect_stats || return 0
    awk -F'\t' 'NF>=2 { gsub(/%/,"",$2); if ($2+0 > 0) printf "%s\t%s\n", $2, $1 }' \
        "$STATS_CACHE" 2>/dev/null \
        | sort -rn | head -3 \
        | awk -F'\t' '{ printf "%s%s %.0f%%", sep, $2, $1; sep=", " } END { print "" }'
}

# Top three containers by memory, as "name 780M, name 512M, name 340M".
# MemUsage arrives as "123.4MiB / 512MiB"; normalise the first field to MiB so
# a GiB value does not sort below a MiB one on its leading digit.
top_mem() {
    collect_stats || return 0
    awk -F'\t' '
        NF>=3 {
            split($3, a, " "); v = a[1]; u = v
            gsub(/[0-9.]/, "", u); gsub(/[^0-9.]/, "", v)
            if      (u ~ /^GiB/) v = v * 1024
            else if (u ~ /^KiB/) v = v / 1024
            else if (u ~ /^B/)   v = v / 1048576
            if (v+0 > 0) printf "%.1f\t%s\n", v, $1
        }' "$STATS_CACHE" 2>/dev/null \
        | sort -rn | head -3 \
        | awk -F'\t' '{ printf "%s%s %.0fM", sep, $2, $1; sep=", " } END { print "" }'
}

# ── Check: CPU temperature ──────────────────────────────────────────────────
read_temp() {
    local t=""
    if command -v sensors &>/dev/null; then
        t=$(sensors -u 2>/dev/null \
            | awk '/^(Tctl|Tdie|Package id 0):/{getline; print $2; exit}')
        [[ -z "$t" ]] && t=$(sensors -u 2>/dev/null \
            | awk '/_input:/{print $2}' | sort -rn | head -1)
    fi
    if [[ -z "$t" ]]; then
        local best=0 v z
        for z in /sys/class/thermal/thermal_zone*/temp; do
            [[ -r "$z" ]] || continue
            v=$(( $(cat "$z" 2>/dev/null || echo 0) / 1000 ))
            (( v > best )) && best=$v
        done
        (( best > 0 )) && t=$best
    fi
    printf '%.0f' "${t:-0}" 2>/dev/null || echo 0
}

check_temp() {
    local t nl; t=$(read_temp); nl=$'\n'
    # No sensor is itself the finding: gotcha #17 exists because a thermal trip
    # is invisible without lm-sensors. Report it rather than passing silently.
    if [[ "$t" == "0" ]]; then
        push temp down "The CPU temperature cannot be read.${nl}Install lm-sensors. Without it a thermal shutdown leaves no trace in any log and looks exactly like someone pulling the plug."
        return
    fi
    if (( t >= WATCHDOG_TEMP_C )); then
        local msg="Running hot at ${t}C, above the ${WATCHDOG_TEMP_C}C limit." who
        who=$(top_cpu)
        [[ -n "$who" ]] && msg="${msg}${nl}Working hardest: ${who}"
        push temp down "$msg" "$t"
    else
        push temp up "Back to a normal ${t}C." "$t"
    fi
}

# ── Check: CPU load ─────────────────────────────────────────────────────────
check_load() {
    local load5 cores limit nl
    nl=$'\n'
    load5=$(awk '{print $2}' /proc/loadavg 2>/dev/null || echo 0)
    cores=$(nproc 2>/dev/null || echo 1)
    limit=$(awk -v c="$cores" -v r="$WATCHDOG_LOAD_RATIO" 'BEGIN{printf "%.2f", c*r}')

    if awk -v l="$load5" -v m="$limit" 'BEGIN{exit !(l > m)}'; then
        local msg="Busy: load ${load5} across ${cores} cores, above the ${limit} limit." who
        who=$(top_cpu)
        [[ -n "$who" ]] && msg="${msg}${nl}Working hardest: ${who}"
        push load down "$msg" "$load5"
    else
        push load up "Load is back to ${load5}, under the ${limit} limit." "$load5"
    fi
}

# ── Check: memory and swap ──────────────────────────────────────────────────
check_memory() {
    local total avail stotal sfree used_pct avail_pct swap_pct=0 nl
    nl=$'\n'
    total=$(awk '/^MemTotal:/{print $2}'     /proc/meminfo)
    avail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
    stotal=$(awk '/^SwapTotal:/{print $2}'   /proc/meminfo)
    sfree=$(awk '/^SwapFree:/{print $2}'     /proc/meminfo)
    [[ -n "${total:-}" && "${total:-0}" -gt 0 ]] || return 0

    avail_pct=$(( avail * 100 / total ))
    used_pct=$(( 100 - avail_pct ))
    (( ${stotal:-0} > 0 )) && swap_pct=$(( (stotal - sfree) * 100 / stotal ))

    local reasons=""
    (( avail_pct < WATCHDOG_MEM_AVAIL_PCT )) && \
        reasons="Running low on memory: only ${avail_pct}% free, and the floor is ${WATCHDOG_MEM_AVAIL_PCT}%."
    (( swap_pct > WATCHDOG_SWAP_USED_PCT )) && \
        reasons="${reasons:+$reasons }Swapping heavily: ${swap_pct}% of swap is in use, and the limit is ${WATCHDOG_SWAP_USED_PCT}%."

    if [[ -n "$reasons" ]]; then
        local msg="$reasons" who
        who=$(top_mem)
        [[ -n "$who" ]] && msg="${msg}${nl}Using the most: ${who}"
        push memory down "$msg" "$used_pct"
    else
        push memory up "Memory is comfortable again: ${used_pct}% used, swap at ${swap_pct}%." "$used_pct"
    fi
}

# ── Check: disk space ───────────────────────────────────────────────────────
# Computed from avail and size rather than df's Use%, which excludes the
# reserved blocks and so reads several percent optimistic on ext4.
free_pct() {
    df -P -k "$1" 2>/dev/null | awk 'NR==2 && $2>0 { printf "%d", $4*100/$2 }'
}

check_disk() {
    local osf ssdf reasons="" worst=100 nl
    nl=$'\n'
    osf=$(free_pct /)
    ssdf=$(free_pct "$COREX_SSD_MOUNT")

    if [[ -n "$osf" ]]; then
        (( osf < worst )) && worst=$osf
        (( osf < WATCHDOG_OS_FREE_PCT )) && \
            reasons="The OS disk is nearly full: ${osf}% free, and the floor is ${WATCHDOG_OS_FREE_PCT}%. This one stops Docker and apt working, not just a single service."
    fi
    if [[ -n "$ssdf" ]]; then
        (( ssdf < worst )) && worst=$ssdf
        (( ssdf < WATCHDOG_SSD_FREE_PCT )) && \
            reasons="${reasons:+$reasons$nl}The data SSD is filling up: ${ssdf}% free, and the floor is ${WATCHDOG_SSD_FREE_PCT}%."
    fi

    # Anything else CoreX has been given: the database volume, a separate
    # backup partition. Checking only the two original mounts meant a volume
    # added later was watched by nothing, and the database volume filling
    # stops Nextcloud, Immich and Cal.com at once.
    local extra pct
    for extra in /mnt/corex-fast /mnt/corex-backup; do
        mountpoint -q "$extra" 2>/dev/null || continue
        pct=$(free_pct "$extra")
        [[ -n "$pct" ]] || continue
        (( pct < worst )) && worst=$pct
        (( pct < WATCHDOG_SSD_FREE_PCT )) && \
            reasons="${reasons:+$reasons$nl}${extra} is filling up: ${pct}% free, and the floor is ${WATCHDOG_SSD_FREE_PCT}%."
    done

    # A mount that should be there and is not. Docker refuses to start without
    # the data disk, but a volume that disappears while the box is running is
    # silent: the services keep writing, to the empty directory underneath.
    local want
    for want in "$COREX_SSD_MOUNT" /mnt/corex-fast; do
        if [[ -d "$want" ]] && grep -qE "[[:space:]]${want}[[:space:]]" /etc/fstab 2>/dev/null \
           && ! mountpoint -q "$want" 2>/dev/null; then
            reasons="${reasons:+$reasons$nl}${want} is in fstab but is not mounted. Anything writing there is writing to the disk underneath it, not to the volume."
            worst=0
        fi
    done

    if [[ -n "$reasons" ]]; then
        push disk down "${reasons}${nl}Free some up with: corex manage cleanup" "$worst"
    else
        push disk up "Disks have room: ${osf:-?}% free on the OS disk, ${ssdf:-?}% free on the SSD." "$worst"
    fi
}

# ── Check: container health ─────────────────────────────────────────────────
# This is the check the HTTP monitors cannot do. It covers four faults, all of
# which have happened on this box and none of which change an HTTP response:
#
#   1. A container that should be running is not. Restart policy is the test:
#      `corex manage disable` sets restart=no, so a deliberately disabled
#      service is excluded automatically and does not alert.
#   2. Docker's own healthcheck says unhealthy while the port still answers.
#   3. The kernel OOM-killed it. A memory limit set too low looks like a
#      mysterious restart otherwise.
#   4. It is restart-looping. Kuma's HTTP check can easily land in the up
#      window of a container cycling every thirty seconds.
#
# One `docker inspect` over every container, so the cost is a single API call.
check_containers() {
    local ids raw prev_file="${STATE_DIR}/watchdog-restarts"
    ids=$(docker ps -aq 2>/dev/null)
    if [[ -z "$ids" ]]; then
        push containers down "Docker reports no containers at all, which means the engine is down or has lost its state."
        return
    fi

    # shellcheck disable=SC2086
    raw=$(docker inspect --format \
        '{{.Name}}|{{.State.Status}}|{{.RestartCount}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}|{{.HostConfig.RestartPolicy.Name}}|{{.State.OOMKilled}}' \
        $ids 2>/dev/null)
    [[ -n "$raw" ]] || return 0

    local down="" unhealthy="" oom="" looping="" now_state=""
    local name status rcount health policy oomk prev_rc prev_oom delta
    while IFS='|' read -r name status rcount health policy oomk; do
        [[ -n "${name:-}" ]] || continue
        name="${name#/}"
        now_state="${now_state}${name} ${rcount} ${oomk}"$'\n'

        prev_rc=$(awk -v n="$name" '$1==n {print $2}'  "$prev_file" 2>/dev/null)
        prev_oom=$(awk -v n="$name" '$1==n {print $3}' "$prev_file" 2>/dev/null)

        if [[ "$status" != "running" ]]; then
            # Restart policy is the intent signal. `corex manage disable` sets
            # restart=no, so a service stopped on purpose is correct, not a
            # fault, and must not alert.
            case "$policy" in
                always|unless-stopped) down="${down:+$down, }${name}" ;;
            esac
        else
            # Health is only meaningful while the container is up. Docker keeps
            # the last health verdict on a stopped container forever, so
            # checking it unconditionally reported ten stopped Coolify
            # containers as unhealthy on a box where they were switched off
            # deliberately.
            [[ "$health" == "unhealthy" ]] && \
                unhealthy="${unhealthy:+$unhealthy, }${name}"
        fi

        # OOMKilled is also sticky: it stays true until the container is
        # recreated, so reporting the flag itself alerts forever. Report the
        # transition instead. An absent previous sample means this is the first
        # run, where every flag looks like a transition, so skip it.
        [[ "$oomk" == "true" && -n "${prev_oom:-}" && "$prev_oom" != "true" ]] && \
            oom="${oom:+$oom, }${name}"

        if [[ -n "${prev_rc:-}" ]] && [[ "$rcount" =~ ^[0-9]+$ ]] \
           && [[ "$prev_rc" =~ ^[0-9]+$ ]]; then
            delta=$(( rcount - prev_rc ))
            (( delta >= WATCHDOG_RESTART_THRESHOLD )) && \
                looping="${looping:+$looping, }${name} (${delta}x)"
        fi
    done <<< "$raw"

    printf '%s' "$now_state" > "$prev_file" 2>/dev/null

    # One fault per line, because a container can be in several of these states
    # at once and running them together as a single sentence is unreadable on a
    # phone.
    local nl=$'\n' reasons="" first=""
    [[ -n "$down" ]]      && { reasons="Stopped, but told to restart: ${down}"; first="${down%%,*}"; }
    [[ -n "$unhealthy" ]] && { reasons="${reasons:+$reasons$nl}Failing their own health check: ${unhealthy}"; first="${first:-${unhealthy%%,*}}"; }
    [[ -n "$oom" ]]       && { reasons="${reasons:+$reasons$nl}Killed for using too much memory, so the limit is set too low: ${oom}"; first="${first:-${oom%%,*}}"; }
    [[ -n "$looping" ]]   && { reasons="${reasons:+$reasons$nl}Restarting over and over: ${looping}"; first="${first:-${looping%% *}}"; }

    local total running
    total=$(printf '%s\n' "$raw" | grep -c . )
    running=$(printf '%s\n' "$raw" | awk -F'|' '$2=="running"' | grep -c . )

    if [[ -n "$reasons" ]]; then
        # The container log is the only place the cause appears for this class
        # of fault, so name the command rather than leaving it to be recalled.
        [[ -n "$first" ]] && reasons="${reasons}${nl}Find out why with: docker logs --tail 30 ${first}"
        push containers down "$reasons" "$running"
    else
        push containers up "All ${running} of ${total} containers are running and healthy." "$running"
    fi
}

# ── Check: thermal shedding ─────────────────────────────────────────────────
# Shedding is a successful outcome for the guardian and a failure for the
# operator: services are down and the reason is only in a log. Surfacing it as
# an alert is what makes gotcha #25 debuggable, where the guardian shed 24
# containers and then waited for a temperature the hardware never reaches.
check_shed() {
    local list="${STATE_DIR}/thermal-shed.list" n=0 names=""
    if [[ -r "$list" ]]; then
        # No `|| echo 0` here. `grep -c` prints 0 and exits 1 when nothing
        # matches, so the fallback appended a second line and the arithmetic
        # below saw "0\n0" instead of a number.
        n=$(grep -c . "$list" 2>/dev/null)
        [[ "$n" =~ ^[0-9]+$ ]] || n=0
        names=$(paste -sd, - < "$list" 2>/dev/null | sed 's/,/, /g')
    fi
    if (( n > 0 )); then
        local nl=$'\n'
        push shed down \
            "Thermal guardian has stopped ${n} service(s) to shed heat.${nl}${names}${nl}They restart on their own once the CPU cools." "$n"
    else
        push shed up "Nothing is shed. Every container the guardian stopped is back." 0
    fi
}

# ── Run every check ─────────────────────────────────────────────────────────
# Each is independent. A check that errors must not stop the rest, which is why
# there is no `set -e` and no `&&` chaining here.
check_temp
check_load
check_memory
check_disk
check_containers
check_shed
exit 0
WGEOF
}

# ── Kuma registration helper ────────────────────────────────────────────────
# Written as Python because Kuma stores monitors in SQLite and the sqlite3 CLI
# is not installed on a stock Ubuntu server, while python3 always is. Kuma has
# no REST API for creating monitors; the web UI drives a Socket.io connection,
# which is not scriptable from a shell.
_watchdog_write_setup_helper() {
    install_script /usr/local/bin/corex-watchdog-setup.py 750 << 'PYEOF'
#!/usr/bin/env python3
"""Register CoreX watchdog push monitors in the Uptime Kuma database.

Reads `key<TAB>name<TAB>description` lines on stdin, creates any monitor that
does not already exist, links it to every active notification, applies a
readable Telegram message template, and prints the resulting
`WATCHDOG_TOKEN_<KEY>=<token>` lines on stdout.

Only token lines go to stdout, because the caller appends them straight to
/etc/corex/watchdog.conf and that file is sourced by bash. Progress goes to
stderr.

Idempotent: an existing monitor keeps its token and its notification links, so
re-running this never invalidates a working setup or duplicates a monitor.
"""
import json
import secrets
import sqlite3
import sys
from datetime import datetime, timezone

# A push monitor goes down when no heartbeat arrives within `interval`. The
# watchdog pushes every 60s, so 120 leaves one whole missed push of slack and
# timer jitter cannot manufacture a false alarm.
INTERVAL = 120
RETRY_INTERVAL = 120
# Beats to wait before re-notifying about a problem that is still unresolved.
# Roughly hourly: enough to remind, not enough to train you to mute it.
RESEND_INTERVAL = 30
# One retry, so a single bad sample becomes PENDING rather than an alert.
MAX_RETRIES = 1

# Kuma's default Telegram message is "[name] [status] msg" on a single line,
# which buries the two things you actually read first. This puts the verdict
# and the service on line one, where the phone's notification preview shows
# them, and the detail below.
#
# MarkdownV2 rather than HTML: in this mode Kuma escapes the interpolated
# values for us, so a container name or an error string containing brackets or
# a hyphen cannot break the parse and silently drop the whole notification.
# Markup in the template itself is left alone, which is why the bold works.
# What an Uptime Kuma alert looks like on a phone.
#
# Deliberately close to the default, and the restraint is the point: Telegram
# rejects a message whose MarkdownV2 does not parse, and a rejected alert is
# no alert at all. A clever template that breaks on one monitor name
# containing a hyphen silently turns off monitoring.
#
# So the only additions are a blank line, which is what makes the headline
# readable on a lock screen, and a closing line that differs by state. The
# wording that carries the weight lives in `msg`, which for the push monitors
# is written by lib/watchdog.sh in plain sentences.
#
# The template context Kuma actually provides is status, name, hostnameOrURL,
# msg, monitorJSON and heartbeatJSON. There is no `heartbeat` object and no
# localDateTime, and hostnameOrURL on a push monitor is the push URL, which
# carries the token, so neither is used here.
TELEGRAM_TEMPLATE = (
    "{{ status }} *{{ name }}*\n"
    "\n"
    "{{ msg }}\n"
    "{% if heartbeatJSON.status == 0 %}"
    "\n_I will message again when it recovers\\._"
    "{% endif %}"
)


# Every template CoreX has ever written. A notification carrying one of these
# is ours to update; anything else was written by the operator and is left
# alone.
#
# This list is the whole point of the function below. The first version skipped
# any notification that already had a template, which reads as politeness and
# is really gotcha #22 again: a generated thing that is only written when
# absent never changes on an existing install. The improved wording would have
# shipped in the repository and never reached a single phone.
COREX_TEMPLATES = {
    # v3.11.0, the first one.
    "{{ status }}  *{{ name }}*\n\n{{ msg }}",
    # v3.19.0, with the state-dependent closing line.
    TELEGRAM_TEMPLATE,
}


def apply_telegram_template(cur):
    """Put CoreX's message template on every Telegram notification.

    Updates a notification that has no template, and one carrying a template
    CoreX wrote earlier. Leaves anything else untouched, so an operator who
    wrote their own keeps it. Returns the names that were changed.
    """
    changed = []
    rows = list(cur.execute("SELECT id, name, config FROM notification"))
    for nid, name, cfg in rows:
        try:
            conf = json.loads(cfg)
        except (ValueError, TypeError):
            continue
        if conf.get("type") != "telegram":
            continue
        current = conf.get("telegramTemplate") or ""
        if conf.get("telegramUseTemplate") and current not in COREX_TEMPLATES:
            continue
        if current == TELEGRAM_TEMPLATE and conf.get("telegramUseTemplate"):
            continue                       # already current, nothing to do
        conf["telegramUseTemplate"] = True
        conf["telegramTemplate"] = TELEGRAM_TEMPLATE
        conf["telegramTemplateParseMode"] = "MarkdownV2"
        cur.execute("UPDATE notification SET config = ? WHERE id = ?",
                    (json.dumps(conf), nid))
        changed.append(name)
    return changed


def main(db_path):
    checks = []
    for line in sys.stdin:
        parts = line.rstrip("\n").split("\t")
        if len(parts) >= 2 and parts[0]:
            checks.append((parts[0], parts[1], parts[2] if len(parts) > 2 else ""))
    if not checks:
        return 0

    db = sqlite3.connect(db_path, timeout=30)
    db.execute("PRAGMA busy_timeout = 30000")
    cur = db.cursor()

    notif = [r[0] for r in cur.execute(
        "SELECT id FROM notification WHERE active = 1")]
    if not notif:
        print("# warning: no active notification in Kuma, monitors will be "
              "silent until one is configured", file=sys.stderr)

    user = cur.execute("SELECT id FROM user ORDER BY id LIMIT 1").fetchone()
    user_id = user[0] if user else 1
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")

    for key, name, desc in checks:
        row = cur.execute(
            "SELECT id, push_token FROM monitor WHERE name = ?", (name,)
        ).fetchone()

        if row and row[1]:
            mid, token = row
        else:
            token = secrets.token_hex(16)
            if row:
                mid = row[0]
                cur.execute(
                    "UPDATE monitor SET push_token = ?, type = 'push' WHERE id = ?",
                    (token, mid))
            else:
                cur.execute(
                    "INSERT INTO monitor (name, type, push_token, interval, "
                    "retry_interval, resend_interval, maxretries, active, "
                    "user_id, weight, created_date, description, upside_down) "
                    "VALUES (?, 'push', ?, ?, ?, ?, ?, 1, ?, 2000, ?, ?, 0)",
                    (name, token, INTERVAL, RETRY_INTERVAL, RESEND_INTERVAL,
                     MAX_RETRIES, user_id, now, desc))
                mid = cur.lastrowid

        for nid in notif:
            cur.execute(
                "INSERT INTO monitor_notification (monitor_id, notification_id) "
                "SELECT ?, ? WHERE NOT EXISTS (SELECT 1 FROM "
                "monitor_notification WHERE monitor_id = ? AND notification_id = ?)",
                (mid, nid, mid, nid))

        print("WATCHDOG_TOKEN_%s=%s" % (key.upper(), token))

    for name in apply_telegram_template(cur):
        print("applied Telegram message template to '%s'" % name, file=sys.stderr)

    db.commit()
    db.close()
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: corex-watchdog-setup.py <kuma.db>", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
PYEOF
}

# ── Register the push monitors in Uptime Kuma ───────────────────────────────
# Kuma caches its monitor list in memory, so a monitor inserted while it is
# running is not picked up until restart. Stopping it first also removes any
# chance of writing to the database underneath a live process.
watchdog_seed_monitors() {
    local db="${DATA_ROOT:-/mnt/corex-data/service-data}/uptime-kuma/kuma.db"
    if [[ ! -f "$db" ]]; then
        log_warning "Uptime Kuma database not found at ${db}, skipping monitor setup"
        return 1
    fi
    command -v python3 &>/dev/null || { log_warning "python3 missing, cannot register watchdog monitors"; return 1; }

    local was_running=false
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qxF uptime-kuma; then
        was_running=true
        log_info "Stopping Uptime Kuma to register watchdog monitors..."
        docker stop uptime-kuma >/dev/null 2>&1 || true
    fi

    # Cold backup before touching it. Cheap insurance on a file that holds
    # every monitor, notification and heartbeat.
    cp -a "$db" "${db}.pre-watchdog" 2>/dev/null || true

    local tokens rc=0
    tokens=$(printf '%s\n' "${WATCHDOG_CHECKS[@]}" | tr '|' '\t' \
        | python3 /usr/local/bin/corex-watchdog-setup.py "$db") || rc=$?

    if (( rc != 0 )) || [[ -z "$tokens" ]]; then
        log_warning "Monitor registration failed; database backup kept at ${db}.pre-watchdog"
        [[ "$was_running" == "true" ]] && docker start uptime-kuma >/dev/null 2>&1 || true
        return 1
    fi

    # Replace the token block wholesale. Rewriting in place keeps operator
    # edits to the thresholds above it untouched.
    local tmp
    tmp=$(mktemp) || return 1
    grep -v '^WATCHDOG_TOKEN_' /etc/corex/watchdog.conf > "$tmp" 2>/dev/null
    # Filtered, not appended wholesale: this file is sourced by bash, so a
    # stray line from the helper would be executed rather than ignored.
    printf '%s\n' "$tokens" | grep '^WATCHDOG_TOKEN_' >> "$tmp"
    cat "$tmp" > /etc/corex/watchdog.conf
    rm -f "$tmp"
    chmod 640 /etc/corex/watchdog.conf

    [[ "$was_running" == "true" ]] && docker start uptime-kuma >/dev/null 2>&1 || true

    local n; n=$(printf '%s\n' "$tokens" | grep -c '^WATCHDOG_TOKEN_')
    log_success "Registered ${n} watchdog monitors in Uptime Kuma"
}

# Nothing in CoreX rotated its own logs, and this module adds the chattiest
# one: during a sustained fault the watchdog writes a line per failing check
# per minute. The config covers the other CoreX logs too, since they have the
# same problem and no other module claims them.
_watchdog_write_logrotate() {
    cat > /etc/logrotate.d/corex << LREOF
/var/log/corex-watchdog.log
/var/log/corex-backup.log
{
    # Ubuntu ships /var/log as root:syslog 775, and logrotate refuses to touch
    # a log whose parent directory is group-writable unless told which
    # identity to rotate as. Without this line every entry here is skipped
    # with "insecure permissions" and nothing rotates.
    su root syslog
    weekly
    rotate 4
    maxsize 10M
    missingok
    notifempty
    compress
    delaycompress
    # The watchdog and the guardian hold the file open and append to it, so
    # renaming it out from under them would leave them writing to a deleted
    # inode until the next systemd invocation.
    copytruncate
}

# The blackbox log is on its own schedule because it is crash evidence, not
# operational noise. It is the only record that survives a thermal trip or a
# power cut (gotcha #16), so it is kept for six months rather than one, and
# rotated by size so a rotation never lands in the middle of an incident.
/mnt/corex-data/blackbox.log
{
    su root root
    monthly
    rotate 6
    maxsize 50M
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
LREOF
    chmod 644 /etc/logrotate.d/corex
}

_watchdog_write_units() {
    cat > /etc/systemd/system/corex-watchdog.service << WSEOF
[Unit]
Description=CoreX resource watchdog (pushes host health to Uptime Kuma)
After=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/corex-watchdog.sh
WSEOF

    cat > /etc/systemd/system/corex-watchdog.timer << WTEOF
[Unit]
Description=Run the CoreX resource watchdog every 60s

[Timer]
OnBootSec=90s
OnUnitActiveSec=60s
AccuracySec=5s

[Install]
WantedBy=timers.target
WTEOF

    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now corex-watchdog.timer 2>/dev/null || true
}

# ── Reporting ───────────────────────────────────────────────────────────────
# Used by `corex manage health`, so an operator can tell "no alerts because
# everything is fine" from "no alerts because nothing is being measured".
watchdog_status() {
    if ! systemctl is-active --quiet corex-watchdog.timer 2>/dev/null; then
        echo "INACTIVE"; return 0
    fi
    local conf=/etc/corex/watchdog.conf
    [[ -r "$conf" ]] || { echo "INACTIVE"; return 0; }
    grep -q '^WATCHDOG_ENABLED=false' "$conf" && { echo "DISABLED"; return 0; }
    grep -q '^WATCHDOG_TOKEN_' "$conf" || { echo "UNREGISTERED"; return 0; }
    echo "ACTIVE"
}
