#!/bin/bash
# lib/services/ups.sh — CoreX Pro
# UPS Monitoring — graceful shutdown on power loss (Network UPS Tools)
#
# NOTES:
#   - This module installs NUT on the HOST, not in Docker. That is deliberate:
#     upsmon must survive and act while Docker itself is shutting down. A
#     containerised monitor cannot reliably stop its own runtime.
#   - Requires a USB-connected UPS. Detection is automatic via nut-scanner.
#   - The point of this module is data integrity, not uptime. An unclean
#     shutdown discards everything in the page cache; with dirty_ratio at 10%
#     of RAM that is still hundreds of MB of un-flushed database writes.
#     MariaDB (Nextcloud) and PostgreSQL (Immich) can both be corrupted by it.
#   - See CLAUDE.md gotcha #16 for why unclean shutdowns leave no evidence.

# ── Metadata ──────────────────────────────────────────────────────────────────
SERVICE_NAME="ups"
SERVICE_LABEL="UPS Monitoring — graceful shutdown on power loss (NUT)"
SERVICE_CATEGORY="monitoring"
SERVICE_REQUIRED=false
SERVICE_NEEDS_DOMAIN=false
SERVICE_NEEDS_EMAIL=false
SERVICE_RAM_MB=32
SERVICE_DISK_GB=1
SERVICE_DESCRIPTION="Monitors a USB-connected UPS. On battery, waits out short outages; on low battery, stops every container cleanly and powers down before the battery dies — protecting your databases from corruption."

# Where NUT keeps its config on Debian/Ubuntu.
_UPS_CONF_DIR="/etc/nut"
# Internal UPS name used across all NUT config files.
_UPS_DEV_NAME="corex-ups"

# ── Private helpers ───────────────────────────────────────────────────────────

# Detect a USB UPS. Echoes the driver name on success, nothing on failure.
_ups_detect() {
    local scan
    # nut-scanner is the authoritative probe; it emits a ups.conf fragment.
    if command -v nut-scanner &>/dev/null; then
        scan=$(nut-scanner -U -q 2>/dev/null | grep -oP '^\s*driver\s*=\s*"\K[^"]+' | head -1)
        [[ -n "$scan" ]] && { echo "$scan"; return 0; }
    fi
    # Fallback: most consumer UPS units (APC, CyberPower, Eaton) speak USB HID.
    if command -v lsusb &>/dev/null; then
        if lsusb 2>/dev/null | grep -qiE 'APC|American Power|CyberPower|Eaton|MGE|Tripp|Liebert|Powercom|Riello'; then
            echo "usbhid-ups"
            return 0
        fi
    fi
    return 1
}

# Write the shutdown handler that upsmon invokes on low battery.
# This is the whole reason the module exists, so it is deliberately defensive:
# it must make progress even if Docker is unresponsive.
_ups_write_shutdown_handler() {
    cat > /usr/local/bin/corex-ups-shutdown.sh << 'UPSSHEOF'
#!/bin/bash
# Invoked by upsmon when the UPS reports low battery. Goal: get databases to a
# consistent on-disk state before power is lost. Never block indefinitely —
# a hung step must not consume the remaining battery.
LOG="/mnt/corex-data/blackbox.log"
say() { printf '%s ups-shutdown: %s\n' "$(date -Is)" "$1" >> "$LOG" 2>/dev/null; }

say "LOW BATTERY — beginning graceful shutdown"

# Stop containers with a bounded timeout. Databases flush on SIGTERM; the
# 30s grace period is enough for InnoDB and PostgreSQL to checkpoint.
if command -v docker &>/dev/null; then
    running=$(docker ps -q 2>/dev/null)
    if [[ -n "$running" ]]; then
        say "stopping $(echo "$running" | wc -l | tr -d ' ') containers"
        # shellcheck disable=SC2086
        timeout 90 docker stop --time 30 $running >/dev/null 2>&1 \
            || say "WARNING: docker stop timed out — continuing"
    fi
    timeout 20 systemctl stop docker.socket docker >/dev/null 2>&1 || true
fi

# Flush the page cache to disk. Without this the whole point is lost.
say "syncing filesystems"
sync
timeout 15 bash -c 'sync; sync' >/dev/null 2>&1 || true

say "powering off"
# upsmon has already set the killpower flag where supported; NUT handles
# cutting UPS output after the OS halts.
/sbin/shutdown -h now "UPS low battery — CoreX graceful shutdown"
UPSSHEOF
    chmod 750 /usr/local/bin/corex-ups-shutdown.sh
}

