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
SSHEOF
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    log_success "SSH hardened (port ${SSH_PORT}, root login disabled)"

    # ── Fail2ban ─────────────────────────────────────────────────────────────
    log_info "Configuring Fail2ban..."
    cat > /etc/fail2ban/jail.local << F2BEOF
[DEFAULT]
bantime  = 86400
findtime = 600
maxretry = 3

[sshd]
enabled = true
port    = ${SSH_PORT}
logpath = %(sshd_log)s
backend = %(sshd_backend)s
F2BEOF
    systemctl enable --now fail2ban 2>/dev/null || true
    log_success "Fail2ban active (3 failures → 24hr ban)"

    # ── Auto Security Updates ─────────────────────────────────────────────────
    cat > /etc/apt/apt.conf.d/20auto-upgrades << AUEOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
AUEOF

    # ── Kernel Hardening ──────────────────────────────────────────────────────
    log_info "Applying kernel security parameters..."
    cat > /etc/sysctl.d/99-corex.conf << SYEOF
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
SYEOF
    sysctl --system > /dev/null 2>&1
    log_success "Kernel hardened"

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
    ufw allow 8080/tcp          comment 'Traefik Dashboard'
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
    ufw allow from 172.16.0.0/12 to any

    ufw --force enable
    log_success "UFW firewall active (${SSH_PORT}, 80, 443 + LAN services)"
}
