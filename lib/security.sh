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
        restic \
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

    # ── Fail2ban ─────────────────────────────────────────────────────────────
    log_info "Configuring Fail2ban..."
    cat > /etc/fail2ban/jail.local << F2BEOF
[DEFAULT]
bantime  = 86400
findtime = 600
maxretry = 3
banaction = ufw

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

    # ── Unattended Security Updates (security-only, no auto-reboot) ──────────
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
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Mail "";
UUEOF
    log_success "Unattended security upgrades configured (security-only, no auto-reboot)"

    # ── Kernel Hardening + Network Performance ─────────────────────────────────
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

    # ── Hardware watchdog ────────────────────────────────────────────────────
    # If the kernel hard-hangs, systemd's watchdog resets the box instead of
    # leaving it dark until someone power-cycles it manually.
    log_info "Enabling systemd hardware watchdog..."
    mkdir -p /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/99-corex-watchdog.conf << WDEOF
[Manager]
RuntimeWatchdogSec=60s
RebootWatchdogSec=10min
ShutdownWatchdogSec=10min
WDEOF
    systemctl daemon-reexec 2>/dev/null || true
    log_success "Watchdog armed (60s runtime timeout)"

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