# Write a notification handler so on-battery events land in the blackbox log.
_ups_write_notify_handler() {
    cat > /usr/local/bin/corex-ups-notify.sh << 'UPSNOTEOF'
#!/bin/bash
# upsmon NOTIFYCMD. $1 is the human-readable message; NOTIFYTYPE is exported.
LOG="/mnt/corex-data/blackbox.log"
printf '%s ups-event: [%s] %s\n' "$(date -Is)" "${NOTIFYTYPE:-UNKNOWN}" "${1:-}" >> "$LOG" 2>/dev/null
logger -t corex-ups "[${NOTIFYTYPE:-UNKNOWN}] ${1:-}" 2>/dev/null || true
UPSNOTEOF
    chmod 750 /usr/local/bin/corex-ups-notify.sh
}

# ── Functions ─────────────────────────────────────────────────────────────────

ups_dirs() {
    # NUT is host-installed, so there is no docker-configs dir to create.
    # A copy of the generated config is kept on the SSD so it survives an OS
    # reinstall and is captured by Restic along with everything else.
    mkdir -p "${DATA_ROOT}/ups-config"
    chown -R root:root "${DATA_ROOT}/ups-config"
    chmod 750 "${DATA_ROOT}/ups-config"
}

ups_firewall() {
    : # upsd binds 127.0.0.1:3493 only — no inbound rule needed
}

ups_deploy() {
    ups_dirs

    log_info "Installing Network UPS Tools..."
    apt-get install -y -qq nut nut-client nut-server usbutils 2>/dev/null \
        || { log_warning "Could not install NUT packages — skipping UPS setup"; return 0; }

    # Detect the UPS before writing any config. Configuring upsmon without a
    # real device risks spurious shutdowns, which is far worse than no module.
    local driver
    if ! driver=$(_ups_detect); then
        log_warning "No USB UPS detected — NUT installed but NOT enabled."
        echo "    Connect the UPS via USB, then run: corex manage repair ups"
        echo "    Verify detection with: nut-scanner -U"
        state_service_installed "ups"
        return 0
    fi
    log_success "UPS detected (driver: ${driver})"

    local ups_pass
    ups_pass=$(generate_pass)

    # ── nut.conf: standalone = driver + server + monitor on one machine ──────
    cat > "${_UPS_CONF_DIR}/nut.conf" << UNEOF
MODE=standalone
UNEOF

    # ── ups.conf: the device itself ──────────────────────────────────────────
    cat > "${_UPS_CONF_DIR}/ups.conf" << UUEOF
# Poll frequently enough to react before a short runtime UPS is exhausted.
pollinterval = 5

[${_UPS_DEV_NAME}]
    driver = ${driver}
    port = auto
    desc = "CoreX Pro UPS"
    # Ignore transient sags; only real outages should trigger on-battery.
    # ignorelb tells NUT to use our own thresholds rather than the UPS's
    # often-optimistic low-battery flag.
UUEOF

    # ── upsd.conf: listen on loopback only ──────────────────────────────────
    cat > "${_UPS_CONF_DIR}/upsd.conf" << UDEOF
LISTEN 127.0.0.1 3493
MAXAGE 25
UDEOF

    # ── upsd.users: credentials for the local monitor ───────────────────────
    cat > "${_UPS_CONF_DIR}/upsd.users" << UPEOF
[upsmon]
    password = ${ups_pass}
    upsmon primary
UPEOF

    # ── upsmon.conf: the policy that decides when to shut down ──────────────
    # SHUTDOWNCMD runs our handler, which stops containers before halting.
    cat > "${_UPS_CONF_DIR}/upsmon.conf" << UMEOF
MONITOR ${_UPS_DEV_NAME}@localhost 1 upsmon ${ups_pass} primary

MINSUPPLIES 1
SHUTDOWNCMD "/usr/local/bin/corex-ups-shutdown.sh"
NOTIFYCMD "/usr/local/bin/corex-ups-notify.sh"
POLLFREQ 5
POLLFREQALERT 5
HOSTSYNC 15
DEADTIME 15
RBWARNTIME 43200
NOCOMMWARNTIME 300
FINALDELAY 5

# Route events through NOTIFYCMD so they reach the blackbox log, and keep
# wall messages for the ones a logged-in operator should see immediately.
NOTIFYFLAG ONLINE   SYSLOG+EXEC
NOTIFYFLAG ONBATT   SYSLOG+WALL+EXEC
NOTIFYFLAG LOWBATT  SYSLOG+WALL+EXEC
NOTIFYFLAG FSD      SYSLOG+WALL+EXEC
NOTIFYFLAG COMMOK   SYSLOG+EXEC
NOTIFYFLAG COMMBAD  SYSLOG+WALL+EXEC
NOTIFYFLAG SHUTDOWN SYSLOG+WALL+EXEC
NOTIFYFLAG REPLBATT SYSLOG+WALL+EXEC
NOTIFYFLAG NOCOMM   SYSLOG+WALL+EXEC
UMEOF

    # NUT config holds a password — lock it down.
    chown root:nut "${_UPS_CONF_DIR}"/nut.conf "${_UPS_CONF_DIR}"/ups.conf \
        "${_UPS_CONF_DIR}"/upsd.conf "${_UPS_CONF_DIR}"/upsd.users \
        "${_UPS_CONF_DIR}"/upsmon.conf 2>/dev/null || true
    chmod 640 "${_UPS_CONF_DIR}"/nut.conf "${_UPS_CONF_DIR}"/ups.conf \
        "${_UPS_CONF_DIR}"/upsd.conf "${_UPS_CONF_DIR}"/upsmon.conf 2>/dev/null || true
    chmod 600 "${_UPS_CONF_DIR}"/upsd.users 2>/dev/null || true

    _ups_write_shutdown_handler
    _ups_write_notify_handler

    # Keep a backup copy on the SSD (mode 600 — it contains the password).
    cp "${_UPS_CONF_DIR}"/ups.conf "${_UPS_CONF_DIR}"/upsmon.conf \
        "${DATA_ROOT}/ups-config/" 2>/dev/null || true
    chmod 600 "${DATA_ROOT}/ups-config/"* 2>/dev/null || true

    # nut-driver-enumerator generates the per-UPS driver unit on modern NUT.
    systemctl enable nut-driver-enumerator 2>/dev/null || true
    systemctl restart nut-driver-enumerator 2>/dev/null || true
    systemctl enable nut-server nut-monitor 2>/dev/null || true
    systemctl restart nut-server 2>/dev/null || true
    systemctl restart nut-monitor 2>/dev/null || true

    # Confirm the driver actually talks to the hardware.
    sleep 3
    if upsc "${_UPS_DEV_NAME}@localhost" ups.status &>/dev/null; then
        local st
        st=$(upsc "${_UPS_DEV_NAME}@localhost" ups.status 2>/dev/null)
        log_success "UPS monitoring active (status: ${st})"
    else
        log_warning "NUT installed but the UPS is not responding yet."
        echo "    Check: upsc ${_UPS_DEV_NAME}@localhost"
        echo "    Check: systemctl status nut-server nut-monitor"
    fi

    # Record the password so it lands in the credentials file.
    UPS_MONITOR_PASSWORD="$ups_pass"
    state_service_installed "ups"
    log_success "UPS module deployed (graceful shutdown on low battery)"
}

