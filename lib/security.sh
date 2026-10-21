#!/bin/bash
# lib/security.sh — CoreX Pro v2
# Phase 2: SSH hardening, Fail2ban, kernel params, UFW firewall.
# Extracted from install-corex-master.sh Phase 2.

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

phase2_security() {
    log_step "═══ PHASE 2: Security Hardening ═══"

    # ── System Updates ───────────────────────────────────────────────────────
    log_info "Updating system packages..."
    apt-get update -qq && apt-get upgrade -y -qq \
        || log_warning "System update failed — continuing..."

    # ── Install Required Packages ────────────────────────────────────────────
    log_info "Installing security & utility packages..."
    apt-get install -y -qq \
        ufw fail2ban \
        unattended-upgrades apt-listchanges \
        curl wget nano htop jq \
        net-tools parted \
        avahi-daemon avahi-utils \
        logrotate rsync cron \
        lm-sensors smartmontools \
        apparmor apparmor-utils \
        restic sqlite3 \
        || log_warning "Some package installs failed — continuing..."

    # ── SSH Hardening ────────────────────────────────────────────────────────
    log_info "Hardening SSH (port ${SSH_PORT})..."
    cat > /etc/ssh/sshd_config.d/99-corex.conf << SSHEOF
Port ${SSH_PORT}
PermitRootLogin no
PasswordAuthentication yes
MaxAuthTries 3
LoginGraceTime 20
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
PermitEmptyPasswords no
ClientAliveInterval 300
ClientAliveCountMax 2
DebianBanner no
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
SSHEOF
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    log_success "SSH hardened (port ${SSH_PORT}, root login disabled, modern ciphers only)"

    _security_fail2ban
    _security_unattended
    _security_sysctl

    # ── Journal size cap ─────────────────────────────────────────────────────
    # systemd-journald defaults to 10% of the filesystem, which on a large SSD
    # grows to many GB and was never bounded. Persistent storage is kept (it is
    # what makes post-crash forensics possible) but capped.
    log_info "Capping systemd journal size..."
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/99-corex.conf << JEOF
[Journal]
Storage=persistent
SystemMaxUse=500M
SystemKeepFree=1G
SystemMaxFileSize=50M
MaxRetentionSec=1month
JEOF
    systemctl restart systemd-journald 2>/dev/null || true
    log_success "Journal capped at 500M, 1 month retention"

    _security_watchdog

    # ── UFW Firewall ──────────────────────────────────────────────────────────
    log_info "Configuring UFW firewall..."
    ufw --force reset > /dev/null 2>&1
    ufw default deny incoming
    ufw default allow outgoing

    # Public-facing ports
    ufw allow "${SSH_PORT}/tcp" comment 'SSH (custom port)'
    ufw allow 80/tcp            comment 'HTTP (Traefik redirects to HTTPS)'
    ufw allow 443/tcp           comment 'HTTPS (Traefik TLS termination)'
    ufw allow 53                comment 'DNS (AdGuard Home, TCP+UDP)'
    # Traefik dashboard (8080) is bound to 127.0.0.1 — no external rule needed
    ufw allow 3000/tcp          comment 'AdGuard Home Setup UI'
    ufw allow 9443/tcp          comment 'Portainer (HTTPS UI)'
    ufw allow 5678/tcp          comment 'n8n Workflow Automation'
    ufw allow 2283/tcp          comment 'Immich Photo Management'
    ufw allow 3001/tcp          comment 'Uptime Kuma Status Page'
    ufw allow 3002/tcp          comment 'Grafana Dashboards'
    ufw allow 8000/tcp          comment 'Coolify Web Hosting'
    ufw allow 5353/udp          comment 'mDNS (Avahi/Bonjour discovery)'

    # Mail ports (Stalwart)
    ufw allow 25/tcp  comment 'SMTP (inbound mail)'
    ufw allow 587/tcp comment 'SMTP Submission (outbound mail)'
    ufw allow 465/tcp comment 'SMTPS (encrypted submission)'
    ufw allow 143/tcp comment 'IMAP (mail retrieval)'
    ufw allow 993/tcp comment 'IMAPS (encrypted mail retrieval)'

    # LAN-only services (Time Machine, Ollama, Open WebUI)
    local lan_subnet="${SERVER_IP%.*}.0/24"
    ufw allow from "$lan_subnet" to any port 445 proto tcp   comment 'SMB (Time Machine)'
    ufw allow from "$lan_subnet" to any port 137:139 proto tcp comment 'NetBIOS (Time Machine)'
    ufw allow from "$lan_subnet" to any port 11434 proto tcp comment 'Ollama LLM (LAN only)'
    ufw allow from "$lan_subnet" to any port 3003 proto tcp  comment 'Open WebUI (LAN only)'

    # Docker internal traffic (prevents 502 Bad Gateway)
    ufw allow in on docker0
    # Compose's per-project bridges (br-<hash>) draw from Docker's default
    # address pool, so the 172.16.0.0/12 rule below already covers them.
    ufw allow from 172.16.0.0/12 to any comment 'Docker default address pool'
    # Docker Swarm / Coolify allocate overlay networks from 10.0.0.0/8, which is
    # outside 172.16.0.0/12. Without this, overlay traffic (e.g. 10.0.1.x ->
    # 10.0.0.1) is dropped and logged continuously.
    ufw allow from 10.0.0.0/8 to any comment 'Docker Swarm / Coolify overlay'

    # Blocked-packet logging stays ON — it is real security signal. The log
    # flood it used to produce came from the missing 10.0.0.0/8 rule above,
    # not from logging being too verbose.
    ufw logging low

    ufw --force enable
    log_success "UFW firewall active (${SSH_PORT}, 80, 443 + LAN services)"
}

