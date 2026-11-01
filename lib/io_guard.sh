#!/bin/bash
# lib/io_guard.sh — CoreX Pro
# Reboot the machine when its system disk stops answering.
#
# The daemon is agent/corex-io-guard.py; its header explains the failure it
# exists for (gotcha #87). This file installs it and edits its settings.
#
# Settings live in /etc/corex/io-guard.conf and the daemon rereads them every
# 30 seconds, so a change needs no restart. Status is written to
# /run/corex/io-guard.json, which is memory, every five seconds.

IO_GUARD_CONF="${IO_GUARD_CONF:-/etc/corex/io-guard.conf}"
IO_GUARD_STATUS="${IO_GUARD_STATUS:-/run/corex/io-guard.json}"
IO_GUARD_BIN="/usr/local/lib/corex/corex-io-guard.py"
IO_GUARD_UNIT="/etc/systemd/system/corex-io-guard.service"

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

_io_guard_write_default_conf() {
    cat > "$IO_GUARD_CONF" << 'IGEOF'
# CoreX I/O guard. Reread every 30 seconds, no restart needed.
# Change with: corex manage io-guard set <key> <value>, or from the dashboard.

# Watch the system disk at all.
IO_GUARD_ENABLED=true

# reboot: restart the machine when the disk is stuck.
# alert:  send a Telegram message and leave it alone.
IO_GUARD_ACTION=reboot

# Seconds requests may sit in flight with none completing before the disk
# counts as stuck. 30 to 3600. A busy disk completes something every second;
# two minutes of nothing is a request that is never coming back.
IO_GUARD_STALL_SEC=120

# Never act this soon after boot, 120 to 7200 seconds. This is what stops one
# bad disk from turning into a reboot loop.
IO_GUARD_BOOT_GRACE_SEC=600

# auto: every device on the physical disk holding /, volumes included.
# Or a list of names from /sys/block, for example "dm-0 nvme0n1".
IO_GUARD_DEVICES=auto
IGEOF
    chmod 644 "$IO_GUARD_CONF"
}

io_guard_install() {
    local src
    src="$(dirname "${BASH_SOURCE[0]}")/../agent/corex-io-guard.py"
    [[ -f "$src" ]] || { log_warning "I/O guard source not found at ${src}"; return 1; }
    command -v python3 >/dev/null 2>&1 || { log_warning "I/O guard needs python3"; return 1; }

    mkdir -p /etc/corex /usr/local/lib/corex /var/lib/corex
    if [[ -f "$IO_GUARD_CONF" ]]; then
        log_info "Keeping existing ${IO_GUARD_CONF}"
    else
        _io_guard_write_default_conf
        log_success "Wrote ${IO_GUARD_CONF}"
    fi
    install -m 0755 "$src" "$IO_GUARD_BIN"
    # corex_common supplies the Telegram credentials; the agent installs it,
    # and the guard runs without notifications when it is absent.
    [[ -f /usr/local/lib/corex/corex_common.py ]] || \
        install -m 0644 "$(dirname "$src")/corex_common.py" /usr/local/lib/corex/corex_common.py

    cat > "$IO_GUARD_UNIT" << IGUEOF
[Unit]
Description=CoreX I/O guard (reboots when the system disk stops answering)
After=local-fs.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${IO_GUARD_BIN}
Restart=always
RestartSec=5
# The guard locks itself into memory so nothing it needs is ever read back
# from the disk it is watching.
LimitMEMLOCK=infinity
OOMScoreAdjust=-900
Nice=-5

[Install]
WantedBy=multi-user.target
IGUEOF
    systemctl daemon-reload
    systemctl enable corex-io-guard.service >/dev/null 2>&1
    # restart, not enable --now: --now leaves a running copy alone, so new
    # code would install and the old code would carry on (gotcha #22).
    systemctl restart corex-io-guard.service \
        && log_success "I/O guard running: $(io_guard_summary)" \
        || log_warning "I/O guard did not start: journalctl -u corex-io-guard"
}

# One line for logs and the end of setup.
io_guard_summary() {
    local enabled action stall
    enabled=$(_io_guard_get IO_GUARD_ENABLED)
    action=$(_io_guard_get IO_GUARD_ACTION)
    stall=$(_io_guard_get IO_GUARD_STALL_SEC)
    if [[ "$enabled" != "true" ]]; then
        echo "switched off"
    else
        echo "${action} after ${stall}s of a stuck system disk"
    fi
}

