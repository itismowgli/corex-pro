#!/bin/bash
# lib/recovery.sh — CoreX Pro
# Getting the box back on its own, without someone walking over to it.
#
# THE TWO FAILURES THIS COVERS, WHICH NEED DIFFERENT ANSWERS
#
# 1. The kernel hangs. Nothing responds, nothing is logged, and the journal
#    simply stops mid-line, because journald never flushes (gotcha #16). No
#    software on the machine can fix this, because no software on the machine
#    is running. The only thing that can is hardware.
#
#    Measured on a real box: a boot that ended with zero clean-shutdown
#    markers, then a 73 minute gap before the next one. That gap is a person
#    noticing and walking over to the power button.
#
#    So: enable the board's watchdog timer and let systemd pet it. If systemd
#    stops petting, the hardware resets the machine without asking anyone.
#
# 2. Services are down but the box is fine. Usually the thermal guardian shed
#    load and something interrupted the recovery, or a container died and its
#    restart policy had been cleared. The box answers SSH, so the hardware
#    watchdog will never fire, and from the outside it looks identical to a
#    hang: nothing works.
#
#    That one is fixable in software, and the fix is to notice and act rather
#    than wait to be told.
#
# WHY A REBOOT IS THE LAST RUNG AND NOT THE FIRST
#
# Rebooting is the answer people reach for because it usually works, and it is
# a bad first move: it takes every healthy service down to fix the unhealthy
# ones, and it throws away the evidence of what went wrong. So the healer
# restarts what is actually broken, repeatedly, and only reboots when that has
# failed for long enough that something outside its reach is wrong.
#
# A reboot loop is worse than the fault it is trying to fix, so there is a
# minimum interval between reboots and it is recorded on disk, not in memory.

RECOVERY_HEAL_EVERY_SEC="${RECOVERY_HEAL_EVERY_SEC:-300}"
# How many consecutive degraded checks before a reboot is considered. At five
# minutes a check, six is half an hour of a service refusing to come back.
RECOVERY_REBOOT_AFTER="${RECOVERY_REBOOT_AFTER:-6}"
# Never reboot more often than this, however bad things look.
RECOVERY_REBOOT_COOLDOWN_SEC="${RECOVERY_REBOOT_COOLDOWN_SEC:-21600}"
RECOVERY_REBOOT_ENABLED="${RECOVERY_REBOOT_ENABLED:-true}"
# Seconds systemd may go without petting the hardware before it resets us.
RECOVERY_WATCHDOG_SEC="${RECOVERY_WATCHDOG_SEC:-60}"

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ── The hardware half ────────────────────────────────────────────────────────

# Find the watchdog driver this board actually has.
#
# Probed rather than assumed, the same rule as gotcha #19's corollary about
# binaries in images. An AMD board wants sp5100_tco and an Intel one iTCO_wdt,
# and loading the wrong one does nothing at all: no device appears, systemd
# happily runs with no watchdog, and the machine that was meant to recover
# itself still needs a person.
_recovery_watchdog_module() {
    local m
    for m in sp5100_tco iTCO_wdt wdat_wdt; do
        modinfo "$m" >/dev/null 2>&1 || continue
        modprobe "$m" 2>/dev/null || continue
        sleep 1
        if [[ -e /dev/watchdog ]]; then
            echo "$m"
            return 0
        fi
        modprobe -r "$m" 2>/dev/null || true
    done
    return 1
}

_recovery_install_watchdog() {
    local mod
    if ! mod="$(_recovery_watchdog_module)"; then
        log_warning "No hardware watchdog on this board, so a kernel hang still needs a person"
        log_warning "  The service healer below still covers services going down"
        return 0
    fi
    log_success "Hardware watchdog: ${mod} (/dev/watchdog)"

    # Load it at every boot. Without this the device is absent when systemd
    # starts, and systemd only opens the watchdog once, at startup: a module
    # loaded later is never used and nothing reports that.
    echo "$mod" > /etc/modules-load.d/corex-watchdog.conf
    chmod 644 /etc/modules-load.d/corex-watchdog.conf

    # A drop-in rather than editing system.conf, so an Ubuntu upgrade that
    # replaces that file does not silently take the watchdog away with it.
    mkdir -p /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/corex-watchdog.conf << WDEOF
# Managed by CoreX.
#
# RuntimeWatchdogSec makes systemd pet the board's watchdog. If systemd stops,
# because the kernel has locked up, the hardware resets the machine. That is
# the only thing that recovers a hang, because everything that could ask
# nicely has already stopped running.
#
# RebootWatchdogSec covers the other half: a reboot that hangs part way, which
# otherwise sits there looking exactly like the fault it was meant to clear.
[Manager]
RuntimeWatchdogSec=${RECOVERY_WATCHDOG_SEC}
RebootWatchdogSec=10min
WDEOF
    chmod 644 /etc/systemd/system.conf.d/corex-watchdog.conf
    systemctl daemon-reexec 2>/dev/null || true
}