_security_fail2ban() {
    log_info "Configuring Fail2ban..."
    # An ignoreip line is the operator's own allowlist, usually the home LAN so
    # a mistyped password from the laptop does not ban it for a day. Keep it
    # across a rewrite; dropping it is a lockout that only shows up later.
    local ignoreip=""
    [[ -f /etc/fail2ban/jail.local ]] \
        && ignoreip=$(grep -m1 -E '^[[:space:]]*ignoreip[[:space:]]*=' /etc/fail2ban/jail.local || true)
    cat > /etc/fail2ban/jail.local << F2BEOF
[DEFAULT]
bantime  = 86400
findtime = 600
maxretry = 3
banaction = ufw
${ignoreip}

[sshd]
enabled  = true
port     = ${SSH_PORT}
logpath  = %(sshd_log)s
backend  = %(sshd_backend)s
maxretry = 3
bantime  = 86400

[sshd-aggressive]
enabled  = true
port     = ${SSH_PORT}
logpath  = %(sshd_log)s
backend  = %(sshd_backend)s
filter   = sshd[mode=aggressive]
maxretry = 2
bantime  = 604800
findtime = 3600

[recidive]
enabled  = true
logpath  = /var/log/fail2ban.log
bantime  = 2592000
findtime = 86400
maxretry = 3
F2BEOF
    systemctl enable --now fail2ban 2>/dev/null || true
    log_success "Fail2ban active (3 fails → 24hr ban, repeat offenders → 30-day ban)"

}

# Security-only unattended upgrades, no auto-reboot.
_security_unattended() {
    log_info "Configuring unattended security updates..."
    cat > /etc/apt/apt.conf.d/20auto-upgrades << 'AUEOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
AUEOF

    cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'UUEOF'
// CoreX Pro — Unattended Upgrades (security patches only, no automatic reboots)
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
// Do NOT automatically reboot — server stays up, admin reboots deliberately
Unattended-Upgrade::Automatic-Reboot "false";

// Kernel, libc and systemd upgrades are EXCLUDED from unattended runs.
//
// "Security-only" is not sufficient protection: Ubuntu ships kernel updates
// through the -security origin, so an unattended run will happily upgrade the
// kernel. On a mini server that is the single most dangerous thing it can do
// unsupervised — the upgrade drives CPU load up, and if the box then loses
// power or thermal-trips mid-transaction, dpkg is left with systemd and
// libc-bin unpacked-but-unconfigured, which can leave the machine unbootable.
//
// These three package families are the ones where an interrupted transaction
// is unrecoverable without physical console access. They still get upgraded,
// just deliberately, by an operator who is watching:
//     sudo apt-get install --only-upgrade linux-generic
// or simply:  corex manage os-upgrade
Unattended-Upgrade::Package-Blacklist {
    "linux-generic";
    "linux-image-";
    "linux-headers-";
    "linux-modules-";
    "linux-firmware";
    "libc6";
    "libc-bin";
    "systemd";
    "udev";
};

// Leave old kernels alone during unattended runs — removing a kernel is also
// a dpkg transaction, and a known-good fallback kernel is worth the disk.
Unattended-Upgrade::Remove-Unused-Kernel-Packages "false";
Unattended-Upgrade::Remove-Unused-Dependencies "false";

// If an unattended run is interrupted, let the next one repair rather than
// refuse to proceed.
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
// Never hold the lock during a shutdown — that is how dpkg gets killed.
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Mail "";
UUEOF
    systemctl unmask apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
    systemctl enable --now apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service 2>/dev/null || true
    log_success "Unattended security upgrades configured (security-only, no auto-reboot)"

}

