#!/bin/bash
#
# Scheduled maintenance: the jobs that keep a box healthy and that nobody
# remembers to run.
#
# One timer, hourly, and a runner that decides what is due. Four timers would
# have been the obvious shape and it is the wrong one here: the tasks share a
# machine that thermal trips, so exactly one of them may run at a time and
# every one of them has to be refused when the CPU is already hot. That
# decision has to live in one place.
#
# The other rule is about honesty. The plan for this module said a scheduler
# that schedules a backup with no repository is worse than none, because the
# page will say it ran. So every task records what actually happened, a
# missing prerequisite is a failure rather than a skip, and the Maintenance
# tab reads that record rather than the schedule.
#
# Config:  /etc/corex/maintenance.conf   (0640, hand-editable)
# History: /var/lib/corex/maintenance.json
# Log:     /var/log/corex-maintenance.log

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

MAINT_CONF=/etc/corex/maintenance.conf
MAINT_STATE=/var/lib/corex/maintenance.json
MAINT_LOG=/var/log/corex-maintenance.log

# task|label|what it is|default enabled|default interval hours|default hour
#
# os-upgrade is off by default and that is deliberate. It is the only task
# here that can leave the machine unbootable: an unattended kernel upgrade
# interrupted by a thermal trip is what left this box with systemd unpacked
# and unconfigured (gotcha #18). It refuses to start when hot, dirty or
# freshly booted, but choosing to run it unattended is still the operator's
# call to make.
MAINT_TASKS=(
    "backup|Backup|Restic snapshot of every service's data and compose file, then prune and spot-check.|true|24|3"
    "cleanup|Docker cleanup|Remove images and build cache nothing is using. This is the disk that fills first.|true|168|4"
    "timemachine|Time Machine check|Confirm the share is being written to and the container is not restart-looping.|true|168|5"
    "os-upgrade|OS packages|Supervised apt upgrade, including the kernel packages unattended-upgrades is told to leave alone.|false|720|4"
)

maintenance_install() {
    log_info "Installing scheduled maintenance..."
    mkdir -p /etc/corex /var/lib/corex

    _maintenance_write_conf
    _maintenance_write_script
    _maintenance_write_units
    _maintenance_drop_backup_cron
    _maintenance_refresh_backup_scripts

    log_success "Scheduled maintenance installed (checks what is due every hour)"
}

# ── Config ───────────────────────────────────────────────────────────────────
# Written when absent and backfilled after that, so an operator's edited
# schedule survives an upgrade while a newly added task still appears.
_maintenance_write_conf() {
    if [[ ! -f "$MAINT_CONF" ]]; then
        cat > "$MAINT_CONF" << MCEOF
# CoreX scheduled maintenance.
#
# MAINTENANCE_ENABLED=false stops everything without uninstalling the timer.
# Each task has three settings: whether it runs, how many hours between runs,
# and the hour of the day it prefers. A task overdue by half its interval
# again runs at the next opportunity rather than waiting for its hour, so a
# machine that is off overnight still gets its backup.
MAINTENANCE_ENABLED=true

# Nothing starts above this, and a task already running is paused when it
# crosses it and resumed eight degrees lower. A check before starting is not
# enough on its own: the first full backup began at 66C and reached 96.8C six
# minutes later, and the thermal guardian shut the machine down at 97C.
MAINTENANCE_MAX_TEMP_C=85

# Cores restic may compress on. It is Go and will use every one of them
# otherwise, which is what produced the 96.8C above.
MAINTENANCE_BACKUP_CORES=2

MCEOF
        local row task label enabled interval hour
        for row in "${MAINT_TASKS[@]}"; do
            IFS='|' read -r task label _ enabled interval hour <<< "$row"
            local key="${task^^}"; key="${key//-/_}"
            {
                echo "# ${label}"
                echo "MAINTENANCE_${key}_ENABLED=${enabled}"
                echo "MAINTENANCE_${key}_INTERVAL_H=${interval}"
                echo "MAINTENANCE_${key}_HOUR=${hour}"
                echo ""
            } >> "$MAINT_CONF"
        done
        chmod 640 "$MAINT_CONF"
    fi
    _maintenance_sync_conf
}

