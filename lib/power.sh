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
POWER_CPU_UNIT="/etc/systemd/system/corex-cpu.service"
POWER_CONF="/etc/corex/power.conf"

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


# ── CPU clock ceiling ─────────────────────────────────────────────────────────
#
# The one software lever that measurably moves this class of hardware away from
# its thermal limit, and it was found by asking why an idle box was at 86C.
#
# amd-pstate-epp with the powersave governor still boosts to the top of the
# range if the energy performance preference is set to "performance", which is
# what Ubuntu leaves it at. Measured on a Ryzen 9 5900HX mini server with 21
# mostly idle containers, eight samples a minute apart each time:
#
#   EPP=performance, no cap        mean 86.3C   cores at 4.1 to 4.2 GHz
#   EPP=balance_power, no cap      mean 83.0C   cores at 3.2 to 4.0 GHz
#   EPP=balance_power, 3.0 GHz cap mean 76.8C   cores at 2.4 to 2.9 GHz
#
# Ten degrees, for a ceiling below a base clock the chassis cannot sustain
# anyway. It is close to free in practice: the machine was already trying to
# boost and then thermally shedding, so the peak it gave up was one it never
# actually held.
#
# It matters beyond comfort. THERMAL_WARN_C is 80, so at 86C the guardian sat
# permanently in its warn band, the shed list could never drain, and the
# maintenance governor would have paused forever. A number under the warn
# threshold is what makes both of those work at all.
#
# Off by default. This is hardware-specific tuning and CoreX does not guess at
# it: an empty POWER_CPU_MAX_MHZ leaves the CPU exactly as the kernel set it.

_power_cpu_read() {
    POWER_CPU_MAX_MHZ=""; POWER_CPU_EPP=""
    [[ -r "$POWER_CONF" ]] || return 0
    # shellcheck source=/dev/null
    . "$POWER_CONF" 2>/dev/null || true
}

_power_cpu_write_conf() {
    mkdir -p /etc/corex
    cat > "$POWER_CONF" << PCEOF
# CoreX CPU clock settings, applied at boot by corex-cpu.service.
#
# Both are empty by default, which means CoreX changes nothing. See
# lib/power.sh for the measurements behind the numbers.
#
# POWER_CPU_MAX_MHZ  a ceiling on scaling_max_freq, in MHz. On a chassis that
#                    cannot sustain boost this costs a peak it never held and
#                    buys real thermal headroom.
# POWER_CPU_EPP      energy performance preference: performance,
#                    balance_performance, balance_power, power or default.
#                    amd-pstate-epp boosts to the top of the range on
#                    "performance" even under the powersave governor.
POWER_CPU_MAX_MHZ="${POWER_CPU_MAX_MHZ:-}"
POWER_CPU_EPP="${POWER_CPU_EPP:-}"
PCEOF
    chmod 644 "$POWER_CONF"
}