# Kernel hardening and network performance parameters.
_security_sysctl() {
    log_info "Applying kernel security and network performance parameters..."
    cat > /etc/sysctl.d/99-corex.conf << SYEOF
# ── Security: Anti-spoofing ──────────────────────────────────────────────────
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# ── Security: SYN flood / connection hardening ───────────────────────────────
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_rfc1337 = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# ── Performance: TCP buffer tuning (critical for Gbps file transfers) ────────
# Default Linux buffers (~200KB) are far too small for gigabit/multi-gigabit LAN.
# These settings allow the kernel to auto-tune up to 64MB per socket:
#   min=4KB  default=256KB  max=64MB
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 262144 67108864
net.ipv4.tcp_wmem = 4096 262144 67108864
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# ── Performance: TCP window scaling + timestamps (RFC 1323) ──────────────────
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1

# ── Performance: BBR congestion control ──────────────────────────────────────
# BBR (Bottleneck Bandwidth and RTT) vastly outperforms CUBIC on LAN transfers.
# It estimates actual bandwidth instead of relying on packet loss signals.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ── Performance: Connection handling ─────────────────────────────────────────
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3

# ── Performance: Increase file descriptor + inotify limits ───────────────────
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512

# ── Performance: VM tuning for file-server workloads ─────────────────────────
# dirty_ratio caps how much RAM may hold un-flushed writes. The old value (40%)
# meant many GB of unwritten data on a 32GB box — a power loss then discards all
# of it, risking database corruption (MariaDB/PostgreSQL). It also causes
# multi-second stalls when the kernel finally flushes. 10/5 keeps throughput
# while bounding the loss window.
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.dirty_expire_centisecs = 3000
vm.swappiness = 10
SYEOF
    sysctl --system > /dev/null 2>&1
    log_success "Kernel hardened + network tuned for multi-gigabit performance"
}

# If the kernel hard-hangs, systemd's watchdog resets the box instead of
# leaving it dark until someone power-cycles it manually.
_security_watchdog() {
    log_info "Enabling systemd hardware watchdog..."
    mkdir -p /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/99-corex-watchdog.conf << WDEOF
[Manager]
RuntimeWatchdogSec=60s
RebootWatchdogSec=10min
ShutdownWatchdogSec=10min
WDEOF
    # RuntimeWatchdogSec only does anything if a watchdog device exists, and
    # Ubuntu deny-lists every hardware watchdog driver. lib/recovery.sh owns
    # loading it at boot, past that deny-list; see gotcha #84.
    # shellcheck source=lib/recovery.sh
    source "$(dirname "${BASH_SOURCE[0]}")/recovery.sh"
    _recovery_install_watchdog
    _recovery_install_panic_reboot
    _recovery_install_idle_guard
    systemctl daemon-reexec 2>/dev/null || true
    log_success "Watchdog armed (60s runtime timeout)"
}


# ── Audit and Re-apply ────────────────────────────────────────────────────────