_maintenance_sync_conf() {
    local row task enabled interval hour key k
    grep -q '^MAINTENANCE_ENABLED=' "$MAINT_CONF" 2>/dev/null || \
        echo "MAINTENANCE_ENABLED=true" >> "$MAINT_CONF"
    grep -q '^MAINTENANCE_MAX_TEMP_C=' "$MAINT_CONF" 2>/dev/null || \
        echo "MAINTENANCE_MAX_TEMP_C=85" >> "$MAINT_CONF"
    grep -q '^MAINTENANCE_BACKUP_CORES=' "$MAINT_CONF" 2>/dev/null || \
        echo "MAINTENANCE_BACKUP_CORES=2" >> "$MAINT_CONF"
    for row in "${MAINT_TASKS[@]}"; do
        IFS='|' read -r task _ _ enabled interval hour <<< "$row"
        key="${task^^}"; key="${key//-/_}"
        for k in "ENABLED=${enabled}" "INTERVAL_H=${interval}" "HOUR=${hour}"; do
            grep -q "^MAINTENANCE_${key}_${k%%=*}=" "$MAINT_CONF" 2>/dev/null && continue
            echo "MAINTENANCE_${key}_${k}" >> "$MAINT_CONF"
        done
    done
    chmod 640 "$MAINT_CONF"
}

# The v1 installer put the backup on root's crontab at 3AM. Leaving that in
# place means the snapshot is taken twice, once by cron and once by the timer,
# which is not harmful but is two hours of USB disk churn for one snapshot and
# two rows in the history that disagree about what happened.
_maintenance_drop_backup_cron() {
    crontab -l 2>/dev/null | grep -q 'corex-backup' || return 0
    local tmp
    tmp="$(mktemp)"
    crontab -l 2>/dev/null | grep -v 'corex-backup' > "$tmp"
    crontab "$tmp"
    rm -f "$tmp"
    log_info "Removed the backup cron entry, the maintenance timer owns it now"
}

# The backup script is generated by CoreX, so it is regenerated here rather
# than trusted (gotcha #22). The version found on a box installed before
# v2.5.0 has the Restic password written into a world readable file, and the
# version after it read that password without trimming the credential file's
# column padding, which meant it could not open the repository it was paired
# with. Both are silent: the script logged "Backup complete" either way.
_maintenance_refresh_backup_scripts() {
    local lib="${SCRIPT_DIR:-}/lib/backup.sh"
    [[ -f "$lib" ]] || return 0
    # shellcheck source=/dev/null
    source "$lib"
    declare -f backup_write_scripts >/dev/null 2>&1 || return 0
    backup_write_scripts
    log_info "Rewrote /usr/local/bin/corex-backup.sh and corex-restore.sh"
}

