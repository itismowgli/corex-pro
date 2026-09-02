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