# ── The software half ────────────────────────────────────────────────────────

_recovery_write_healer() {
    install_script /usr/local/bin/corex-heal.sh 750 << 'HEALEOF'
#!/bin/bash
# CoreX service healer. Restarts services that should be running and are not,
# and reboots only when that has failed for long enough to mean something else
# is wrong. Run from corex-heal.timer.
set -uo pipefail

CONF=/etc/corex/recovery.conf
STATE=/var/lib/corex/heal.state
LAST_REBOOT=/var/lib/corex/heal.last-reboot
LOG=/mnt/corex-data/blackbox.log
MANAGE=/home/serveradmin/corex-pro/corex-manage.sh

[[ -r "$CONF" ]] && . "$CONF"
RECOVERY_ENABLED="${RECOVERY_ENABLED:-true}"
RECOVERY_REBOOT_AFTER="${RECOVERY_REBOOT_AFTER:-6}"
RECOVERY_REBOOT_COOLDOWN_SEC="${RECOVERY_REBOOT_COOLDOWN_SEC:-21600}"
RECOVERY_REBOOT_ENABLED="${RECOVERY_REBOOT_ENABLED:-true}"
[[ "$RECOVERY_ENABLED" == "true" ]] || exit 0
[[ -x "$MANAGE" ]] || exit 0

say() {
    printf '%s heal: %s\n' "$(date -Is)" "$1" >> "$LOG" 2>/dev/null
    logger -t corex-heal "$1" 2>/dev/null || true
}

# Never fight the thermal guardian.
#
# A shed list with entries in it means the guardian took those services down on
# purpose and is walking them back at its own pace. Restarting them here would
# undo that decision and reheat a machine that is trying to cool, which is the
# mistake gotcha #25 measured: bringing everything back at once took a box from
# 79C to 96C in under two minutes.
if [[ -s /var/lib/corex/thermal-shed.list ]]; then
    exit 0
fi

# SLEEPING is Sablier cold mode and is correct, not a fault. MISSING means the
# service is not installed. Only UNHEALTHY is something to act on.
mapfile -t reported < <(
    "$MANAGE" status --plain 2>/dev/null | awk -F'\t' '$2 == "UNHEALTHY" {print $1}'
)

# Do not trust that verdict on its own before rebooting a working machine.
#
# This is not hypothetical. monitoring reported UNHEALTHY permanently because
# its cold-mode check accepted exit code 0 and Grafana, stopped on purpose,
# exits 137. A healer that believed it would have restarted a healthy service
# every five minutes and then rebooted the box every six hours, forever. The
# status verdict comes from a module; whether a container is stopped for a
# reason is a fact about the container.
#
# So a service only counts as broken when it has at least one container that
# stopped in a way nobody asked for. If every stopped container exited
# deliberately, the verdict is wrong and the box is fine.
broken=()
for svc in "${reported[@]:-}"; do
    [[ -n "$svc" ]] || continue
    real=no
    while read -r cid; do
        [[ -n "$cid" ]] || continue
        oom=$(docker inspect -f '{{.State.OOMKilled}}' "$cid" 2>/dev/null)
        code=$(docker inspect -f '{{.State.ExitCode}}' "$cid" 2>/dev/null)
        if [[ "$oom" == "true" ]]; then real=yes; break; fi
        case "$code" in 0|2|137|143) ;; *) real=yes; break ;; esac
    done < <(docker ps -aq --filter "label=com.docker.compose.project=${svc}" \
                          --filter "status=exited" 2>/dev/null)
    [[ "$real" == yes ]] && broken+=("$svc")