# ── The runner ───────────────────────────────────────────────────────────────
# Self-contained, like the watchdog and the thermal guardian: it runs from
# systemd with no CoreX libraries sourced.
_maintenance_write_script() {
    cat > /usr/local/bin/corex-maintenance.sh << 'MREOF'
#!/bin/bash
# CoreX scheduled maintenance. Installed by lib/maintenance.sh; do not edit
# here, the settings are in /etc/corex/maintenance.conf.
set -uo pipefail

CONF=/etc/corex/maintenance.conf
STATE=/var/lib/corex/maintenance.json
LOG=/var/log/corex-maintenance.log
LOCK=/var/lib/corex/maintenance.lock
MANAGE=/home/serveradmin/corex-pro/corex-manage.sh
BACKUP=/usr/local/bin/corex-backup.sh
RESTIC_REPO=/mnt/corex-data/backups/restic-repo
TM_DATA=/mnt/corex-data/timemachine-data

# shellcheck disable=SC1090
[[ -r "$CONF" ]] && source "$CONF"
: "${MAINTENANCE_ENABLED:=true}"
: "${MAINTENANCE_MAX_TEMP_C:=85}"
: "${MAINTENANCE_BACKUP_CORES:=2}"

log() { echo "$(date '+%Y-%m-%dT%H:%M:%S%z') maintenance: $*" >> "$LOG"; }

[[ "$MAINTENANCE_ENABLED" == "true" ]] || exit 0

# Find the repo wherever this box keeps it. The path above is the usual one;
# an install that lives somewhere else must still be able to run cleanup.
if [[ ! -x "$MANAGE" ]]; then
    for cand in /home/*/corex-pro/corex-manage.sh /opt/corex-pro/corex-manage.sh \
                /root/corex-pro/corex-manage.sh; do
        [[ -x "$cand" ]] && { MANAGE="$cand"; break; }
    done
fi

# One task at a time, across invocations. Two of these on a box that trips at
# TjMax is the failure this whole module is arranged to avoid.
exec 9>"$LOCK"
flock -n 9 || { log "another run still going, skipping this hour"; exit 0; }

cpu_temp() {
    local t
    if command -v sensors >/dev/null 2>&1; then
        t="$(sensors 2>/dev/null | sed -n 's/^Tctl:[[:space:]]*+\([0-9.]*\).*/\1/p' | head -1)"
        [[ -n "$t" ]] && { echo "${t%.*}"; return 0; }
    fi
    local hottest=0 zone
    for zone in /sys/class/thermal/thermal_zone*/temp; do
        [[ -r "$zone" ]] || continue
        t=$(( $(cat "$zone") / 1000 ))
        (( t > hottest )) && hottest=$t
    done
    echo "$hottest"
}

# ── History ─────────────────────────────────────────────────────────────────
# JSON, written with python3 so a partial write cannot corrupt it and so the
# agent can hand the document to the dashboard unchanged.

state_get_last() {
    python3 - "$STATE" "$1" << 'PYEOF' 2>/dev/null || echo 0
import json, sys
try:
    with open(sys.argv[1]) as fh:
        print(int(json.load(fh).get("tasks", {}).get(sys.argv[2], {}).get("last", 0)))
except Exception:
    print(0)
PYEOF
}

# A run and a deferral are recorded separately, and that is not tidiness.
#
# Writing "last" on a deferral was measured doing real harm on the first hot
# hour after this shipped: the timer found the backup due, the CPU was at 86C,
# it declined, and stamping the attempt as the last run meant due() would not
# ask again for a day. A refusal to start is not a run, so it must not reset
# the clock, and the page has to be able to say which of the two it is
# looking at.
state_record() {
    python3 - "$STATE" "$1" "$2" "$3" "$4" "$5" << 'PYEOF'
import json, os, sys, time
path, task, state, rc, elapsed, detail = sys.argv[1:7]
try:
    with open(path) as fh:
        doc = json.load(fh)
except Exception:
    doc = {}
row = doc.setdefault("tasks", {}).setdefault(task, {})
now = int(time.time())
if state == "deferred":
    row["deferred_at"] = now
    # Enough to say why, not a transcript.
    row["deferred_detail"] = detail[:200]
else:
    row.update({
        "last": now,
        "state": state,
        "rc": int(rc),
        "elapsed": int(elapsed),
        # The full output is in the log next door, and this document is
        # served to a web page.
        "detail": detail[:400],
    })
tmp = path + ".tmp"
with open(tmp, "w") as fh:
    json.dump(doc, fh, sort_keys=True, indent=1)
os.replace(tmp, path)
os.chmod(path, 0o644)
PYEOF
}

notify() {
    local kind="$1" headline="$2" body="$3" detail="$4"
    python3 - "$kind" "$headline" "$body" "$detail" << 'PYEOF' 2>/dev/null || true
import sys
sys.path.insert(0, "/usr/local/lib/corex")
import corex_common as cc
kind, headline, body, detail = sys.argv[1:5]
token, chat = cc.telegram_creds()
if token and chat:
    cc.telegram_send(token, chat, cc.message(kind, headline, body, detail=detail))
PYEOF
}

