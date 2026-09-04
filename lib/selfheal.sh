#!/bin/bash
# lib/selfheal.sh — CoreX Pro
# Boot-time self-repair, so an unclean shutdown does not compound into a
# broken system that needs a human with a keyboard.
#
# WHY THIS EXISTS:
#   A mini server will lose power or thermal-trip eventually. When it does
#   mid-`apt`, dpkg is left with packages unpacked-but-not-configured — often
#   including systemd and libc-bin. Ubuntu does NOT self-repair this on boot;
#   it sits broken until someone runs `dpkg --configure -a` by hand, and every
#   subsequent unattended-upgrade run fails or makes it worse.
#
#   It also does not record that the shutdown was unclean, so the next person
#   to look has no idea what happened.
#
# See CLAUDE.md gotcha #16 and #17.

selfheal_install() {
    log_info "Installing boot-time self-repair..."

    mkdir -p /var/lib/corex

    cat > /usr/local/bin/corex-boot-repair.sh << 'BREOF'
#!/bin/bash
# Runs once per boot, before the apt timers. Detects an unclean shutdown and
# repairs anything it broke. Every step is bounded and logged.
set -uo pipefail

LOG=/mnt/corex-data/blackbox.log
MARK=/var/lib/corex/clean-shutdown
mkdir -p "$(dirname "$LOG")" /var/lib/corex 2>/dev/null

say() {
    printf '%s boot-repair: %s\n' "$(date -Is)" "$1" >> "$LOG" 2>/dev/null
    logger -t corex-boot-repair "$1" 2>/dev/null || true
}

# ── 1. Was the last shutdown clean? ─────────────────────────────────────────
# corex-boot-repair.service's ExecStop removes this marker on an orderly stop,
# so its presence at boot means we went down hard. This is far more reliable than
# grepping the journal, which is exactly what an unclean shutdown truncates.
UNCLEAN=false
if [[ -f "$MARK" ]]; then
    UNCLEAN=true
    say "PREVIOUS SHUTDOWN WAS UNCLEAN (power loss, thermal trip, or hang)"
    # Surface the last health sample before the crash — the actual diagnostic.
    last_sample=$(grep -E 'temp=' "$LOG" 2>/dev/null | tail -1)
    [[ -n "$last_sample" ]] && say "last sample before crash: ${last_sample}"
else
    say "previous shutdown was clean"
fi
# Re-arm the marker for this boot.
touch "$MARK" 2>/dev/null

# ── 2. Repair dpkg if a transaction was interrupted ─────────────────────────
# Checking first keeps the common case free: --configure -a on a healthy system
# is a no-op but still takes the lock, which we would rather not do on boot.
if command -v dpkg &>/dev/null; then
    broken=$(awk '/^Status: install ok unpacked/{c++} END{print c+0}' \
        /var/lib/dpkg/status 2>/dev/null)
    if (( broken > 0 )); then
        say "dpkg has ${broken} unpacked-but-unconfigured package(s) — repairing"
        # Wait for any apt process to release the lock rather than fighting it.
        if timeout 300 flock -w 240 /var/lib/dpkg/lock-frontend \
             dpkg --configure -a >/dev/null 2>&1; then
            still=$(awk '/^Status: install ok unpacked/{c++} END{print c+0}' \
                /var/lib/dpkg/status 2>/dev/null)
            if (( still > 0 )); then
                say "dpkg repair incomplete: ${still} still unconfigured — needs attention"
            else
                say "dpkg repair OK (${broken} package(s) configured)"
            fi
        else
            say "dpkg repair FAILED or timed out — run 'dpkg --configure -a' manually"
        fi
    fi
fi

# ── 3. Warn about a half-installed kernel ───────────────────────────────────
# A kernel whose control files are missing will not build modules and will not
# be repaired by --configure. It needs an explicit reinstall.
if command -v dpkg &>/dev/null; then
    bad_kernel=$(dpkg --audit 2>/dev/null \
        | grep -oE 'linux-(headers|image|modules)[a-z0-9.-]*' | sort -u | head -3)
    if [[ -n "$bad_kernel" ]]; then
        say "kernel package(s) need reinstall: $(echo "$bad_kernel" | paste -sd' ' -)"
    fi
fi

# ── 4. Check filesystem health flags on the data pool ───────────────────────
# An unclean shutdown can leave ext4 needing a check. Report it; do not fsck a
# mounted filesystem.
if [[ "$UNCLEAN" == "true" ]]; then
    for dev in $(findmnt -no SOURCE /mnt/corex-data 2>/dev/null); do
        state=$(tune2fs -l "$dev" 2>/dev/null | awk -F': *' '/Filesystem state/{print $2}')
        [[ -n "$state" && "$state" != "clean" ]] \
            && say "WARNING: ${dev} filesystem state is '${state}' — schedule fsck"
    done
fi

# ── 5. Bring the services back after a thermal shutdown ─────────────────────
#
# The thermal guardian stops every container and powers the machine off when
# the CPU reaches TjMax, which is the right call and used to be a one-way trip.
# `docker stop` on a container whose restart policy is unless-stopped means
# exactly that, so Docker does not bring it back at the next boot: the machine
# came up with 23 containers stopped, 0 running, and nothing recording why.
#
# The guardian now writes what was running before it stops anything. This is
# where that is read, because at boot there is no load and starting the
# services is the right default. Three at a time with a temperature hold
# between, because restoring a whole list at once is what re-triggers the
# shed (gotcha #25).
EMERG_LIST=/var/lib/corex/thermal-emergency.list
if [[ -s "$EMERG_LIST" ]]; then
    n=$(grep -c . "$EMERG_LIST" 2>/dev/null || echo 0)
    say "a thermal shutdown left ${n} container(s) stopped, bringing them back"

    boot_temp() {
        local t=""
        if command -v sensors >/dev/null 2>&1; then
            t=$(sensors -u 2>/dev/null | awk '/^(Tctl|Tdie|Package id 0):/{getline; print $2; exit}')
        fi
        if [[ -z "$t" ]]; then
            local hottest=0 z v
            for z in /sys/class/thermal/thermal_zone*/temp; do
                [[ -r "$z" ]] || continue
                v=$(( $(cat "$z" 2>/dev/null || echo 0) / 1000 ))
                (( v > hottest )) && hottest=$v
            done
            t=$hottest
        fi
        echo "${t%%.*}"
    }

    # An operator's deliberate disable outranks this. Same source the
    # guardian's own restore uses.
    disabled=""
    if command -v jq >/dev/null 2>&1; then
        disabled=$(jq -r '[ .services | to_entries[]
                 | (if (.value.enabled == false) then .key else empty end),
                   ((.value.disabled_components // [])[]) ] | unique[]' \
            /etc/corex/state.json 2>/dev/null || true)
    fi

    started=0; held=0
    while read -r c; do
        [[ -z "$c" ]] && continue
        if [[ -n "$disabled" ]] && printf '%s\n' "$disabled" | grep -qxF "$c"; then
            say "skipping ${c}: disabled by the operator"
            continue
        fi
        t=$(boot_temp)
        # Give up holding rather than never finishing. Ten minutes of waiting
        # means the machine cannot host the workload at all, which is a
        # cooling verdict and not something to solve by waiting longer.
        waited=0
        while [[ -n "$t" && "$t" -ge 88 && $waited -lt 600 ]]; do
            sleep 20; waited=$((waited+20)); held=1
            t=$(boot_temp)
        done
        timeout 90 docker start "$c" >/dev/null 2>&1 && started=$((started+1)) \
            || say "could not start ${c}"
        (( started % 3 == 0 )) && sleep 10
    done < "$EMERG_LIST"

    rm -f "$EMERG_LIST"
    say "restarted ${started} of ${n} container(s) after the thermal shutdown"
    (( held == 1 )) && say "had to wait for the CPU to come down while doing it"
fi
BREOF
    chmod 750 /usr/local/bin/corex-boot-repair.sh

    # Removes the marker on an orderly shutdown. If we never get here, the
    # marker survives and the next boot knows the shutdown was unclean.
    cat > /usr/local/bin/corex-mark-clean.sh << 'MCEOF'
#!/bin/bash
rm -f /var/lib/corex/clean-shutdown 2>/dev/null
printf '%s clean-shutdown: marker cleared, going down orderly\n' "$(date -Is)" \
    >> /mnt/corex-data/blackbox.log 2>/dev/null
exit 0
MCEOF
    chmod 750 /usr/local/bin/corex-mark-clean.sh

    cat > /etc/systemd/system/corex-boot-repair.service << BRSEOF
[Unit]
Description=CoreX boot-time self-repair (dpkg + unclean shutdown detection)
# Must run before anything tries to take the dpkg lock.
Before=apt-daily.service apt-daily-upgrade.service unattended-upgrades.service
After=local-fs.target
Wants=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/corex-boot-repair.sh
# Clearing the marker on stop is what makes unclean detection work.
ExecStop=/usr/local/bin/corex-mark-clean.sh
TimeoutStartSec=420

[Install]
WantedBy=multi-user.target
BRSEOF

    systemctl daemon-reload 2>/dev/null || true
    systemctl enable corex-boot-repair.service 2>/dev/null || true
    log_success "Boot self-repair enabled (repairs dpkg, detects unclean shutdown)"
}

# ── Blackbox health recorder ──────────────────────────────────────────────────
# Moved here from phase2_security. It is a forensics feature, not a hardening
# one, and burying it inside security hardening meant it could not be installed
# or repaired without also resetting UFW and rewriting sshd_config.
#
# An unclean shutdown leaves nothing in the journal because journald never
# flushes. This appends a health sample to a plain file on the SSD every 20s,
# so the last line before a crash tells you the temperature, load and memory
# state at the moment of death — which distinguishes a thermal trip from a PSU
# failure from an OOM.
selfheal_install_blackbox() {
    # ── Crash forensics recorder ─────────────────────────────────────────────
    # An unclean shutdown (power loss, thermal trip, hard hang) leaves nothing
    # in the journal, because journald never gets to flush. This samples health
    # to a plain file on the SSD every 20s, so the last line before a crash
    # tells you the temperature, load and memory state at that moment.
    log_info "Installing crash forensics recorder..."
    cat > /usr/local/bin/corex-blackbox.sh << 'BBEOF'
#!/bin/bash
# Appends a health sample to the blackbox log. Survives unclean shutdown.
LOG="/mnt/corex-data/blackbox.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null
temp=""
if command -v sensors &>/dev/null; then
    temp=$(sensors 2>/dev/null | grep -oE 'Tctl:.*?\+[0-9.]+' | grep -oE '[0-9.]+' | head -1)
fi
if [[ -z "$temp" ]]; then
    for z in /sys/class/thermal/thermal_zone*/temp; do
        [[ -r "$z" ]] && temp=$(( $(cat "$z" 2>/dev/null) / 1000 )) && break
    done
fi
read -r l1 l5 l15 _ < /proc/loadavg
mem=$(free -m | awk '/^Mem:/{printf "%d/%dMB", $3, $2}')
swap=$(free -m | awk '/^Swap:/{printf "%d/%dMB", $3, $2}')
throttle=$(cat /sys/devices/system/cpu/cpu0/thermal_throttle/core_throttle_count 2>/dev/null || echo "-")
printf '%s temp=%sC load=%s/%s/%s mem=%s swap=%s throttle=%s containers=%s\n' \
    "$(date -Is)" "${temp:-?}" "$l1" "$l5" "$l15" "$mem" "$swap" "$throttle" \
    "$(docker ps -q 2>/dev/null | wc -l)" >> "$LOG"
# Keep the file bounded (~last 3 days at 20s cadence).
if [[ $(stat -c%s "$LOG" 2>/dev/null || echo 0) -gt 20000000 ]]; then
    tail -n 100000 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
fi
BBEOF
    chmod +x /usr/local/bin/corex-blackbox.sh

    cat > /etc/systemd/system/corex-blackbox.service << BBSEOF
[Unit]
Description=CoreX blackbox health recorder
After=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/corex-blackbox.sh
BBSEOF

    cat > /etc/systemd/system/corex-blackbox.timer << BBTEOF
[Unit]
Description=Sample CoreX health every 20s for post-crash forensics

[Timer]
OnBootSec=30s
OnUnitActiveSec=20s
AccuracySec=1s
Persistent=false

[Install]
WantedBy=timers.target
BBTEOF
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now corex-blackbox.timer 2>/dev/null || true

    # Detect sensors non-interactively so temperatures are actually available.
    command -v sensors-detect &>/dev/null && yes | sensors-detect --auto &>/dev/null || true
    log_success "Blackbox recorder active (/mnt/corex-data/blackbox.log)"
}

# ── Delay Docker start after boot ─────────────────────────────────────────────
# Honest description of what this does: it does NOT stagger individual
# containers — they all still start together, just later. What it buys is that
# they no longer start while the kernel, the SSD mount, journald and the apt
# timers are all competing for the same CPU. On a thermally-marginal box that
# separation alone measurably lowers the peak.
#
# Real per-container staggering would require dropping restart: unless-stopped
# across every service and sequencing them from systemd, which trades away the
# self-healing restart behaviour. The thermal guardian handles the residual
# spike reactively instead: it begins sampling at 45s, while the boot surge is
# still in progress, and sheds load if the surge pushes temperature too high.
selfheal_delay_docker_start() {
    log_info "Delaying Docker start to flatten the boot load spike..."

    mkdir -p /etc/systemd/system/docker.service.d
    cat > /etc/systemd/system/docker.service.d/99-corex-stagger.conf << SGEOF
[Service]
# Let the kernel, SSD mount and journald settle before ~38 containers start.
ExecStartPre=/bin/sleep 15
SGEOF

    systemctl daemon-reload 2>/dev/null || true
    log_success "Docker start delayed 15s (flattens boot load spike)"
}