security_check() {
    echo ""
    echo -e "${CYAN}${BOLD}CoreX Security Audit${NC}"
    echo "─────────────────────────────────────────────────────────"
    echo ""

    local passed=0
    local warnings=0
    local errors=0

    # 1. SSH hardening
    echo -e "  ${BOLD}SSH Configuration:${NC}"
    local root_login ssh_p
    root_login=$(sshd -T 2>/dev/null | awk '/^permitrootlogin /{print $2}')
    ssh_p=$(sshd -T 2>/dev/null | awk '/^port /{print $2}')
    if [[ "$root_login" == "no" ]]; then
        echo -e "    ${GREEN}OK${NC} PermitRootLogin disabled (port ${ssh_p:-2222})"
        ((passed++))
    else
        echo -e "    ${YELLOW}WARN${NC} PermitRootLogin is '${root_login}' (expected 'no')"
        ((warnings++))
    fi

    # 2. UFW firewall
    echo -e "  ${BOLD}UFW Firewall:${NC}"
    if command -v ufw &>/dev/null; then
        local ufw_status
        ufw_status=$(ufw status 2>/dev/null | head -1)
        # "inactive" contains "active", so match the whole word.
        if [[ "$ufw_status" == "Status: active" ]]; then
            echo -e "    ${GREEN}OK${NC} UFW firewall is active"
            ((passed++))
        else
            echo -e "    ${RED}FAIL${NC} UFW firewall is INACTIVE"
            ((errors++))
        fi
    else
        echo -e "    ${RED}FAIL${NC} UFW is not installed"
        ((errors++))
    fi

    # 3. Fail2ban
    echo -e "  ${BOLD}Fail2ban Intrusion Prevention:${NC}"
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        echo -e "    ${GREEN}OK${NC} fail2ban service is active"
        ((passed++))
    else
        echo -e "    ${YELLOW}WARN${NC} fail2ban service is inactive"
        ((warnings++))
    fi

    # 4. Unattended security updates and timers
    echo -e "  ${BOLD}Unattended Security Updates:${NC}"
    local apt_masked=false
    if systemctl is-enabled apt-daily.timer 2>/dev/null | grep -q "masked" || \
       systemctl is-enabled apt-daily-upgrade.timer 2>/dev/null | grep -q "masked"; then
        apt_masked=true
    fi

    if [[ "$apt_masked" == "true" ]]; then
        echo -e "    ${RED}FAIL${NC} apt-daily.timer or apt-daily-upgrade.timer is masked (auto-updates suppressed)"
        ((errors++))
    elif systemctl is-active --quiet apt-daily-upgrade.timer 2>/dev/null; then
        echo -e "    ${GREEN}OK${NC} apt-daily and apt-daily-upgrade timers are active"
        ((passed++))
    else
        echo -e "    ${YELLOW}WARN${NC} apt-daily-upgrade.timer is not active"
        ((warnings++))
    fi

    if [[ -f /etc/apt/apt.conf.d/50unattended-upgrades ]] && \
       grep -q 'Unattended-Upgrade::Package-Blacklist' /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null; then
        echo -e "    ${GREEN}OK${NC} Kernel and libc blacklist configured for unattended updates"
        ((passed++))
    else
        echo -e "    ${YELLOW}WARN${NC} 50unattended-upgrades missing CoreX package blacklist"
        ((warnings++))
    fi

    # 5. Kernel sysctl parameters
    echo -e "  ${BOLD}Kernel Hardening:${NC}"
    local syncookies rp_filter
    syncookies=$(sysctl -n net.ipv4.tcp_syncookies 2>/dev/null || echo 0)
    rp_filter=$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || echo 0)
    if [[ "$syncookies" == "1" && "$rp_filter" == "1" ]]; then
        echo -e "    ${GREEN}OK${NC} SYN flood protection and anti-spoofing enabled"
        ((passed++))
    else
        echo -e "    ${YELLOW}WARN${NC} Kernel parameters not active (syncookies=${syncookies}, rp_filter=${rp_filter})"
        ((warnings++))
    fi

    # 6. Hardware watchdog. The systemd setting alone proves nothing: with no
    #    watchdog device it is silently inert, and the box stays hung.
    echo -e "  ${BOLD}Hardware Watchdog:${NC}"
    local wd_usec
    wd_usec=$(systemctl show -p RuntimeWatchdogUSec --value 2>/dev/null || true)
    if [[ ! -e /dev/watchdog0 ]]; then
        echo -e "    ${YELLOW}WARN${NC} No watchdog device, so a hung kernel will not reset itself"
        ((warnings++))
    elif [[ -z "$wd_usec" || "$wd_usec" == "0" || "$wd_usec" == "infinity" ]]; then
        echo -e "    ${YELLOW}WARN${NC} Watchdog device present but systemd is not using it"
        ((warnings++))
    else
        echo -e "    ${GREEN}OK${NC} Hardware watchdog armed (${wd_usec})"
        ((passed++))
    fi

    # 7. A panic or a CPU lockup has to end in a reboot, or the machine waits
    #    for someone to cut the power. Ubuntu ships kernel.panic=0.
    echo -e "  ${BOLD}Recovery From A Kernel Hang:${NC}"
    local k_panic k_soft k_hard
    k_panic=$(sysctl -n kernel.panic 2>/dev/null || echo 0)
    k_soft=$(sysctl -n kernel.softlockup_panic 2>/dev/null || echo 0)
    k_hard=$(sysctl -n kernel.hardlockup_panic 2>/dev/null || echo 0)
    if [[ "$k_panic" != "0" && "$k_soft" == "1" && "$k_hard" == "1" ]]; then
        echo -e "    ${GREEN}OK${NC} A panic or a CPU lockup reboots after ${k_panic}s"
        ((passed++))
    else
        echo -e "    ${YELLOW}WARN${NC} A kernel panic or lockup leaves the machine dead (panic=${k_panic}, softlockup_panic=${k_soft}, hardlockup_panic=${k_hard})"
        ((warnings++))
    fi

    if grep -q 'AuthenticAMD' /proc/cpuinfo 2>/dev/null; then
        local deep=0 blocked=0 st
        for st in /sys/devices/system/cpu/cpu[0-9]*/cpuidle/state[0-9]*; do
            [[ -r "$st/latency" ]] || continue
            (( $(cat "$st/latency") >= 100 )) || continue
            deep=$((deep + 1))
            [[ "$(cat "$st/disable" 2>/dev/null)" == "1" ]] && blocked=$((blocked + 1))
        done
        if (( deep == 0 || blocked == deep )); then
            echo -e "    ${GREEN}OK${NC} Deep CPU idle state is off, so a low-load freeze cannot happen there"
            ((passed++))
        else
            echo -e "    ${YELLOW}WARN${NC} Ryzen deep idle state is enabled on $((deep - blocked)) of ${deep} CPU entries; it can freeze the whole platform at low load"
            ((warnings++))
        fi
    fi

    echo ""
    if (( errors > 0 )); then
        log_warning "Security audit: ${passed} passed, ${warnings} warning(s), ${errors} error(s)."
        echo "    Run 'sudo corex manage security apply' to apply recommended security hardening."
        return 1
    elif (( warnings > 0 )); then
        log_info "Security audit: ${passed} passed, ${warnings} warning(s)."
        return 0
    else
        log_success "Security audit: all ${passed} checks passed."
        return 0
    fi
}