# ── Is it due ───────────────────────────────────────────────────────────────

due() {
    local task="$1" key interval hour last now elapsed
    key="${task^^}"; key="${key//-/_}"
    local en_var="MAINTENANCE_${key}_ENABLED"
    local iv_var="MAINTENANCE_${key}_INTERVAL_H"
    local hr_var="MAINTENANCE_${key}_HOUR"
    [[ "${!en_var:-false}" == "true" ]] || return 1
    interval="${!iv_var:-24}"
    hour="${!hr_var:-3}"
    last="$(state_get_last "$task")"
    now="$(date +%s)"
    elapsed=$(( now - last ))
    (( elapsed >= interval * 3600 )) || return 1
    # Its own hour, or overdue by half an interval again. The second clause is
    # what makes this work on a machine that is switched off at night: without
    # it a backup scheduled for 03:00 on a box that sleeps from 01:00 never
    # happens, and the history says it is due forever.
    [[ "$(date +%-H)" == "$hour" ]] && return 0
    (( elapsed >= interval * 3600 * 3 / 2 )) && return 0
    return 1
}

# ── The tasks ───────────────────────────────────────────────────────────────
# Each prints its own summary and returns a shell status. A prerequisite that
# is missing is a failure, never a quiet success: the whole point of the
# history is that it can be trusted.

task_backup() {
    [[ -x "$BACKUP" ]] || { echo "$BACKUP is missing"; return 1; }
    if [[ ! -f "${RESTIC_REPO}/config" ]]; then
        echo "there is no Restic repository at ${RESTIC_REPO}, so nothing was backed up"
        return 1
    fi
    # restic is Go, and left alone it uses every core to compress. Measured on
    # this hardware: the first full snapshot took the CPU from 66C to 96.8C in
    # six minutes and the thermal guardian shut the machine down at 97C to
    # avoid a hardware trip. GOMAXPROCS is the lever that stops that
    # happening, the same one the dashboard build uses.
    #
    # HOME matters too. Under systemd there is none, so restic reports
    # "unable to locate cache directory" and reads every file on every run,
    # which is both slow and hot. With a cache, later runs are incremental.
    export GOMAXPROCS="${MAINTENANCE_BACKUP_CORES:-2}"
    export HOME=/var/lib/corex
    export RESTIC_CACHE_DIR=/var/lib/corex/restic-cache
    mkdir -p "$RESTIC_CACHE_DIR"
    nice -n 19 ionice -c 3 "$BACKUP" 2>&1 | tail -20
    # The script writes its own log and swallows restic's status, so the
    # snapshot list is what says whether this run produced anything.
    # Trimmed on both sides. The credentials file is column aligned, so a
    # label is followed by padding, and leaving that padding in the password
    # is how a repository ends up keyed on two spaces plus the real value.
    local pw
    pw="$(grep -m1 'Restic Backup:' /root/corex-credentials.txt 2>/dev/null \
          | sed -e 's/^[^:]*:[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [[ -n "$pw" ]] || { echo "the Restic password is not in /root/corex-credentials.txt"; return 1; }
    local latest
    latest="$(RESTIC_REPOSITORY="$RESTIC_REPO" RESTIC_PASSWORD="$pw" \
              restic snapshots --latest 1 --json 2>/dev/null \
              | python3 -c 'import json,sys
try:
    s = json.load(sys.stdin)
    print(s[-1]["time"] if s else "")
except Exception:
    print("")' 2>/dev/null)"
    [[ -n "$latest" ]] || { echo "restic holds no snapshot after this run"; return 1; }
    echo "latest snapshot ${latest}"
}

task_cleanup() {
    [[ -x "$MANAGE" ]] || { echo "cannot find corex-manage.sh"; return 1; }
    nice -n 19 bash "$MANAGE" cleanup 2>&1 | tail -20
}

