#!/bin/bash
#
# Wake-on-LAN, and nothing else.
#
# The dashboard can switch this machine off. It cannot switch it on, because it
# runs on the machine and the Cloudflare tunnel goes down with it. No amount of
# CoreX code changes that: the packet has to come from somewhere else, or the
# power has to be cut and restored. So this module does the one part that
# belongs on the box, arms the NIC so that something else on the network can
# wake it, and the dashboard and this command say plainly what the rest of the
# answer is.
#
# The setting does not survive a reboot on its own. ethtool writes it to the
# driver, not to anything persistent, so it needs a unit that reapplies it
# after the interface exists.
#
# Two things outside this file have to be right as well, and neither can be
# checked from here. The BIOS has to permit wake from S5, which is off by
# default on most boards, and the sender has to be on the same layer 2 network,
# so a magic packet from outside the house does not arrive.

set -u

POWER_UNIT="/etc/systemd/system/corex-wol.service"

# _power_ifaces prints the physical interfaces, skipping the ones Docker and
# the tunnel create. A magic packet arrives on a real NIC or not at all.
_power_ifaces() {
    local iface
    for iface in /sys/class/net/*; do
        iface="$(basename "$iface")"
        case "$iface" in
            lo|docker*|br-*|veth*|tun*|wg*|cni*) continue ;;
        esac
        # A virtual interface has no device link. Wireless is listed, since
        # some cards do support it, but it is rarely usable for this.
        [[ -e "/sys/class/net/${iface}/device" ]] || continue
        echo "$iface"
    done
}

# _power_wol_supported prints the interfaces whose driver reports the magic
# packet mode. Needs root: ethtool returns nothing useful without it.
_power_wol_supported() {
    local iface supports
    while read -r iface; do
        [[ -n "$iface" ]] || continue
        supports="$(ethtool "$iface" 2>/dev/null | sed -n 's/^[[:space:]]*Supports Wake-on:[[:space:]]*//p')"
        [[ "$supports" == *g* ]] && echo "$iface"
    done < <(_power_ifaces)
}

_power_wol_state() {
    local iface="$1"
    ethtool "$iface" 2>/dev/null | sed -n 's/^[[:space:]]*Wake-on:[[:space:]]*//p'
}

_power_write_unit() {
    local ifaces="$1"
    local exec_lines="" iface
    for iface in $ifaces; do
        exec_lines+="ExecStart=/usr/sbin/ethtool -s ${iface} wol g"$'\n'
    done

    cat > "$POWER_UNIT" << WOLEOF
[Unit]
Description=CoreX Wake-on-LAN (arm the NIC so the network can start this machine)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
# ethtool exits non-zero on an interface that has gone away, and a unit that
# fails for that reason would take the others with it.
SuccessExitStatus=0 1
${exec_lines}
[Install]
WantedBy=multi-user.target
WOLEOF

    systemctl daemon-reload 2>/dev/null || true
}

# power_wol_enable arms every interface that can do it, now and at every boot.
power_wol_enable() {
    command -v ethtool >/dev/null 2>&1 || {
        log_info "Installing ethtool"
        DEBIAN_FRONTEND=noninteractive apt-get install -y ethtool >/dev/null 2>&1 \
            || log_warning "Could not install ethtool"
    }

    local ifaces
    ifaces="$(_power_wol_supported | tr '\n' ' ')"
    if [[ -z "${ifaces// /}" ]]; then
        log_warning "No interface on this machine reports supporting a magic packet"
        log_info "So the network cannot start it. A smart plug is the way back on."
        return 1
    fi

    local iface
    for iface in $ifaces; do
        ethtool -s "$iface" wol g 2>/dev/null \
            && log_success "${iface} will wake on a magic packet" \
            || log_warning "${iface} refused the setting"
    done

    _power_write_unit "$ifaces"
    # Restart, not enable --now: an already-running oneshot is left alone by
    # --now, so a unit rewritten with a new interface list would install and
    # never apply (gotcha #22 in a different costume).
    systemctl enable corex-wol.service >/dev/null 2>&1 || true
    systemctl restart corex-wol.service >/dev/null 2>&1 || true
    log_success "Armed at every boot by corex-wol.service"
    return 0
}

power_wol_disable() {
    local iface
    while read -r iface; do
        [[ -n "$iface" ]] || continue
        ethtool -s "$iface" wol d 2>/dev/null \
            && log_success "${iface} will no longer wake on a magic packet"
    done < <(_power_wol_supported)

    systemctl disable --now corex-wol.service >/dev/null 2>&1 || true
    rm -f "$POWER_UNIT"
    systemctl daemon-reload 2>/dev/null || true
}

power_show() {
    echo ""
    echo -e "${BOLD}Power${NC}"
    echo ""

    if ! command -v ethtool >/dev/null 2>&1; then
        log_warning "ethtool is not installed, so wake-on-LAN cannot be read or set"
        echo "  Install it with: corex manage power wol on"
        echo ""
        return 0
    fi

    local iface supports current found=0
    while read -r iface; do
        [[ -n "$iface" ]] || continue
        supports="$(ethtool "$iface" 2>/dev/null | sed -n 's/^[[:space:]]*Supports Wake-on:[[:space:]]*//p')"
        current="$(_power_wol_state "$iface")"
        [[ -n "$supports" ]] || continue
        found=1
        if [[ "$supports" != *g* ]]; then
            echo -e "  ${iface}: ${YELLOW}cannot wake on a magic packet${NC} (supports ${supports})"
        elif [[ "$current" == *g* ]]; then
            echo -e "  ${iface}: ${GREEN}armed${NC} (Wake-on: ${current})"
        else
            echo -e "  ${iface}: ${YELLOW}supported but off${NC} (Wake-on: ${current})"
        fi
    done < <(_power_ifaces)
    [[ $found -eq 1 ]] || echo "  No physical interface reported a wake-on setting."

    echo ""
    if systemctl is-enabled corex-wol.service >/dev/null 2>&1; then
        echo -e "  Reapplied at boot: ${GREEN}yes${NC} (corex-wol.service)"
    else
        echo -e "  Reapplied at boot: ${YELLOW}no${NC}, so a reboot clears it"
        echo "  Turn it on with: corex manage power wol on"
    fi

    cat << 'POWEREOF'

  Switching off is in the dashboard, on the System tab, behind a password,
  a code or a passkey. Switching on is not, and cannot be: the dashboard
  runs on this machine and the tunnel is down while it is off.

  What actually works, in order:

    1. A smart plug, with "restore on AC power loss" set in the BIOS. Cut
       the power, restore it, the box boots. This is the only one that also
       recovers a hung machine, which matters on hardware that thermal trips.
    2. Wake-on-LAN from a phone or a router on the same network. Free once
       the NIC is armed, useless from outside the house.
    3. rtcwake, for a fixed schedule such as off overnight and on at seven.
       No second device at all, but it cannot answer an unplanned request.

  Wake from S5 also has to be enabled in the BIOS, which this cannot check.
POWEREOF
    echo ""
}