# Repairs exactly what security_check reports, and nothing else. It is not
# phase2_security: that runs a full apt upgrade (gotcha #18) and resets UFW,
# which deletes every rule a service module added and reopens the ports of
# services that were removed. SSH is reported and never rewritten from here,
# because a wrong port in sshd_config is a lockout on a box with no console.
security_apply() {
    log_step "Applying CoreX security hardening..."
    _security_fail2ban
    _security_unattended
    _security_sysctl
    _security_watchdog

    if command -v ufw >/dev/null 2>&1 && ! ufw status 2>/dev/null | grep -q '^Status: active'; then
        log_info "UFW is inactive; enabling it with the base rules, keeping existing ones"
        ufw default deny incoming >/dev/null
        ufw default allow outgoing >/dev/null
        ufw allow "${SSH_PORT:-22}/tcp" comment 'SSH (custom port)' >/dev/null
        ufw allow 80/tcp  comment 'HTTP (Traefik redirects to HTTPS)' >/dev/null
        ufw allow 443/tcp comment 'HTTPS (Traefik TLS termination)' >/dev/null
        ufw allow 53      comment 'DNS (AdGuard Home, TCP+UDP)' >/dev/null
        ufw allow from 172.16.0.0/12 to any comment 'Docker default address pool' >/dev/null
        ufw allow from 10.0.0.0/8 to any comment 'Docker Swarm / Coolify overlay' >/dev/null
        ufw --force enable >/dev/null && log_success "UFW enabled"
    fi

    if [[ "$(sshd -T 2>/dev/null | awk '/^permitrootlogin /{print $2}')" != "no" ]]; then
        log_warning "SSH still permits root login. Set PermitRootLogin no in"
        log_warning "  /etc/ssh/sshd_config.d/ and run: sshd -t && systemctl reload ssh"
    fi
    security_check || true
}