# Time Machine has no HTTP endpoint and no Kuma monitor, and it once
# crash-looped sixty times over several hours while `docker ps` showed it Up
# on almost every look (gotcha #29). So this reports two things a glance
# cannot: whether the restart count is climbing, and whether anything has
# actually been written lately.
task_timemachine() {
    docker inspect timemachine >/dev/null 2>&1 || {
        echo "Time Machine is not installed here"; return 0; }
    local restarts running
    restarts="$(docker inspect -f '{{.RestartCount}}' timemachine 2>/dev/null || echo 0)"
    running="$(docker inspect -f '{{.State.Running}}' timemachine 2>/dev/null || echo false)"
    local bundle newest size
    bundle="$(find "$TM_DATA" -maxdepth 2 -name '*.sparsebundle' -print -quit 2>/dev/null)"
    if [[ -z "$bundle" ]]; then
        echo "running=${running} restarts=${restarts}, but no sparsebundle exists yet, so no Mac has ever backed up here"
        [[ "$running" == "true" ]] || return 1
        return 0
    fi
    newest="$(find "$bundle" -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1)"
    newest="${newest%.*}"
    size="$(du -sh "$bundle" 2>/dev/null | cut -f1)"
    local age_days=0
    [[ -n "$newest" ]] && age_days=$(( ( $(date +%s) - newest ) / 86400 ))
    echo "running=${running} restarts=${restarts} size=${size} last written ${age_days}d ago"
    [[ "$running" == "true" ]] || return 1
    (( restarts > 5 )) && return 1
    return 0
}

task_os_upgrade() {
    [[ -x "$MANAGE" ]] || { echo "cannot find corex-manage.sh"; return 1; }
    # It refuses on its own above 85C, with a dirty dpkg database, or under
    # fifteen minutes of uptime. That refusal is a correct outcome, not a
    # failure, so its exit status is passed through unchanged.
    nice -n 10 bash "$MANAGE" os-upgrade --yes 2>&1 | tail -25
}

# ── Keeping a running task inside the thermal budget ────────────────────────
#
# MAINTENANCE_MAX_TEMP_C started as a check before a task begins, and gotcha
# #31 already says in as many words that a pre-flight temperature check is not
# enough on its own. It was right. The first full backup started at 66C, six
# minutes later the CPU was at 96.8C, and the thermal guardian stopped every
# container and powered the machine off at 97C to avoid a hardware trip. The
# pre-flight check had passed, correctly, thirty degrees earlier.
#
# So the task runs in the background and is paused when it gets too hot.
# SIGSTOP is the right instrument: restic, apt and a Docker prune all resume
# from a stop with no state to lose, whereas killing any of them mid-way is a
# choice between a wasted run and a dirty transaction. The task is paused
# rather than throttled because there is nothing to throttle it with that the
# scheduler has not already been told about through nice.
#
# The hysteresis is deliberate. Resuming the moment it drops below the limit
# produces a task that spends its life oscillating around the shed threshold,
# so it stays paused until there is real headroom.
# Signal the task and everything it started, walking the tree explicitly.
#
# Not `kill -- -$pid`. This function is called inside a command substitution,
# where bash does not reliably make a background job its own process group
# leader, so the negative form either fails or, worse, names the group this
# script is itself in: stopping that stops the governor loop as well and
# nothing ever resumes anything. Walking children is a few more lines and has
# no such failure mode.
#
# The parent is stopped before its children so it cannot spawn more while the
# walk is in progress, and resumed after them so it does not immediately
# reap a child that is still stopped.
_signal_tree() {
    local root="$1" sig="$2" child
    if [[ "$sig" == "STOP" ]]; then
        kill -STOP "$root" 2>/dev/null || true
        for child in $(pgrep -P "$root" 2>/dev/null); do
            _signal_tree "$child" STOP
        done
    else
        for child in $(pgrep -P "$root" 2>/dev/null); do
            _signal_tree "$child" CONT
        done
        kill -CONT "$root" 2>/dev/null || true
    fi
}