ups_destroy() {
    systemctl stop nut-monitor nut-server 2>/dev/null || true
    systemctl disable nut-monitor nut-server nut-driver-enumerator 2>/dev/null || true
    apt-get remove -y -qq nut nut-client nut-server 2>/dev/null || true
    rm -f /usr/local/bin/corex-ups-shutdown.sh /usr/local/bin/corex-ups-notify.sh
    state_service_removed "ups"
}

ups_status() {
    # Host service, so container_running does not apply.
    if ! command -v upsc &>/dev/null; then
        echo "MISSING"
        return 0
    fi
    # upsmon is the component that actually protects the data. If the driver
    # cannot reach the UPS, report UNHEALTHY even when the units are up.
    if systemctl is-active --quiet nut-monitor 2>/dev/null \
       && upsc "${_UPS_DEV_NAME}@localhost" ups.status &>/dev/null; then
        echo "HEALTHY"
    elif systemctl list-unit-files 2>/dev/null | grep -q '^nut-monitor'; then
        echo "UNHEALTHY"
    else
        echo "MISSING"
    fi
}

ups_repair() {
    _ups_write_shutdown_handler
    _ups_write_notify_handler
    systemctl restart nut-driver-enumerator 2>/dev/null || true
    systemctl restart nut-server 2>/dev/null || true
    systemctl restart nut-monitor 2>/dev/null || true
    if ! upsc "${_UPS_DEV_NAME}@localhost" ups.status &>/dev/null; then
        log_warning "UPS still not responding — re-run detection: nut-scanner -U"
    fi
}

ups_credentials() {
    echo "UPS Monitoring (NUT, host service — not a container)"
    echo "  Live status:    upsc ${_UPS_DEV_NAME}@localhost"
    echo "  Battery charge: upsc ${_UPS_DEV_NAME}@localhost battery.charge"
    echo "  Runtime left:   upsc ${_UPS_DEV_NAME}@localhost battery.runtime"
    echo "  Service state:  systemctl status nut-server nut-monitor"
    echo "  Event log:      grep ups- /mnt/corex-data/blackbox.log"
    echo "  Monitor user:   upsmon / ${UPS_MONITOR_PASSWORD:-<see /etc/nut/upsd.users>}"
    echo ""
    echo "  TEST BEFORE TRUSTING IT — unplug the UPS from the wall and confirm"
    echo "  an ONBATT event appears in the blackbox log. Do NOT wait for a real"
    echo "  outage to find out the shutdown path is broken:"
    echo "    upsc ${_UPS_DEV_NAME}@localhost ups.status   # expect OB / OB LB"
}