_io_guard_get() {
    [[ -f "$IO_GUARD_CONF" ]] || return 0
    sed -n "s/^${1}=\"\{0,1\}\([^\"#]*\)\"\{0,1\}.*/\1/p" "$IO_GUARD_CONF" | tail -1 | xargs
}

# Validate one setting and write it. The daemon also clamps what it reads, so
# a hand edit cannot set a limit that reboots on every slow write either.
io_guard_set() {
    local key="${1:-}" val="${2:-}"
    case "$key" in
        enabled|IO_GUARD_ENABLED)
            key=IO_GUARD_ENABLED
            case "$val" in
                true|on|yes|1) val=true ;;
                false|off|no|0) val=false ;;
                *) log_warning "enabled is true or false"; return 1 ;;
            esac ;;
        action|IO_GUARD_ACTION)
            key=IO_GUARD_ACTION
            [[ "$val" == "reboot" || "$val" == "alert" ]] \
                || { log_warning "action is reboot or alert"; return 1; } ;;
        stall|stall_sec|IO_GUARD_STALL_SEC)
            key=IO_GUARD_STALL_SEC
            [[ "$val" =~ ^[0-9]+$ ]] && (( val >= 30 && val <= 3600 )) \
                || { log_warning "stall is 30 to 3600 seconds"; return 1; } ;;
        grace|boot_grace_sec|IO_GUARD_BOOT_GRACE_SEC)
            key=IO_GUARD_BOOT_GRACE_SEC
            [[ "$val" =~ ^[0-9]+$ ]] && (( val >= 120 && val <= 7200 )) \
                || { log_warning "grace is 120 to 7200 seconds"; return 1; } ;;
        devices|IO_GUARD_DEVICES)
            key=IO_GUARD_DEVICES
            [[ "$val" == "auto" || "$val" =~ ^[a-z][a-z0-9-]{0,31}( [a-z][a-z0-9-]{0,31})*$ ]] \
                || { log_warning "devices is auto or names from /sys/block, space separated"; return 1; }
            val="\"${val}\"" ;;
        *)
            log_warning "Unknown setting '${key}'. Use enabled, action, stall, grace or devices"
            return 1 ;;
    esac
    [[ -f "$IO_GUARD_CONF" ]] || _io_guard_write_default_conf
    local tmp
    tmp=$(mktemp "${IO_GUARD_CONF}.XXXXXX")
    if grep -q "^${key}=" "$IO_GUARD_CONF"; then
        sed "s|^${key}=.*|${key}=${val}|" "$IO_GUARD_CONF" > "$tmp"
    else
        cat "$IO_GUARD_CONF" > "$tmp"
        echo "${key}=${val}" >> "$tmp"
    fi
    mv "$tmp" "$IO_GUARD_CONF"
    chmod 644 "$IO_GUARD_CONF"
    systemctl kill -s HUP corex-io-guard.service >/dev/null 2>&1 || true
    log_success "${key}=${val}"
}

io_guard_status() {
    if ! systemctl is-active --quiet corex-io-guard.service 2>/dev/null; then
        log_warning "I/O guard is not running. Install it: sudo corex manage io-guard setup"
    fi
    log_info "Setting: $(io_guard_summary)"
    if [[ -f "$IO_GUARD_STATUS" ]]; then
        python3 - "$IO_GUARD_STATUS" << 'IGPEOF'
import json, sys
s = json.load(open(sys.argv[1]))
print("  State:   %s%s" % (s["state"], " (boot grace, will not act yet)" if s.get("in_boot_grace") else ""))
print("  Memory locked: %s" % ("yes" if s.get("memory_locked") else "NO"))
for dev, d in sorted(s.get("devices", {}).items()):
    print("  %-10s in flight %-4s stalled %ss" % (dev, d.get("in_flight"), d.get("stalled_sec")))
IGPEOF
    fi
    local log
    for log in /mnt/corex-data/io-guard.log /var/lib/corex/io-guard.log; do
        if [[ -s "$log" ]]; then
            log_info "Recent events (${log}):"
            tail -5 "$log" | sed 's/^/  /'
            break
        fi
    done
}