run_governed() {
    local fn="$1"
    local resume_at=$(( MAINTENANCE_MAX_TEMP_C - 8 ))
    local out; out="$(mktemp)"

    "$fn" > "$out" 2>&1 &
    local pid=$!
    local paused=false pauses=0 t

    while kill -0 "$pid" 2>/dev/null; do
        sleep 15
        kill -0 "$pid" 2>/dev/null || break
        t="$(cpu_temp)"
        [[ -n "$t" ]] || continue
        if [[ "$paused" == "false" ]] && (( t >= MAINTENANCE_MAX_TEMP_C )); then
            _signal_tree "$pid" STOP
            paused=true; pauses=$((pauses+1))
            log "paused at ${t}C, over the ${MAINTENANCE_MAX_TEMP_C}C limit"
        elif [[ "$paused" == "true" ]] && (( t <= resume_at )); then
            _signal_tree "$pid" CONT
            paused=false
            log "resumed at ${t}C"
        fi
    done

    # A task left stopped never exits, so wait would hang for as long as the
    # unit timeout allows.
    [[ "$paused" == "true" ]] && _signal_tree "$pid" CONT
    wait "$pid"
    local rc=$?
    cat "$out"
    (( pauses > 0 )) && echo "(paused ${pauses} time(s) to stay under ${MAINTENANCE_MAX_TEMP_C}C)"
    rm -f "$out"
    return "$rc"
}

# ── Run whatever is due ─────────────────────────────────────────────────────