_power_cpu_write_unit() {
    cat > "$POWER_CPU_UNIT" << CPUEOF
[Unit]
Description=CoreX CPU clock ceiling and energy preference
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/corex-cpu.sh

[Install]
WantedBy=multi-user.target
CPUEOF

    install_script /usr/local/bin/corex-cpu.sh 750 << 'CPUSEOF'
#!/bin/bash
# CoreX CPU clock ceiling. Installed by lib/power.sh; settings live in
# /etc/corex/power.conf. Both empty means do nothing at all.
set -uo pipefail
CONF=/etc/corex/power.conf
[[ -r "$CONF" ]] || exit 0
# shellcheck disable=SC1090
source "$CONF"
: "${POWER_CPU_MAX_MHZ:=}"
: "${POWER_CPU_EPP:=}"

log() { printf '%s cpu: %s
' "$(date -Is)" "$1" >> /mnt/corex-data/blackbox.log 2>/dev/null; }

if [[ -n "$POWER_CPU_EPP" ]]; then
    n=0
    for f in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
        [[ -w "$f" ]] || continue
        echo "$POWER_CPU_EPP" > "$f" 2>/dev/null && n=$((n+1))
    done
    log "energy preference ${POWER_CPU_EPP} on ${n} cpu(s)"
fi

if [[ -n "$POWER_CPU_MAX_MHZ" ]]; then
    khz=$(( POWER_CPU_MAX_MHZ * 1000 ))
    n=0
    for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq; do
        [[ -w "$f" ]] || continue
        # Never below the driver's floor, or the write is rejected and the
        # core is left at whatever it had.
        min=$(cat "${f%scaling_max_freq}cpuinfo_min_freq" 2>/dev/null || echo 0)
        (( khz < min )) && khz=$min
        echo "$khz" > "$f" 2>/dev/null && n=$((n+1))
    done
    log "clock ceiling ${POWER_CPU_MAX_MHZ} MHz on ${n} cpu(s)"
fi
exit 0
CPUSEOF

    systemctl daemon-reload 2>/dev/null || true
}

# power_cpu_set applies a ceiling and an energy preference now, and at boot.
power_cpu_set() {
    local mhz="${1:-}" epp="${2:-balance_power}"
    if [[ -n "$mhz" && ! "$mhz" =~ ^[0-9]+$ ]]; then
        log_error "The ceiling must be a whole number of MHz, for example 3000"
    fi
    if [[ ! -d /sys/devices/system/cpu/cpu0/cpufreq ]]; then
        log_warning "This kernel exposes no cpufreq controls, so there is nothing to set"
        return 1
    fi
    POWER_CPU_MAX_MHZ="$mhz"
    POWER_CPU_EPP="$epp"
    _power_cpu_write_conf
    _power_cpu_write_unit
    systemctl enable corex-cpu.service >/dev/null 2>&1 || true
    # restart, not enable --now: an already-running oneshot is left alone by
    # --now, so a changed ceiling would be written to the config and never
    # applied (gotcha #22 in a different costume).
    systemctl restart corex-cpu.service >/dev/null 2>&1 || true
    if [[ -n "$mhz" ]]; then
        log_success "CPU ceiling ${mhz} MHz, energy preference ${epp}, reapplied at every boot"
    else
        log_success "Energy preference ${epp}, no ceiling, reapplied at every boot"
    fi
}

power_cpu_reset() {
    POWER_CPU_MAX_MHZ=""; POWER_CPU_EPP=""
    _power_cpu_write_conf
    systemctl disable --now corex-cpu.service >/dev/null 2>&1 || true
    rm -f "$POWER_CPU_UNIT" /usr/local/bin/corex-cpu.sh
    systemctl daemon-reload 2>/dev/null || true
    # Put the hardware back where the kernel had it, rather than leaving it
    # wherever the last ceiling left it until a reboot.
    local f max
    for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq; do
        [[ -w "$f" ]] || continue
        max=$(cat "${f%scaling_max_freq}cpuinfo_max_freq" 2>/dev/null) || continue
        echo "$max" > "$f" 2>/dev/null || true
    done
    log_success "CPU ceiling removed; the energy preference is whatever the kernel sets at boot"
}

_power_cpu_show() {
    local d=/sys/devices/system/cpu/cpu0/cpufreq
    [[ -d "$d" ]] || { echo "  CPU: this kernel exposes no cpufreq controls"; return 0; }
    _power_cpu_read
    local gov drv epp cur cap hw
    gov=$(cat "$d/scaling_governor" 2>/dev/null || echo "?")
    drv=$(cat "$d/scaling_driver" 2>/dev/null || echo "?")
    epp=$(cat "$d/energy_performance_preference" 2>/dev/null || echo "n/a")
    cap=$(awk '{printf "%d", $1/1000}' "$d/scaling_max_freq" 2>/dev/null || echo 0)
    hw=$(awk '{printf "%d", $1/1000}' "$d/cpuinfo_max_freq" 2>/dev/null || echo 0)
    cur=$(for c in /sys/devices/system/cpu/cpu[0-3]/cpufreq/scaling_cur_freq; do
            [[ -r "$c" ]] && awk '{printf "%d ", $1/1000}' "$c"; done)

    echo "  CPU: governor ${gov}, driver ${drv}, energy preference ${epp}"
    if (( cap > 0 && hw > 0 && cap < hw )); then
        echo -e "       ceiling ${GREEN}${cap} MHz${NC} of ${hw} MHz available"
    else
        echo "       ceiling ${cap} MHz, which is the hardware maximum"
    fi
    echo "       first four cores now: ${cur}MHz"
    if systemctl is-enabled corex-cpu.service >/dev/null 2>&1; then
        echo -e "       Reapplied at boot: ${GREEN}yes${NC} (corex-cpu.service)"
    elif [[ -n "${POWER_CPU_MAX_MHZ:-}${POWER_CPU_EPP:-}" ]]; then
        echo -e "       Reapplied at boot: ${YELLOW}no${NC}, so a reboot undoes it"
    else
        echo "       CoreX is not managing the clock (corex manage power cpu 3000)"
    fi
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
    _power_cpu_show
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