done

count=0
[[ -r "$STATE" ]] && read -r count < "$STATE" 2>/dev/null
count=${count:-0}

if (( ${#broken[@]} == 0 )); then
    [[ "$count" != "0" ]] && say "everything is healthy again after ${count} degraded check(s)"
    echo 0 > "$STATE"
    exit 0
fi

count=$(( count + 1 ))
echo "$count" > "$STATE"
say "degraded (${count}): ${broken[*]}"

# Try the cheap thing first, every time. A restart fixes a container that died;
# it is also harmless when it does not.
for svc in "${broken[@]}"; do
    timeout 120 "$MANAGE" restart "$svc" >/dev/null 2>&1 \
        && say "restarted ${svc}" \
        || say "could not restart ${svc}"
done

(( count < RECOVERY_REBOOT_AFTER )) && exit 0
[[ "$RECOVERY_REBOOT_ENABLED" == "true" ]] || { say "still degraded, reboot is disabled"; exit 0; }

# A reboot loop is worse than the fault it is meant to clear, so the last one
# is remembered on disk rather than in this process.
now=$(date +%s); last=0
[[ -r "$LAST_REBOOT" ]] && read -r last < "$LAST_REBOOT" 2>/dev/null
last=${last:-0}
if (( now - last < RECOVERY_REBOOT_COOLDOWN_SEC )); then
    say "still degraded, but a reboot $(( (now - last) / 60 ))min ago is too recent"
    exit 0
fi

say "rebooting: ${#broken[@]} service(s) have stayed down across ${count} checks"
echo "$now" > "$LAST_REBOOT"
echo 0 > "$STATE"
sync
# Delayed so the message above leaves the machine before the network does.
(sleep 5; systemctl reboot) &
HEALEOF
}

_recovery_write_units() {
    cat > /etc/systemd/system/corex-heal.service << HSEOF
[Unit]
Description=CoreX service healer
After=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/corex-heal.sh
HSEOF

    cat > /etc/systemd/system/corex-heal.timer << HTEOF
[Unit]
Description=Run the CoreX service healer every ${RECOVERY_HEAL_EVERY_SEC}s

[Timer]
# Late enough that a normal boot has finished bringing services up, or the
# healer meets a half-started box and calls it degraded.
OnBootSec=5min
OnUnitActiveSec=${RECOVERY_HEAL_EVERY_SEC}s
AccuracySec=30s

[Install]
WantedBy=timers.target
HTEOF

    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now corex-heal.timer 2>/dev/null || true
}

recovery_install() {
    log_info "Installing self-recovery..."
    mkdir -p /etc/corex /var/lib/corex

    if [[ ! -f /etc/corex/recovery.conf ]]; then
        cat > /etc/corex/recovery.conf << RCEOF
# CoreX self-recovery configuration.

# Restart services that should be running and are not.
RECOVERY_ENABLED=true

# Consecutive degraded checks before a reboot is considered. The healer runs
# every ${RECOVERY_HEAL_EVERY_SEC}s, so ${RECOVERY_REBOOT_AFTER} is about
# $(( RECOVERY_HEAL_EVERY_SEC * RECOVERY_REBOOT_AFTER / 60 )) minutes of a
# service refusing to come back.
RECOVERY_REBOOT_AFTER=${RECOVERY_REBOOT_AFTER}

# Set false to heal but never reboot. The box then stays degraded until
# someone looks, which is the right trade on hardware you cannot get to
# remotely and the wrong one on hardware you cannot get to physically.
RECOVERY_REBOOT_ENABLED=${RECOVERY_REBOOT_ENABLED}

# Minimum seconds between automatic reboots, whatever else is true. A reboot
# loop is worse than the fault it is trying to clear.
RECOVERY_REBOOT_COOLDOWN_SEC=${RECOVERY_REBOOT_COOLDOWN_SEC}
RCEOF
        chmod 644 /etc/corex/recovery.conf
        log_success "Wrote /etc/corex/recovery.conf"
    else
        log_info "Keeping existing /etc/corex/recovery.conf"
    fi

    _recovery_install_watchdog
    _recovery_write_healer
    _recovery_write_units
    log_success "Self-recovery active (heals services, reboots only as a last resort)"
}