TASKS="backup cleanup timemachine os-upgrade"
if [[ $# -gt 0 ]]; then
    # A named task runs whether or not it is due. This is what
    # `corex manage maintenance run <task>` uses.
    TASKS="$*"
    FORCED=1
else
    FORCED=0
fi

temp="$(cpu_temp)"
ran=0
for task in $TASKS; do
    if [[ "$FORCED" != "1" ]]; then
        due "$task" || continue
    fi
    if (( temp >= MAINTENANCE_MAX_TEMP_C )); then
        log "$task is due but the CPU is at ${temp}C, over the ${MAINTENANCE_MAX_TEMP_C}C limit"
        state_record "$task" "deferred" 0 0 "deferred, CPU at ${temp}C"
        continue
    fi

    log "$task starting (CPU ${temp}C)"
    started=$(date +%s)
    output="$(run_governed "task_${task//-/_}" 2>&1)"
    rc=$?
    elapsed=$(( $(date +%s) - started ))
    summary="$(echo "$output" | tr -d '\r' | grep -v '^[[:space:]]*$' | tail -3 | tr '\n' ' ')"
    [[ -n "$summary" ]] || summary="no output"

    if (( rc == 0 )); then
        log "$task ok in ${elapsed}s: $summary"
        state_record "$task" "ok" 0 "$elapsed" "$summary"
    else
        log "$task FAILED rc=$rc in ${elapsed}s: $summary"
        state_record "$task" "failed" "$rc" "$elapsed" "$summary"
        notify fail "Scheduled ${task} did not work" \
            "It ran for ${elapsed}s and came back with an error, so treat this as not done." \
            "$summary"
    fi
    ran=$(( ran + 1 ))
    # One per invocation. The timer comes round again in an hour, and running
    # a backup straight into a cleanup is how a marginal cooling system
    # becomes a thermal trip.
    break
done

(( ran > 0 )) || exit 0
MREOF
    chmod 750 /usr/local/bin/corex-maintenance.sh
}

_maintenance_write_units() {
    cat > /etc/systemd/system/corex-maintenance.service << MSEOF
[Unit]
Description=CoreX scheduled maintenance (backup, cleanup, checks)
After=docker.service

[Service]
Type=oneshot
# Long enough for a first Restic snapshot of a full data SSD over USB, and
# short enough that a wedged run does not hold the lock forever.
TimeoutStartSec=4h
Nice=10
IOSchedulingClass=idle
ExecStart=/usr/local/bin/corex-maintenance.sh
MSEOF

    cat > /etc/systemd/system/corex-maintenance.timer << MTEOF
[Unit]
Description=Check hourly whether any CoreX maintenance is due

[Timer]
OnBootSec=10min
OnUnitActiveSec=1h
AccuracySec=5min
# So a machine that was off through its window catches up on the next boot
# rather than waiting a whole interval.
Persistent=true

[Install]
WantedBy=timers.target
MTEOF

    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now corex-maintenance.timer 2>/dev/null || true
}

# ── Reporting ───────────────────────────────────────────────────────────────

maintenance_status() {
    systemctl is-active --quiet corex-maintenance.timer 2>/dev/null || { echo "INACTIVE"; return 0; }
    [[ -r "$MAINT_CONF" ]] || { echo "INACTIVE"; return 0; }
    grep -q '^MAINTENANCE_ENABLED=false' "$MAINT_CONF" && { echo "DISABLED"; return 0; }
    echo "ACTIVE"
}

maintenance_show() {
    echo ""
    echo -e "${BOLD}Scheduled maintenance${NC}"
    echo ""
    case "$(maintenance_status)" in
        ACTIVE)   echo -e "  Timer: ${GREEN}active${NC}, checks what is due every hour" ;;
        DISABLED) echo -e "  Timer: ${YELLOW}running but switched off${NC} in ${MAINT_CONF}" ;;
        *)        echo -e "  Timer: ${RED}not installed${NC}, run: corex manage maintenance setup" ;;
    esac

    # shellcheck disable=SC1090
    [[ -r "$MAINT_CONF" ]] && source "$MAINT_CONF"
    echo ""

    local row task label desc key en iv hr
    for row in "${MAINT_TASKS[@]}"; do
        IFS='|' read -r task label desc _ _ _ <<< "$row"
        key="${task^^}"; key="${key//-/_}"
        en="MAINTENANCE_${key}_ENABLED"; iv="MAINTENANCE_${key}_INTERVAL_H"; hr="MAINTENANCE_${key}_HOUR"
        if [[ "${!en:-false}" == "true" ]]; then
            echo -e "  ${BOLD}${label}${NC}: every ${!iv:-?}h, preferring ${!hr:-?}:00"
        else
            echo -e "  ${BOLD}${label}${NC}: ${YELLOW}off${NC}"
        fi
        echo "    ${desc}"
        _maintenance_print_last "$task"
        echo ""
    done

    if [[ -r "$MAINT_LOG" ]]; then
        echo "  Recent runs:"
        tail -6 "$MAINT_LOG" | sed 's/^/    /'
        echo ""
    fi
}

_maintenance_print_last() {
    [[ -r "$MAINT_STATE" ]] || { echo "    Never run."; return 0; }
    python3 - "$MAINT_STATE" "$1" << 'PYEOF'
import datetime, json, sys
try:
    with open(sys.argv[1]) as fh:
        row = json.load(fh).get("tasks", {}).get(sys.argv[2])
except Exception:
    row = None
if not row:
    print("    Never run.")
    raise SystemExit(0)
last = int(row.get("last", 0) or 0)
if not last:
    print("    Never run.")
else:
    when = datetime.datetime.fromtimestamp(last).strftime("%Y-%m-%d %H:%M")
    state = row.get("state", "?")
    mark = {"ok": "[  OK]", "failed": "[FAIL]"}.get(state, "[    ]")
    print("    %s last run %s in %ss: %s" % (mark, when, row.get("elapsed", 0),
                                             row.get("detail", "")))
held = int(row.get("deferred_at", 0) or 0)
if held > last:
    when = datetime.datetime.fromtimestamp(held).strftime("%Y-%m-%d %H:%M")
    print("    [WARN] held back at %s: %s" % (when, row.get("deferred_detail", "")))
PYEOF
}
