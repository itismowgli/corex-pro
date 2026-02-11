#!/bin/bash
################################################################################
#
#   ██████╗ ██████╗ ██████╗ ███████╗██╗  ██╗    ██████╗ ██████╗  ██████╗
#  ██╔════╝██╔═══██╗██╔══██╗██╔════╝╚██╗██╔╝    ██╔══██╗██╔══██╗██╔═══██╗
#  ██║     ██║   ██║██████╔╝█████╗   ╚███╔╝     ██████╔╝██████╔╝██║   ██║
#  ██║     ██║   ██║██╔══██╗██╔══╝   ██╔██╗     ██╔═══╝ ██╔══██╗██║   ██║
#  ╚██████╗╚██████╔╝██║  ██║███████╗██╔╝ ██╗    ██║     ██║  ██║╚██████╔╝
#   ╚═════╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝    ╚═╝     ╚═╝  ╚═╝ ╚═════╝
#
#  CoreX Pro — Sovereign Hybrid Homelab (Battle-Tested)
#  "Brains on System. Muscle on SSD."
#
#  ═══════════════════════════════════════════════════════════════════════════
#  ARCHITECTURE
#  ═══════════════════════════════════════════════════════════════════════════
#
#  ┌─ INTERNET ────────────────────────────────────────────────────────────┐
#  │  Cloudflare Tunnel (encrypted, zero port-forwarding required)         │
#  │  CF Dashboard: Public Hostnames → container_name:port (NOT localhost) │
#  ├─ SECURITY ────────────────────────────────────────────────────────────┤
#  │  UFW (firewall) → CrowdSec (community IPS) → Fail2ban (SSH jail)     │
#  │  SSH on port 2222 + kernel hardening + auto security updates          │
#  ├─ DNS & ROUTING ───────────────────────────────────────────────────────┤
#  │  AdGuard Home (DNS:53, Admin:3000) → DNS Rewrites: *.domain → LAN IP │
#  │  Traefik v3 (HTTP→HTTPS redirect, Let's Encrypt TLS, security hdrs)  │
#  ├─ CORE SERVICES ───────────────────────────────────────────────────────┤
#  │  Portainer       – Docker management UI              (9443)           │
#  │  Nextcloud       – Files/NAS/sync (Google Drive alt)  (Traefik)       │
#  │  Immich          – Photos (Google Photos alternative) (2283)          │
#  │  Vaultwarden     – Passwords (Bitwarden alternative)  (Traefik)       │
#  │  Stalwart Mail   – Email server (SMTP/IMAP/CalDAV)    (25/587/993)    │
#  │  Coolify         – Web hosting PaaS (Vercel alt)      (8000)          │
#  │  n8n             – Workflow automation                 (5678)          │
#  │  Time Machine    – macOS backups via SMB              (445)           │
#  │  Uptime Kuma     – Status monitoring                  (3001)          │
#  │  Grafana+Prom    – Metrics & dashboards               (3002/9090)     │
#  ├─ AI LAYER (Sandboxed) ────────────────────────────────────────────────┤
#  │  Ollama          – Local LLM engine                   (11434)         │
#  │  Open WebUI      – ChatGPT-like interface             (3003)          │
#  │  Browserless     – Headless Chrome for AI agents      (3005)          │
#  ├─ BACKUP ──────────────────────────────────────────────────────────────┤
#  │  Restic          – Encrypted snapshots (daily cron at 3AM)            │
#  │                    Retention: 7 daily, 4 weekly, 6 monthly            │
#  │                    Commands: corex-backup.sh / corex-restore.sh       │
#  ├─ STORAGE ─────────────────────────────────────────────────────────────┤
#  │  LOCAL DISK: OS + Docker Engine only (fast boot, stable)              │
#  │  EXT SSD /dev/sdX:                                                    │
#  │    Part 1 (400GB) → /mnt/timemachine   (optional, legacy partition)  │
#  │    Part 2 (~600GB)→ /mnt/corex-data    (ALL data: services + TM)     │
#  │      ├── docker-configs/  (compose files, each service gets a dir)    │
#  │      ├── service-data/    (databases, uploads, persistent app state)  │
#  │      └── backups/         (Restic encrypted repository)               │
#  └───────────────────────────────────────────────────────────────────────┘
#
#  USAGE:
#    chmod +x install-corex-master.sh
#    sudo bash install-corex-master.sh
#
################################################################################

set -e          # Exit immediately if any command fails
set -u          # Exit if an undefined variable is used
set -o pipefail # Pipe fails if ANY command in the pipeline fails

################################################################################
#                           CONFIGURATION
# Edit these values before running. Passwords are auto-generated on first run
# and saved to /root/corex-credentials.txt (loaded on subsequent runs).
################################################################################

SERVER_IP="192.168.1.100"               # Your server's static LAN IP
DOMAIN="example.com"                    # Your domain (DNS managed via Cloudflare)
EMAIL="admin@example.com"              # Used for Let's Encrypt cert registration
TIMEZONE="UTC"                          # Server timezone (e.g. America/New_York, Asia/Kolkata)
SSH_PORT="2222"                         # Non-standard SSH port (security through obscurity)

# Cloudflare Tunnel Token — get from:
# https://one.dash.cloudflare.com → Networks → Tunnels → Create a Tunnel
# Leave as PASTE_YOUR_TUNNEL_TOKEN_HERE to skip tunnel setup
CLOUDFLARE_TUNNEL_TOKEN="PASTE_YOUR_TUNNEL_TOKEN_HERE"

# ── Storage Layout ──
# External SSD gets two partitions:
#   Partition 1: Time Machine backups (macOS)
#   Partition 2: All Docker configs, service data, backups
TM_SIZE="500GB"                          # Size for Time Machine partition
MOUNT_TM="/mnt/timemachine"              # Mount point for Time Machine partition
MOUNT_POOL="/mnt/corex-data"             # Mount point for data pool partition

# ── Derived Paths (all live on external SSD) ──
DOCKER_ROOT="${MOUNT_POOL}/docker-configs"   # docker-compose.yml per service
DATA_ROOT="${MOUNT_POOL}/service-data"       # Persistent data (DBs, uploads, etc.)
BACKUP_ROOT="${MOUNT_POOL}/backups"          # Restic encrypted backup repository
CRED_FILE="/root/corex-credentials.txt"      # Auto-generated passwords stored here
DOCS_FILE="/root/CoreX_Dashboard_Credentials.md"  # Full dashboard & setup guide

################################################################################
#                           HELPER FUNCTIONS
################################################################################

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'
YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_step()    { echo -e "${CYAN}${BOLD}[STEP]${NC} $1"; }
log_success() { echo -e "${GREEN}[  OK]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

# FIXED: logic rewrite to ensure function returns success when check passes
check_root() { 
    if [[ $EUID -ne 0 ]]; then 
        log_error "Run as root: sudo bash install-corex-master.sh"
    fi
    return 0
}

# Generate a 24-char random password (alphanumeric, no special chars)
generate_pass() { openssl rand -base64 24 | tr -d '/+=' | head -c 24; }

################################################################################
# PHASE 0: PRE-FLIGHT CHECKS
# Validates environment, generates or loads passwords for idempotent re-runs.
################################################################################

phase0_precheck() {
    log_step "═══ PHASE 0: Pre-Flight Checks ═══"

    # 1. Verify internet (needed to pull Docker images)
    if ping -c 1 -W 3 google.com &>/dev/null; then
        log_success "Internet connection OK."
    else
        log_warning "Internet check failed. Proceeding anyway, but downloads may fail."
    fi

    # 2. Check RAM (Ollama needs ~4GB for small models)
    local mem_total
    mem_total=$(free -g | awk '/Mem/{print $2}')
    if [[ $mem_total -lt 8 ]]; then
        log_warning "Low RAM: ${mem_total}GB. AI services may be slow. 8GB+ recommended."
    else
        log_success "RAM: ${mem_total}GB — sufficient."
    fi

    # 3. Load or generate passwords
    # If cred file exists from a previous run, we load it to avoid generating
    # new passwords (which would lock us out of existing databases).
    if [[ -f "$CRED_FILE" ]]; then
        log_info "Loading existing credentials from $CRED_FILE..."
        MYSQL_ROOT_PASS=$(grep "MySQL Root:" "$CRED_FILE" | awk '{print $3}')
        NEXTCLOUD_DB_PASS=$(grep "Nextcloud DB:" "$CRED_FILE" | awk '{print $3}')
        N8N_ENCRYPTION_KEY=$(grep "n8n Encryption:" "$CRED_FILE" | awk '{print $3}')
        TM_PASSWORD=$(grep "Time Machine:" "$CRED_FILE" | awk '{print $3}')
        VAULTWARDEN_ADMIN_TOKEN=$(grep "Vaultwarden:" "$CRED_FILE" | awk '{print $2}')
        GRAFANA_ADMIN_PASS=$(grep "Grafana Admin:" "$CRED_FILE" | awk '{print $3}')
        RESTIC_PASSWORD=$(grep "Restic Backup:" "$CRED_FILE" | awk '{print $3}')
        IMMICH_DB_PASS=$(grep "Immich DB:" "$CRED_FILE" | awk '{print $3}')
        WEBUI_SECRET_KEY=$(grep "AI WebUI Secret:" "$CRED_FILE" | awk '{print $4}')
        STALWART_ADMIN_PASS=$(grep "Stalwart Admin:" "$CRED_FILE" | awk '{print $4}')
        [[ -z "$STALWART_ADMIN_PASS" ]] && STALWART_ADMIN_PASS="(unknown — check: docker logs stalwart | grep password)"
        log_success "Existing passwords loaded (no new passwords generated)."
    else
        log_info "First run — generating secure passwords..."
        MYSQL_ROOT_PASS=$(generate_pass)
        NEXTCLOUD_DB_PASS=$(generate_pass)
        N8N_ENCRYPTION_KEY=$(generate_pass)
        TM_PASSWORD=$(generate_pass)
        VAULTWARDEN_ADMIN_TOKEN=$(generate_pass)
        GRAFANA_ADMIN_PASS=$(generate_pass)
        RESTIC_PASSWORD=$(generate_pass)
        IMMICH_DB_PASS=$(generate_pass)
        WEBUI_SECRET_KEY=$(generate_pass)
        STALWART_ADMIN_PASS=""  # Captured from container logs in Phase 5
        log_success "Passwords generated (will be saved at end)."
    fi

    # 4. Set timezone
    timedatectl set-timezone "$TIMEZONE" 2>/dev/null || true
    log_success "Timezone: $TIMEZONE"
}

################################################################################
# PHASE 1: DRIVE SETUP
# Partitions the external SSD into two ext4 partitions and mounts them.
# Supports both fresh format and re-mounting existing partitions.
################################################################################

phase1_drive() {
    log_step "═══ PHASE 1: Drive Setup (External SSD) ═══"

    # Show available disks for user to choose
    echo ""
    lsblk -d -o NAME,SIZE,MODEL,TRAN | grep -v loop
    echo ""
    log_warning "Enter the EXTERNAL SSD device name (e.g. sda, sdb, nvme1n1)"
    log_warning "⚠ DO NOT enter your OS drive!"
    read -p "Device: " DRIVE_NAME || log_error "No device input provided."
    TARGET_DEV="/dev/${DRIVE_NAME}"

    [[ ! -b "$TARGET_DEV" ]] && log_error "Device $TARGET_DEV not found."

    # Safety: unmount any existing partitions on the target drive
    # FIXED: Added lazy unmount (-l) and stop docker to prevent "Device or resource busy"
    log_info "Stopping Docker and clearing disk locks..."
    systemctl stop docker 2>/dev/null || true
    log_info "Unmounting any existing partitions..."
    for p in $(lsblk -ln -o NAME "$TARGET_DEV" | tail -n +2); do
        umount -l "/dev/$p" 2>/dev/null || true
    done

    # Clean old entries from fstab to avoid duplicates
    sed -i "\|$MOUNT_TM|d" /etc/fstab
    sed -i "\|$MOUNT_POOL|d" /etc/fstab
    systemctl daemon-reload

    # Ask: format fresh or just mount existing partitions?
    echo ""
    log_warning "Has this drive ALREADY been partitioned for CoreX?"
    read -p "Skip formatting and just mount existing partitions? (y/N): " SKIP_FORMAT || SKIP_FORMAT="n"

    if [[ "$SKIP_FORMAT" == "y" || "$SKIP_FORMAT" == "Y" ]]; then
        log_info "Skipping format — mounting existing partitions..."
    else
        # Destructive format
        log_warning "⚠ ALL DATA ON $TARGET_DEV WILL BE DESTROYED"
        read -p "Type 'DESTROY' to confirm: " CONFIRM || CONFIRM="CANCEL"
        [[ "$CONFIRM" != "DESTROY" ]] && log_error "Aborted by user."

        log_info "Wiping drive signatures..."
        # FIXED: Added explicit signatures wipe to ensure partition table can be re-written
        wipefs -a -f "$TARGET_DEV"

        log_info "Creating GPT partition table..."
        parted -s "$TARGET_DEV" mklabel gpt

        log_info "Partition 1: ${TM_SIZE} for Time Machine..."
        parted -s "$TARGET_DEV" mkpart primary ext4 0% "$TM_SIZE"

        log_info "Partition 2: remaining space for Data Pool..."
        parted -s "$TARGET_DEV" mkpart primary ext4 "$TM_SIZE" 100%

        # Wait for kernel to recognize new partitions
        sleep 2; partprobe "$TARGET_DEV"; sleep 3

        # Determine partition names (NVMe uses p1/p2, SATA uses 1/2)
        if [[ "$TARGET_DEV" == *nvme* ]]; then
            P1="${TARGET_DEV}p1"; P2="${TARGET_DEV}p2"
        else
            P1="${TARGET_DEV}1"; P2="${TARGET_DEV}2"
        fi

        log_info "Formatting partitions as ext4..."
        mkfs.ext4 -F -L TIMEMACHINE "$P1"
        mkfs.ext4 -F -L COREX_DATA "$P2"
    fi

    # Handle partition naming for mount (same logic as above)
    if [[ "$TARGET_DEV" == *nvme* ]]; then
        P1="${TARGET_DEV}p1"; P2="${TARGET_DEV}p2"
    else
        P1="${TARGET_DEV}1"; P2="${TARGET_DEV}2"
    fi

    # Create mount points
    mkdir -p "$MOUNT_TM" "$MOUNT_POOL"

    # Get UUIDs for stable fstab entries (survives device reordering)
    local U1 U2
    U1=$(blkid -s UUID -o value "$P1")
    U2=$(blkid -s UUID -o value "$P2")
    [[ -z "$U1" || -z "$U2" ]] && log_error "Could not read partition UUIDs."

    # Add to fstab with nofail (system boots even if SSD is disconnected)
    echo "UUID=$U1 $MOUNT_TM ext4 defaults,noatime,nofail 0 2" >> /etc/fstab
    echo "UUID=$U2 $MOUNT_POOL ext4 defaults,noatime,nofail 0 2" >> /etc/fstab
    mount -a

    # Verify
    mountpoint -q "$MOUNT_TM" && mountpoint -q "$MOUNT_POOL" \
        && log_success "Both partitions mounted." \
        || log_error "Mount failed. Check dmesg for errors."
    df -h "$MOUNT_TM" "$MOUNT_POOL"
    
    # Restart Docker now that the pool is mounted
    systemctl start docker 2>/dev/null || true
}

################################################################################
# PHASE 2: SECURITY HARDENING
# Configures: SSH lockdown, Fail2ban, CrowdSec (later), kernel params, UFW.
# Follows best practices from NetworkChuck, SimpleHomelab, and CIS benchmarks.
################################################################################

phase2_security() {
    log_step "═══ PHASE 2: Security Hardening ═══"

    # ── System Updates ──────────────────────────────────────────────────────
    log_info "Updating system packages..."
    apt-get update -qq && apt-get upgrade -y -qq || log_warning "System update failed — continuing..."

    # ── Install Required Packages ───────────────────────────────────────────
    # avahi-daemon:   Required for macOS Time Machine discovery (Bonjour/mDNS)
    # avahi-utils:    CLI tools for Avahi (avahi-browse, etc.)
    # apparmor-utils: Mandatory Access Control for Docker containers
    # unattended-upgrades: Automatic security patches
    # restic:         Backup tool (used in Phase 6)
    log_info "Installing security & utility packages..."
    apt-get install -y -qq \
        ufw fail2ban \
        unattended-upgrades apt-listchanges \
        curl wget nano htop jq \
        net-tools parted \
        avahi-daemon avahi-utils \
        logrotate rsync cron \
        apparmor apparmor-utils \
        restic || log_warning "Some package installs failed — continuing..."

    # ── SSH Hardening ───────────────────────────────────────────────────────
    # Move SSH off port 22 to reduce drive-by bot attacks.
    # Disable root login. Limit auth attempts to 3 before disconnect.
    # Set idle timeout to 10 minutes (300s × 2 keepalives).
    # NOTE: Password auth left enabled for now. After setting up SSH keys,
    # uncomment PasswordAuthentication no below and re-run.
    log_info "Hardening SSH on port ${SSH_PORT}..."
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%s)
    sed -i "s/^#\?Port .*/Port ${SSH_PORT}/"                   /etc/ssh/sshd_config
    sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/"      /etc/ssh/sshd_config
    sed -i "s/^#\?MaxAuthTries .*/MaxAuthTries 3/"             /etc/ssh/sshd_config
    sed -i "s/^#\?PermitEmptyPasswords .*/PermitEmptyPasswords no/" /etc/ssh/sshd_config
    sed -i "s/^#\?ClientAliveInterval .*/ClientAliveInterval 300/"  /etc/ssh/sshd_config
    sed -i "s/^#\?ClientAliveCountMax .*/ClientAliveCountMax 2/"    /etc/ssh/sshd_config
    # Uncomment this AFTER setting up SSH keys:
    # sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication no/" /etc/ssh/sshd_config
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    log_success "SSH hardened (port ${SSH_PORT}, root login disabled)"

    # ── Fail2ban ────────────────────────────────────────────────────────────
    # Watches SSH logs. After 3 failed logins in 10min, bans IP for 24 hours.
    # Uses UFW as the ban action (adds deny rule automatically).
    log_info "Configuring Fail2ban..."
    cat > /etc/fail2ban/jail.local << F2BEOF
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 3
banaction = ufw

[sshd]
enabled  = true
port     = ${SSH_PORT}
maxretry = 3
bantime  = 86400
F2BEOF
    systemctl enable --now fail2ban
    log_success "Fail2ban active (SSH: 3 attempts → 24hr ban)"

    # ── Automatic Security Updates ──────────────────────────────────────────
    # Silently installs security patches daily. No manual intervention needed.
    log_info "Enabling automatic security updates..."
    cat > /etc/apt/apt.conf.d/20auto-upgrades << AUEOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
AUEOF
    systemctl enable --now unattended-upgrades
    log_success "Auto security updates enabled"

    # ── Kernel Hardening (sysctl) ───────────────────────────────────────────
    # These prevent common network-level attacks:
    # - rp_filter: Rejects packets with spoofed source IPs
    # - accept_redirects: Prevents ICMP redirect attacks (MITM vector)
    # - send_redirects: Server should not send ICMP redirects
    # - ignore_broadcasts: Blocks smurf amplification attacks
    # - tcp_syncookies: Mitigates SYN flood DoS attacks
    # - log_martians: Logs impossible source addresses for forensics
    log_info "Applying kernel hardening..."
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

    # ── UFW Firewall ────────────────────────────────────────────────────────
    # Default: deny all incoming, allow all outgoing.
    # Each port is explicitly opened with a comment explaining its purpose.
    # LAN-only services (SMB, Ollama, WebUI) are restricted to 192.168.29.0/24.
    log_info "Configuring UFW firewall..."
    ufw --force reset > /dev/null 2>&1
    ufw default deny incoming
    ufw default allow outgoing

    # ── Public-facing ports ──
    ufw allow ${SSH_PORT}/tcp   comment 'SSH (custom port)'
    ufw allow 80/tcp            comment 'HTTP (Traefik → redirects to HTTPS)'
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

    # ── Mail ports (Stalwart) ──
    ufw allow 25/tcp            comment 'SMTP (inbound mail)'
    ufw allow 587/tcp           comment 'SMTP Submission (outbound mail)'
    ufw allow 465/tcp           comment 'SMTPS (encrypted submission)'
    ufw allow 143/tcp           comment 'IMAP (mail retrieval)'
    ufw allow 993/tcp           comment 'IMAPS (encrypted mail retrieval)'

    # ── LAN-only services (restricted to local network) ──
    # FIXED: Added proto tcp for ranges to satisfy UFW protocol requirement
    ufw allow from 192.168.29.0/24 to any port 445 proto tcp   comment 'SMB (Time Machine)'
    ufw allow from 192.168.29.0/24 to any port 137:139 proto tcp comment 'NetBIOS (Time Machine)'
    ufw allow from 192.168.29.0/24 to any port 11434 proto tcp comment 'Ollama LLM (LAN only)'
    ufw allow from 192.168.29.0/24 to any port 3003 proto tcp  comment 'Open WebUI (LAN only)'

    # ── Docker internal traffic (CRITICAL: prevents 502 Bad Gateway errors) ──
    # Docker containers communicate on 172.x.x.x subnets. Without this,
    # UFW blocks Traefik → container traffic and you get 502 errors.
    ufw allow in on docker0
    ufw allow from 172.16.0.0/12 to any

    ufw --force enable
    log_success "UFW firewall active (${SSH_PORT}, 80, 443 + LAN services)"
}

################################################################################
# PHASE 3: DOCKER INSTALLATION
# Installs Docker Engine and creates the three isolated Docker networks.
# Docker data stays on local disk for performance (images, layers, cache).
# Persistent app data lives on SSD via bind mounts.
################################################################################

phase3_docker() {
    log_step "═══ PHASE 3: Docker Installation ═══"

    # Install Docker if not present
    if ! command -v docker &>/dev/null; then
        log_info "Installing Docker Engine..."
        curl -fsSL https://get.docker.com | sh || log_error "Docker installation failed."
    else
        log_success "Docker already installed."
    fi

    systemctl enable --now docker
    log_success "Docker running."

    # ── Create isolated networks ────────────────────────────────────────────
    # proxy-net:      All web services + Traefik + Cloudflared
    # monitoring-net: Prometheus + Grafana + exporters (isolated from web)
    # ai-net:         Ollama + WebUI + Browserless (sandboxed)
    docker network create proxy-net 2>/dev/null || true
    docker network create monitoring-net 2>/dev/null || true
    docker network create ai-net 2>/dev/null || true

    log_success "Docker networks created (proxy-net, monitoring-net, ai-net)"
}

################################################################################
# PHASE 4: DIRECTORY STRUCTURE
# Creates the full directory tree on the external SSD.
# Every service gets: a config dir (for docker-compose.yml) and a data dir
# (for persistent state). This separation makes backups and migration clean.
################################################################################

phase4_directories() {
    log_step "═══ PHASE 4: Directory Structure ═══"

    # ── Compose config directories (one per service) ──
    mkdir -p "${DOCKER_ROOT}"/{traefik,portainer,nextcloud,stalwart,immich,vaultwarden,n8n,ai,monitoring,timemachine,adguard,coolify,crowdsec,cloudflared}

    # ── Persistent data directories ──
    # Each maps to a Docker bind mount. Named to match the service.
    mkdir -p "${DATA_ROOT}"/{nextcloud-db,nextcloud-html,immich-db,immich-upload,stalwart-data,vaultwarden,n8n,ollama,open-webui,browserless,adguard-work,adguard-conf,uptime-kuma,grafana,prometheus,portainer,crowdsec-db,crowdsec-config}

    # ── Backup directory ──
    mkdir -p "${BACKUP_ROOT}"

    # ── Fix ownership ──
    # Default: 1000:1000 (first non-root user)
    # Nextcloud webroot needs www-data (uid 33)
    # Grafana needs uid 472
    chown -R 1000:1000 "${DOCKER_ROOT}" "${DATA_ROOT}"
    chown -R 33:33 "${DATA_ROOT}/nextcloud-html"
    chown -R 472:472 "${DATA_ROOT}/grafana"
    chown -R 1000:1000 "$MOUNT_TM"

    log_success "Directory structure created on SSD."
}

################################################################################
# PHASE 5: DEPLOY ALL SERVICES
# Each service is deployed as a docker-compose stack in its own directory.
# Every Traefik-routed service has:
#   - traefik.enable=true
#   - A Host() router rule for the subdomain
#   - websecure entrypoint (HTTPS only)
#   - TLS via Let's Encrypt (myresolver)
#   - loadbalancer.server.port (CRITICAL: tells Traefik which container port)
################################################################################

phase5_deploy() {
    log_step "═══ PHASE 5: Deploy Services ═══"

    ############################################################################
    # 1. TRAEFIK — Reverse Proxy & TLS Termination
    #    Listens on 80 (redirects to 443), 443 (HTTPS), 8080 (dashboard).
    #    Auto-discovers Docker containers with traefik.enable=true label.
    #    Uses Let's Encrypt TLS challenge for free SSL certificates.
    ############################################################################
    log_info "[1/14] Traefik (reverse proxy)"
    cd "${DOCKER_ROOT}/traefik"
    touch acme.json && chmod 600 acme.json  # Let's Encrypt cert storage (must be 600)

    # Static config: entrypoints, providers, certificate resolvers
    cat > traefik.yml << TEOF
api:
  insecure: true      # Dashboard on :8080 (disable in production or add auth)
  dashboard: true
entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https    # All HTTP → HTTPS automatically
  websecure:
    address: ":443"
providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false   # Only containers with traefik.enable=true are routed
    network: proxy-net        # Traefik connects to containers via this network
certificatesResolvers:
  myresolver:
    acme:
      tlsChallenge: {}        # TLS-ALPN-01 challenge (no port 80 needed for certs)
      email: "${EMAIL}"
      storage: /acme.json
TEOF

    cat > docker-compose.yml << DCEOF
services:
  traefik:
    image: traefik:v3.0
    container_name: traefik
    restart: unless-stopped
    ports:
      - "80:80"       # HTTP (redirects to HTTPS)
      - "443:443"     # HTTPS (TLS termination)
      - "8080:8080"   # Dashboard (access via http://SERVER_IP:8080)
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro   # Read-only Docker socket
      - ./traefik.yml:/traefik.yml:ro                  # Static config
      - ./acme.json:/acme.json                         # Let's Encrypt certs
    networks: [proxy-net]
    security_opt: ["no-new-privileges:true"]   # Prevent privilege escalation
networks:
  proxy-net: { external: true }
DCEOF
    docker compose up -d || log_warning "Container(s) may not have started — check with: docker ps"
    log_success "Traefik deployed (80→443, dashboard:8080)"

    ############################################################################
    # 2. ADGUARD HOME — DNS Server & Ad Blocker
    #    Runs DNS on port 53 (TCP+UDP). Admin UI on port 3000.
    #    FIRST RUN: AdGuard wizard listens on port 3000 inside container.
    #    AFTER SETUP: AdGuard switches to port 80 inside container.
    #    We detect which state we're in and map accordingly.
    #    After setup, configure DNS rewrites: *.domain → SERVER_IP
    #    Then set router DNS to SERVER_IP for local-first routing.
    ############################################################################
    log_info "[2/14] AdGuard Home (DNS + ad blocking)"

    # Disable systemd-resolved which holds port 53
    systemctl disable --now systemd-resolved 2>/dev/null || true
    rm -f /etc/resolv.conf
    printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /etc/resolv.conf
    # Lock the file so systemd can't overwrite it on reboot
    chattr +i /etc/resolv.conf 2>/dev/null || true

    cd "${DOCKER_ROOT}/adguard"

    # Detect if AdGuard has already been set up (config file exists with bind_port)
    local ADGUARD_INTERNAL_PORT="3000"
    if [[ -f "${DATA_ROOT}/adguard-conf/AdGuardHome.yaml" ]]; then
        # After setup wizard, AdGuard listens on port 80 (or whatever was configured)
        local CONFIGURED_PORT
        CONFIGURED_PORT=$(grep -A5 "http:" "${DATA_ROOT}/adguard-conf/AdGuardHome.yaml" | grep "address:" | grep -oP ':\K[0-9]+' | head -1)
        if [[ -n "$CONFIGURED_PORT" ]]; then
            ADGUARD_INTERNAL_PORT="$CONFIGURED_PORT"
            log_info "AdGuard already configured — internal port is $ADGUARD_INTERNAL_PORT"
        fi
    else
        log_info "AdGuard first run — wizard will listen on port 3000"
    fi

    cat > docker-compose.yml << DCEOF
services:
  adguard:
    image: adguard/adguardhome:latest
    container_name: adguard
    restart: unless-stopped
    ports:
      - "53:53/tcp"                              # DNS (TCP)
      - "53:53/udp"                              # DNS (UDP)
      - "3000:${ADGUARD_INTERNAL_PORT}/tcp"      # Admin UI → always accessible on host:3000
    volumes:
      - ${DATA_ROOT}/adguard-work:/opt/adguardhome/work    # Runtime data
      - ${DATA_ROOT}/adguard-conf:/opt/adguardhome/conf    # Configuration
    networks: [proxy-net]
networks:
  proxy-net: { external: true }
DCEOF
    docker compose up -d || log_warning "Container(s) may not have started — check with: docker ps"
    log_success "AdGuard Home deployed (DNS:53, Admin:3000)"

    ############################################################################
    # 3. PORTAINER — Docker Management UI
    #    Web UI at port 9443 (HTTPS). Manages all containers, images, volumes.
    #    Data stored on SSD (not anonymous volume) so it's included in backups.
    ############################################################################
    log_info "[3/14] Portainer (Docker management)"
    cd "${DOCKER_ROOT}/portainer"
    cat > docker-compose.yml << DCEOF
services:
  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: unless-stopped
    ports: ["9443:9443"]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock   # Docker access
      - ${DATA_ROOT}/portainer:/data                # Persistent data on SSD (not anon vol!)
    networks: [proxy-net]
    security_opt: ["no-new-privileges:true"]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.portainer.rule=Host(\`portainer.${DOMAIN}\`)"
      - "traefik.http.routers.portainer.entrypoints=websecure"
      - "traefik.http.routers.portainer.tls.certresolver=myresolver"
      - "traefik.http.services.portainer.loadbalancer.server.port=9443"
      - "traefik.http.services.portainer.loadbalancer.server.scheme=https"
networks:
  proxy-net: { external: true }
DCEOF
    docker compose up -d || log_warning "Container(s) may not have started — check with: docker ps"
    log_success "Portainer deployed (9443)"

    ############################################################################
    # 4. NEXTCLOUD — File Storage & Sync (Google Drive / Dropbox alternative)
    #    Uses MariaDB + Redis for performance. Traefik handles HTTPS.
    #    CRITICAL env vars for proxy setup:
    #    - OVERWRITEPROTOCOL=https  (prevents mixed content / redirect loops)
    #    - OVERWRITEHOST            (tells NC its external URL)
    #    - TRUSTED_PROXIES          (allows Traefik to set X-Forwarded headers)
    ############################################################################
    log_info "[4/14] Nextcloud (files + sync)"
    cd "${DOCKER_ROOT}/nextcloud"
    cat > docker-compose.yml << DCEOF
services:
  db:
    image: mariadb:10.11
    container_name: nextcloud-db
    restart: unless-stopped
    command: --transaction-isolation=READ-COMMITTED --binlog-format=ROW --innodb-read-only-compressed=OFF
    volumes:
      - ${DATA_ROOT}/nextcloud-db:/var/lib/mysql
    environment:
      MYSQL_ROOT_PASSWORD: "${MYSQL_ROOT_PASS}"
      MYSQL_PASSWORD: "${NEXTCLOUD_DB_PASS}"
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: nextcloud
    networks: [proxy-net]

  redis:
    image: redis:alpine
    container_name: nextcloud-redis
    restart: unless-stopped
    networks: [proxy-net]

  app:
    image: nextcloud:stable
    container_name: nextcloud
    restart: unless-stopped
    volumes:
      - ${DATA_ROOT}/nextcloud-html:/var/www/html
    environment:
      MYSQL_PASSWORD: "${NEXTCLOUD_DB_PASS}"
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: nextcloud
      MYSQL_HOST: nextcloud-db               # Container name of the DB
      REDIS_HOST: nextcloud-redis            # Container name of Redis
      OVERWRITEPROTOCOL: https               # CRITICAL: prevents redirect loops behind proxy
      OVERWRITEHOST: "nextcloud.${DOMAIN}"   # CRITICAL: tells NC its public URL
      TRUSTED_PROXIES: "172.16.0.0/12 192.168.29.0/24"  # Allow Traefik to forward headers
      NEXTCLOUD_TRUSTED_DOMAINS: "nextcloud.${DOMAIN} ${SERVER_IP}"
      PHP_UPLOAD_LIMIT: 16G                  # Allow large file uploads
      PHP_MEMORY_LIMIT: 1G
    depends_on: [db, redis]
    networks: [proxy-net]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.nextcloud.rule=Host(\`nextcloud.${DOMAIN}\`)"
      - "traefik.http.routers.nextcloud.entrypoints=websecure"
      - "traefik.http.routers.nextcloud.tls.certresolver=myresolver"
      - "traefik.http.services.nextcloud.loadbalancer.server.port=80"
networks:
  proxy-net: { external: true }
DCEOF
    docker compose up -d || log_warning "Container(s) may not have started — check with: docker ps"
    log_success "Nextcloud deployed (nextcloud.${DOMAIN})"

    ############################################################################
    # 5. IMMICH — Photo & Video Management (Google Photos alternative)
    #    Includes: server, machine learning (face/object recognition), DB, Redis.
    #    The ML container downloads models on first start (~1GB).
    ############################################################################
    log_info "[5/14] Immich (photos)"
    cd "${DOCKER_ROOT}/immich"
    cat > docker-compose.yml << DCEOF
services:
  immich-server:
    image: ghcr.io/immich-app/immich-server:release
    container_name: immich-server
    restart: unless-stopped
    ports: ["2283:2283"]
    volumes:
      - ${DATA_ROOT}/immich-upload:/usr/src/app/upload   # Where photos are stored
      - /etc/localtime:/etc/localtime:ro                 # Correct timestamps
    environment:
      DB_HOSTNAME: immich-db
      DB_PASSWORD: "${IMMICH_DB_PASS}"
      DB_USERNAME: postgres
      DB_DATABASE_NAME: immich
      REDIS_HOSTNAME: immich-redis
    depends_on: [immich-db, immich-redis]
    networks: [proxy-net]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.immich.rule=Host(\`photos.${DOMAIN}\`)"
      - "traefik.http.routers.immich.entrypoints=websecure"
      - "traefik.http.routers.immich.tls.certresolver=myresolver"
      - "traefik.http.services.immich.loadbalancer.server.port=2283"

  immich-machine-learning:
    image: ghcr.io/immich-app/immich-machine-learning:release
    container_name: immich-ml
    restart: unless-stopped
    volumes: ["model-cache:/cache"]   # Downloaded ML models cached here
    networks: [proxy-net]

  immich-redis:
    image: redis:alpine
    container_name: immich-redis
    restart: unless-stopped
    networks: [proxy-net]

  immich-db:
    image: tensorchord/pgvecto-rs:pg14-v0.2.0   # Postgres with vector search extension
    container_name: immich-db
    restart: unless-stopped
    environment:
      POSTGRES_PASSWORD: "${IMMICH_DB_PASS}"
      POSTGRES_USER: postgres
      POSTGRES_DB: immich
      POSTGRES_INITDB_ARGS: "--data-checksums"   # Data integrity verification
    volumes:
      - ${DATA_ROOT}/immich-db:/var/lib/postgresql/data
    networks: [proxy-net]

volumes:
  model-cache:    # Named volume for ML model cache (doesn't need backup)
networks:
  proxy-net: { external: true }
DCEOF
    docker compose up -d || log_warning "Container(s) may not have started — check with: docker ps"
    log_success "Immich deployed (2283, photos.${DOMAIN})"

    ############################################################################
    # 6. VAULTWARDEN — Password Manager (Bitwarden-compatible)
    #    Lightweight Rust reimplementation of Bitwarden server.
    #    Uses all Bitwarden clients (mobile, desktop, browser extension).
    #    Admin panel at https://vault.DOMAIN/admin (token-protected).
    ############################################################################
    log_info "[6/14] Vaultwarden (passwords)"
    cd "${DOCKER_ROOT}/vaultwarden"
    cat > docker-compose.yml << DCEOF
services:
  vaultwarden:
    image: vaultwarden/server:latest
    container_name: vaultwarden
    restart: unless-stopped
    volumes:
      - ${DATA_ROOT}/vaultwarden:/data   # Encrypted vault database
    environment:
      DOMAIN: "https://vault.${DOMAIN}"
      ADMIN_TOKEN: "${VAULTWARDEN_ADMIN_TOKEN}"   # Protects /admin panel
      SIGNUPS_ALLOWED: "true"                     # Set false after creating accounts
      LOG_LEVEL: warn
    networks: [proxy-net]
    security_opt: ["no-new-privileges:true"]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.vw.rule=Host(\`vault.${DOMAIN}\`)"
      - "traefik.http.routers.vw.entrypoints=websecure"
      - "traefik.http.routers.vw.tls.certresolver=myresolver"
      - "traefik.http.services.vw.loadbalancer.server.port=80"
networks:
  proxy-net: { external: true }
DCEOF
    docker compose up -d || log_warning "Container(s) may not have started — check with: docker ps"
    log_success "Vaultwarden deployed (vault.${DOMAIN})"

    ############################################################################
    # 7. N8N — Workflow Automation (Zapier alternative)
    #    Runs as user 1000:1000 to avoid permission issues on SSD bind mount.
    #    N8N_PROTOCOL=https and WEBHOOK_URL are required for webhooks to work
    #    correctly behind Traefik reverse proxy.
    ############################################################################
    log_info "[7/14] n8n (automation)"
    cd "${DOCKER_ROOT}/n8n"
    # Ensure data dir exists with correct ownership
    mkdir -p "${DATA_ROOT}/n8n"
    chown -R 1000:1000 "${DATA_ROOT}/n8n"
    cat > docker-compose.yml << DCEOF
services:
  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    ports: ["5678:5678"]
    user: "1000:1000"                     # Match SSD dir ownership (avoids permission errors)
    environment:
      N8N_HOST: "n8n.${DOMAIN}"
      N8N_PORT: "5678"                    # Container listening port
      N8N_PROTOCOL: https                 # Required: tells n8n it's behind HTTPS proxy
      WEBHOOK_URL: "https://n8n.${DOMAIN}"  # Public webhook URL
      N8N_ENCRYPTION_KEY: "${N8N_ENCRYPTION_KEY}"  # Encrypts credentials in DB
      GENERIC_TIMEZONE: "${TIMEZONE}"
    volumes:
      - ${DATA_ROOT}/n8n:/home/node/.n8n  # Workflow data, credentials DB
    networks: [proxy-net]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(\`n8n.${DOMAIN}\`)"
      - "traefik.http.routers.n8n.entrypoints=websecure"
      - "traefik.http.routers.n8n.tls.certresolver=myresolver"
      - "traefik.http.services.n8n.loadbalancer.server.port=5678"
networks:
  proxy-net: { external: true }
DCEOF
    docker compose up -d || log_warning "Container(s) may not have started — check with: docker ps"
    log_success "n8n deployed (5678, n8n.${DOMAIN})"

    ############################################################################
    # 8. TIME MACHINE — macOS Backup Server via SMB
    #    Uses host networking (required for SMB and mDNS/Bonjour discovery).
    #    FIXED v7.1: Env var is PASSWORD (not TM_PASSWORD) for mbentley image.
    #    FIXED v7.1: Data on shared pool (not dedicated partition) for flexibility.
    #    FIXED v7.1: Removed dbus/avahi mounts (caused socket conflicts).
    #    macOS discovers via Bonjour automatically; manual connect also works:
    #      Finder → Go → Connect to Server → smb://SERVER_IP/CoreX_Backup
    ############################################################################
    log_info "[8/14] Time Machine (macOS backups)"
    # Create TM data directory on the shared data pool
    mkdir -p "${MOUNT_POOL}/timemachine-data"
    chown -R 1000:1000 "${MOUNT_POOL}/timemachine-data"
    cd "${DOCKER_ROOT}/timemachine"
    cat > docker-compose.yml << DCEOF
services:
  timemachine:
    image: mbentley/timemachine:smb
    container_name: timemachine
    restart: unless-stopped
    network_mode: host                   # Required for SMB and Bonjour
    environment:
      TM_USERNAME: timemachine
      PASSWORD: "${TM_PASSWORD}"         # NOTE: env var is PASSWORD, not TM_PASSWORD
      TM_UID: "1000"                     # Must match mount point ownership
      TM_GID: "1000"                     # Must match mount point ownership
      SHARE_NAME: CoreX_Backup
      VOLUME_SIZE_LIMIT: "0"             # 0 = use all available space on partition
      SET_PERMISSIONS: "false"
    volumes:
      - ${MOUNT_POOL}/timemachine-data:/opt/timemachine   # Shared data pool (flexible)
volumes: {}
DCEOF
    docker compose up -d || log_warning "Container(s) may not have started — check with: docker ps"
    log_success "Time Machine deployed (SMB:445, smb://${SERVER_IP}/CoreX_Backup)"

    ############################################################################
    # 9. STALWART MAIL — Full Email Server (Gmail alternative)
    #    All-in-one: SMTP, IMAP, CalDAV, CardDAV, WebDAV.
    #    Written in Rust, recommended by Privacy Guides.
    #    Admin UI at mail.DOMAIN:8080 (routed via Traefik).
    #    FIXED: Using official Docker Hub image distribution
    ############################################################################
    log_info "[9/14] Stalwart Mail"
    cd "${DOCKER_ROOT}/stalwart"
    cat > docker-compose.yml << DCEOF
services:
  stalwart:
    image: stalwartlabs/stalwart:latest
    container_name: stalwart
    restart: unless-stopped
    tty: true
    stdin_open: true
    ports:
      - "25:25"      # SMTP (receive mail)
      - "587:587"    # Submission (send mail, STARTTLS)
      - "465:465"    # SMTPS (send mail, implicit TLS)
      - "143:143"    # IMAP (retrieve mail)
      - "993:993"    # IMAPS (retrieve mail, encrypted)
      - "4190:4190"  # ManageSieve (email filtering rules)
    volumes:
      - ${DATA_ROOT}/stalwart-data:/opt/stalwart-mail   # All mail data
    networks: [proxy-net]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.mail.rule=Host(\`mail.${DOMAIN}\`)"
      - "traefik.http.routers.mail.entrypoints=websecure"
      - "traefik.http.routers.mail.tls.certresolver=myresolver"
      - "traefik.http.services.mail.loadbalancer.server.port=8080"
networks:
  proxy-net: { external: true }
DCEOF
    docker compose up -d || log_warning "Container(s) may not have started — check with: docker ps"

    # Stalwart generates its own admin password on first run.
    # Wait for it to boot, then capture the credentials from logs.
    log_info "Waiting for Stalwart to generate admin credentials..."
    sleep 8
    STALWART_ADMIN_PASS=""
    for i in {1..10}; do
        STALWART_ADMIN_PASS=$(docker logs stalwart 2>&1 | grep -oP "password '\K[^']+")
        if [[ -n "$STALWART_ADMIN_PASS" ]]; then
            break
        fi
        sleep 2
    done
    if [[ -n "$STALWART_ADMIN_PASS" ]]; then
        log_success "Stalwart Mail deployed — admin: 'admin' / '$STALWART_ADMIN_PASS'"
    else
        log_warning "Stalwart deployed but could not capture admin password."
        log_warning "Run: docker logs stalwart | grep password"
        STALWART_ADMIN_PASS="(check: docker logs stalwart | grep password)"
    fi

    ############################################################################
    # 10. COOLIFY — Web Hosting PaaS (Vercel/Netlify alternative)
    #     Self-installs its own Docker stack. NOT auto-installed here to
    #     prevent port conflicts. Run the installer manually after setup.
    ############################################################################
    log_info "[10/14] Coolify (installer only)"
    cd "${DOCKER_ROOT}/coolify"
    cat > install.sh << 'CLEOF'
#!/bin/bash
echo "Installing Coolify (self-hosted Vercel/Netlify/Heroku)..."
echo "This installs its own Docker containers and Traefik instance."
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
echo ""
echo "Done! Access at http://YOUR_SERVER_IP:8000"
echo "⚠ Create admin account IMMEDIATELY — first visitor becomes admin!"
CLEOF
    chmod +x install.sh
    log_warning "Coolify: run manually → cd ${DOCKER_ROOT}/coolify && sudo ./install.sh"

    ############################################################################
    # 11. CROWDSEC — Community Intrusion Prevention System
    #     Monitors logs for attack patterns (brute force, CVE exploits, bots).
    #     Shares threat intel with global community — you block known-bad IPs
    #     BEFORE they even attack you. Replaces/supplements Fail2ban.
    ############################################################################
    log_info "[11/14] CrowdSec (IPS)"
    cd "${DOCKER_ROOT}/crowdsec"
    cat > docker-compose.yml << DCEOF
services:
  crowdsec:
    image: crowdsecurity/crowdsec:latest
    container_name: crowdsec
    restart: unless-stopped
    environment:
      # Collections: sets of detection rules for specific services
      COLLECTIONS: "crowdsecurity/linux crowdsecurity/traefik crowdsecurity/http-cve crowdsecurity/sshd"
      TZ: "${TIMEZONE}"
    volumes:
      - ${DATA_ROOT}/crowdsec-db:/var/lib/crowdsec/data      # Threat database
      - ${DATA_ROOT}/crowdsec-config:/etc/crowdsec            # Config files
      - /var/log:/var/log:ro                                  # Read host logs
    networks: [proxy-net]
    security_opt: ["no-new-privileges:true"]
networks:
  proxy-net: { external: true }
DCEOF
    docker compose up -d || log_warning "Container(s) may not have started — check with: docker ps"
    log_success "CrowdSec deployed (community threat intelligence active)"

    ############################################################################
    # 12. MONITORING — Uptime Kuma + Grafana + Prometheus + Node Exporter
    #     Uptime Kuma: status pages + ping/HTTP/TCP monitors
    #     Prometheus: time-series metrics collector
    #     Grafana: dashboards for visualizing metrics
    #     Node Exporter: exposes host CPU/RAM/disk/network metrics
    #     cAdvisor: exposes per-container metrics
    ############################################################################
    log_info "[12/14] Monitoring Stack"
    cd "${DOCKER_ROOT}/monitoring"

    # Fix Prometheus data directory permissions (runs as nobody:nogroup = 65534)
    chown -R 65534:65534 "${DATA_ROOT}/prometheus"

    # Prometheus scrape config
    cat > prometheus.yml << PEOF
global:
  scrape_interval: 30s       # How often to collect metrics

scrape_configs:
  - job_name: node           # Host system metrics (CPU, RAM, disk, network)
    static_configs:
      - targets: ["node-exporter:9100"]
  - job_name: cadvisor       # Per-container metrics
    static_configs:
      - targets: ["cadvisor:8080"]
PEOF

    cat > docker-compose.yml << DCEOF
services:
  uptime-kuma:
    image: louislam/uptime-kuma:latest
    container_name: uptime-kuma
    restart: unless-stopped
    ports: ["3001:3001"]
    volumes:
      - ${DATA_ROOT}/uptime-kuma:/app/data
    networks: [proxy-net, monitoring-net]
    security_opt: ["no-new-privileges:true"]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.uptime.rule=Host(\`status.${DOMAIN}\`)"
      - "traefik.http.routers.uptime.entrypoints=websecure"
      - "traefik.http.routers.uptime.tls.certresolver=myresolver"
      - "traefik.http.services.uptime.loadbalancer.server.port=3001"

  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    restart: unless-stopped
    ports: ["9090:9090"]
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ${DATA_ROOT}/prometheus:/prometheus
    command: ["--config.file=/etc/prometheus/prometheus.yml", "--storage.tsdb.retention.time=30d"]
    networks: [monitoring-net]

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    restart: unless-stopped
    ports: ["3002:3000"]
    volumes:
      - ${DATA_ROOT}/grafana:/var/lib/grafana
    environment:
      GF_SECURITY_ADMIN_PASSWORD: "${GRAFANA_ADMIN_PASS}"
      GF_SERVER_ROOT_URL: "https://grafana.${DOMAIN}"
    networks: [proxy-net, monitoring-net]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.grafana.rule=Host(\`grafana.${DOMAIN}\`)"
      - "traefik.http.routers.grafana.entrypoints=websecure"
      - "traefik.http.routers.grafana.tls.certresolver=myresolver"
      - "traefik.http.services.grafana.loadbalancer.server.port=3000"

  node-exporter:
    image: prom/node-exporter:latest
    container_name: node-exporter
    restart: unless-stopped
    pid: host        # Access host-level process info
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    command: ["--path.procfs=/host/proc", "--path.sysfs=/host/sys", "--path.rootfs=/rootfs"]
    networks: [monitoring-net]

  cadvisor:
    image: gcr.io/cadvisor/cadvisor:latest
    container_name: cadvisor
    restart: unless-stopped
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker:/var/lib/docker:ro
    networks: [monitoring-net]

networks:
  proxy-net: { external: true }
  monitoring-net: { external: true }
DCEOF
    docker compose up -d || log_warning "Container(s) may not have started — check with: docker ps"
    log_success "Monitoring deployed (Kuma:3001, Grafana:3002, Prometheus:9090)"

    ############################################################################
    # 13. CLOUDFLARE TUNNEL — Secure External Access
    #     Creates an encrypted tunnel from Cloudflare's edge to this server.
    #     No port forwarding needed on router. Zero exposed ports to internet.
    #     Uses docker-compose (not raw docker run) for manageability.
    #
    #     CRITICAL: In Cloudflare Dashboard, set Public Hostnames to:
    #       n8n.domain     → HTTP → n8n:5678
    #       photos.domain  → HTTP → immich-server:2283
    #       nextcloud.domain → HTTP → nextcloud:80
    #       vault.domain   → HTTP → vaultwarden:80
    #       etc.
    #     Use CONTAINER NAMES, not localhost! Cloudflared runs inside Docker.
    ############################################################################
    log_info "[13/14] Cloudflare Tunnel"
    cd "${DOCKER_ROOT}/cloudflared"
    docker rm -f cloudflared 2>/dev/null || true   # Clean up any old container

    if [[ "$CLOUDFLARE_TUNNEL_TOKEN" != "PASTE_YOUR_TUNNEL_TOKEN_HERE" ]]; then
        cat > docker-compose.yml << DCEOF
services:
  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared
    restart: unless-stopped
    command: tunnel --no-autoupdate run --token ${CLOUDFLARE_TUNNEL_TOKEN}
    networks: [proxy-net]        # Must be on proxy-net to reach containers by name
    security_opt: ["no-new-privileges:true"]
networks:
  proxy-net: { external: true }
DCEOF
        docker compose up -d || log_warning "Container(s) may not have started — check with: docker ps"
        log_success "Cloudflare Tunnel active"
    else
        log_warning "Cloudflare Tunnel skipped (no token set)"
    fi

    ############################################################################
    # 14. AI STACK — Ollama + Open WebUI + Browserless (Sandboxed)
    #     Ollama: Local LLM inference engine (runs models like Llama, Mistral)
    #     Open WebUI: ChatGPT-like web interface that talks to Ollama
    #     Browserless: Headless Chrome API for AI agents to browse the web
    #     All on ai-net (sandboxed) + proxy-net (for Traefik routing)
    ############################################################################
    log_info "[14/14] AI Stack (Ollama + Open WebUI + Browserless)"
    cd "${DOCKER_ROOT}/ai"
    cat > docker-compose.yml << DCEOF
services:
  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    restart: unless-stopped
    ports: ["11434:11434"]       # Ollama API (LAN only via UFW)
    volumes:
      - ${DATA_ROOT}/ollama:/root/.ollama   # Downloaded models stored here
    networks: [ai-net, proxy-net]
    security_opt: ["no-new-privileges:true"]
    # Uncomment below if you have an NVIDIA GPU:
    # deploy:
    #   resources:
    #     reservations:
    #       devices:
    #         - driver: nvidia
    #           count: all
    #           capabilities: [gpu]

  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    restart: unless-stopped
    ports: ["3003:8080"]
    volumes:
      - ${DATA_ROOT}/open-webui:/app/backend/data   # Chat history, settings
    environment:
      OLLAMA_BASE_URL: "http://ollama:11434"        # Connects to Ollama via Docker network
      WEBUI_SECRET_KEY: "${WEBUI_SECRET_KEY}"
    depends_on: [ollama]
    networks: [ai-net, proxy-net]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.ai.rule=Host(\`ai.${DOMAIN}\`)"
      - "traefik.http.routers.ai.entrypoints=websecure"
      - "traefik.http.routers.ai.tls.certresolver=myresolver"
      - "traefik.http.services.ai.loadbalancer.server.port=8080"

  browserless:
    image: browserless/chrome:latest
    container_name: browserless
    restart: unless-stopped
    ports: ["3005:3000"]         # Headless Chrome API
    environment:
      TOKEN: "${WEBUI_SECRET_KEY}"              # API token for authentication
      MAX_CONCURRENT_SESSIONS: "5"
    networks: [ai-net]
    security_opt: ["no-new-privileges:true"]

networks:
  ai-net: { external: true }
  proxy-net: { external: true }
DCEOF
    docker compose up -d || log_warning "Container(s) may not have started — check with: docker ps"

    # Pull a lightweight model in the background
    log_info "Pulling Llama 3.2 3B model (background download)..."
    sleep 5
    (docker exec ollama ollama pull llama3.2:3b 2>/dev/null || true) &

    # OpenClaw helper script
    cat > setup-openclaw.sh << 'OCEOF'
#!/bin/bash
echo "═══ OpenClaw AI Agent Setup (Docker Sandbox) ═══"
echo ""
echo "OpenClaw runs safely inside Docker. Steps:"
echo "  1. git clone https://github.com/openclaw/openclaw.git"
echo "  2. cd openclaw"
echo "  3. ./docker-setup.sh"
echo ""
echo "When asked for LLM provider, choose Ollama:"
echo "  URL: http://ollama:11434"
echo "  Model: llama3.2:3b (or any model you've pulled)"
echo ""
echo "This gives you a fully LOCAL AI agent — zero API costs."
echo "Docs: https://docs.openclaw.ai/install/docker"
OCEOF
    chmod +x setup-openclaw.sh

    log_success "AI Stack deployed (Ollama:11434, WebUI:3003, Browserless:3005)"
    log_success "═══ All 14 Services Deployed ═══"
}

################################################################################
# PHASE 6: BACKUP SYSTEM (Restic)
# Sets up encrypted, deduplicated, versioned backups of ALL service data.
#
# What gets backed up:
#   - ${DATA_ROOT}   (databases, uploads, configs, vault, mail, photos)
#   - ${DOCKER_ROOT} (all docker-compose.yml files)
#
# What does NOT get backed up (by design):
#   - Docker images/layers (re-pulled on restore via docker compose up)
#   - Time Machine partition (macOS manages its own backups)
#   - Restic repo itself (it IS the backup)
#
# Retention: 7 daily, 4 weekly, 6 monthly snapshots
# Schedule:  Daily at 3:00 AM via cron
#
# RESTORE ON NEW SSD:
#   1. Partition & mount new SSD (same mount points)
#   2. Copy restic-repo folder to new SSD
#   3. Run: sudo corex-restore.sh latest
#   4. All services come back online (docker compose up -d in each dir)
################################################################################

phase6_backup() {
    log_step "═══ PHASE 6: Backup System (Restic) ═══"

    # ── Ensure cron is installed (NOT included in Ubuntu 24 Server minimal) ──
    if ! command -v crontab &>/dev/null; then
        log_info "Installing cron (not present on Ubuntu Server minimal)..."
        apt-get install -y -qq cron
        systemctl enable --now cron
    fi

    # ── Ensure restic is installed (may have been skipped if apt partially failed) ──
    if ! command -v restic &>/dev/null; then
        log_info "Installing restic..."
        apt-get install -y -qq restic || log_error "Failed to install restic."
    fi

    # ── Ensure backup directory exists ──
    mkdir -p "${BACKUP_ROOT}"

    # ── Initialize Restic repository (encrypted with RESTIC_PASSWORD) ──
    export RESTIC_REPOSITORY="${BACKUP_ROOT}/restic-repo"
    export RESTIC_PASSWORD="${RESTIC_PASSWORD}"

    if ! restic cat config &>/dev/null 2>&1; then
        log_info "Initializing Restic backup repository..."
        restic init || log_error "Failed to initialize Restic repository."
        log_success "Restic repo created at ${BACKUP_ROOT}/restic-repo"
    else
        log_success "Restic repo already exists — skipping init."
    fi

    # ── Create backup script ────────────────────────────────────────────────
    cat > /usr/local/bin/corex-backup.sh << BKEOF
#!/bin/bash
# CoreX Pro -- Daily Backup Script
# Runs automatically at 3AM via cron. Can also be run manually.
export RESTIC_REPOSITORY="${BACKUP_ROOT}/restic-repo"
export RESTIC_PASSWORD="${RESTIC_PASSWORD}"
LOG="/var/log/corex-backup.log"

echo "\$(date '+%Y-%m-%d %H:%M:%S') -- Backup starting..." >> "\$LOG"

restic backup "${DATA_ROOT}" "${DOCKER_ROOT}" \
    --tag corex \
    --exclude="*.tmp" \
    --exclude="*.log" \
    --exclude="*/cache/*" \
    >> "\$LOG" 2>&1

restic forget \
    --keep-daily 7 \
    --keep-weekly 4 \
    --keep-monthly 6 \
    --prune \
    >> "\$LOG" 2>&1

echo "\$(date '+%Y-%m-%d %H:%M:%S') -- Backup complete." >> "\$LOG"
BKEOF
    chmod +x /usr/local/bin/corex-backup.sh

    # ── Create restore script ───────────────────────────────────────────────
    cat > /usr/local/bin/corex-restore.sh << RSEOF
#!/bin/bash
# CoreX Pro -- Restore Script
# Usage: sudo corex-restore.sh [snapshot-id]
export RESTIC_REPOSITORY="${BACKUP_ROOT}/restic-repo"
export RESTIC_PASSWORD="${RESTIC_PASSWORD}"

echo ""
echo "=== CoreX Restore ==="
echo ""
echo "Available snapshots:"
restic snapshots
echo ""

SNAP="\${1:-latest}"
echo "Selected: \$SNAP"
read -p "Restore? This OVERWRITES current data. (y/N): " CONFIRM
if [[ "\$CONFIRM" != "y" && "\$CONFIRM" != "Y" ]]; then
    echo "Aborted."
    exit 0
fi

echo "Stopping all Docker containers..."
docker stop \$(docker ps -aq) 2>/dev/null || true

echo "Restoring files..."
restic restore "\$SNAP" --target /

echo "Restarting all services..."
for dir in ${DOCKER_ROOT}/*/; do
    if [[ -f "\$dir/docker-compose.yml" ]]; then
        echo "  Starting \$(basename \$dir)..."
        (cd "\$dir" && docker compose up -d 2>/dev/null) || true
    fi
done

echo ""
echo "Restore complete! Verify with: docker ps"
RSEOF
    chmod +x /usr/local/bin/corex-restore.sh

    # ── Schedule daily backup at 3AM ────────────────────────────────────────
    # Safe crontab update: works even with empty/non-existent crontab.
    # Avoids pipefail crash by using intermediate variables.
    local EXISTING_CRON
    EXISTING_CRON=$(crontab -l 2>/dev/null || true)
    local FILTERED_CRON
    FILTERED_CRON=$(echo "$EXISTING_CRON" | grep -v "corex-backup" || true)
    echo "${FILTERED_CRON}
0 3 * * * /usr/local/bin/corex-backup.sh" | crontab -

    log_success "Backup system ready:"
    log_success "  Auto:    Daily at 3:00 AM"
    log_success "  Manual:  sudo corex-backup.sh"
    log_success "  Restore: sudo corex-restore.sh [snapshot-id]"
}

################################################################################
# PHASE 7: SAVE CREDENTIALS & GENERATE DASHBOARD DOCS
#
# Generates /root/CoreX_Dashboard_Credentials.md — a comprehensive Markdown
# file with every service URL, login credential, admin panel path, and
# step-by-step post-install instructions. Designed to be your single
# reference document for the entire homelab.
#
# On re-runs: Credentials are NOT overwritten (loaded from existing file in
# Phase 0). The docs file IS regenerated every run to stay current.
################################################################################

phase7_summary() {
    log_step "═══ PHASE 7: Save Credentials & Generate Docs ═══"

    # ── Save raw credentials (first run only) ───────────────────────────────
    if [[ ! -f "$CRED_FILE" ]]; then
        cat > "$CRED_FILE" << CREDEOF
MySQL Root:      $MYSQL_ROOT_PASS
Nextcloud DB:    $NEXTCLOUD_DB_PASS
n8n Encryption:  $N8N_ENCRYPTION_KEY
Time Machine:    $TM_PASSWORD
Vaultwarden:     $VAULTWARDEN_ADMIN_TOKEN
Grafana Admin:   $GRAFANA_ADMIN_PASS
Restic Backup:   $RESTIC_PASSWORD
Immich DB:       $IMMICH_DB_PASS
AI WebUI Secret: $WEBUI_SECRET_KEY
Stalwart Admin:  admin / $STALWART_ADMIN_PASS
CREDEOF
        chmod 600 "$CRED_FILE"
        log_success "Raw credentials saved to $CRED_FILE"
    fi

    # ── Generate comprehensive Markdown docs ────────────────────────────────
    cat > "$DOCS_FILE" << DOCSEOF
# 🏠 CoreX Pro v7.0 — Dashboard & Credentials

> **Generated:** $(date '+%A, %B %d, %Y at %I:%M %p %Z')
> **Server IP:** \`${SERVER_IP}\`
> **Domain:** \`${DOMAIN}\`
> **SSH Port:** \`${SSH_PORT}\`

---

## 🔑 Service Credentials

| Service | Admin URL | Username | Password / Token |
|---------|-----------|----------|-----------------|
| **Nextcloud** | \`https://nextcloud.${DOMAIN}\` | *(create on first visit)* | *(you choose)* |
| **Nextcloud DB** | *(internal)* | \`nextcloud\` | \`${NEXTCLOUD_DB_PASS}\` |
| **MySQL Root** | *(internal)* | \`root\` | \`${MYSQL_ROOT_PASS}\` |
| **Immich** | \`https://photos.${DOMAIN}\` | *(create on first visit)* | *(you choose)* |
| **Immich DB** | *(internal)* | \`postgres\` | \`${IMMICH_DB_PASS}\` |
| **Vaultwarden** | \`https://vault.${DOMAIN}\` | *(create on first visit)* | *(you choose)* |
| **Vaultwarden Admin** | \`https://vault.${DOMAIN}/admin\` | *(token-based)* | \`${VAULTWARDEN_ADMIN_TOKEN}\` |
| **n8n** | \`https://n8n.${DOMAIN}\` | *(create on first visit)* | *(you choose)* |
| **n8n Encryption Key** | *(internal)* | — | \`${N8N_ENCRYPTION_KEY}\` |
| **Grafana** | \`https://grafana.${DOMAIN}\` | \`admin\` | \`${GRAFANA_ADMIN_PASS}\` |
| **Portainer** | \`https://${SERVER_IP}:9443\` | *(create on first visit)* | *(you choose)* |
| **Stalwart Mail** | \`https://mail.${DOMAIN}\` | \`admin\` | \`${STALWART_ADMIN_PASS}\` |
| **Uptime Kuma** | \`https://status.${DOMAIN}\` | *(create on first visit)* | *(you choose)* |
| **Open WebUI** | \`https://ai.${DOMAIN}\` | *(create on first visit)* | *(you choose)* |
| **Time Machine** | \`smb://${SERVER_IP}/CoreX_Backup\` | \`timemachine\` | \`${TM_PASSWORD}\` |
| **Restic Backup** | *(CLI only)* | — | \`${RESTIC_PASSWORD}\` |
| **AI WebUI Secret** | *(internal)* | — | \`${WEBUI_SECRET_KEY}\` |
| **AdGuard Home** | \`http://${SERVER_IP}:3000\` | *(create during setup)* | *(you choose)* |
| **Traefik Dashboard** | \`http://${SERVER_IP}:8080\` | *(no auth)* | *(no auth)* |

> ⚠️ **"Create on first visit"** means the first person to open the URL becomes admin.
> Complete setup for Portainer, Nextcloud, Immich, n8n, and Uptime Kuma **immediately** after install.

---

## 🌐 Service Access URLs

### Local Network (LAN)
*These work when your router DNS points to ${SERVER_IP} and AdGuard has DNS rewrites configured.*

| Service | URL | Direct IP Fallback |
|---------|-----|--------------------|
| Traefik Dashboard | \`http://${SERVER_IP}:8080\` | same |
| AdGuard Home | \`http://${SERVER_IP}:3000\` | same |
| Portainer | \`https://${SERVER_IP}:9443\` | same |
| Nextcloud | \`https://nextcloud.${DOMAIN}\` | — |
| Immich (Photos) | \`https://photos.${DOMAIN}\` | \`http://${SERVER_IP}:2283\` |
| Vaultwarden | \`https://vault.${DOMAIN}\` | — |
| n8n | \`https://n8n.${DOMAIN}\` | \`http://${SERVER_IP}:5678\` |
| Stalwart Mail | \`https://mail.${DOMAIN}\` | — |
| Uptime Kuma | \`https://status.${DOMAIN}\` | \`http://${SERVER_IP}:3001\` |
| Grafana | \`https://grafana.${DOMAIN}\` | \`http://${SERVER_IP}:3002\` |
| Open WebUI (AI) | \`https://ai.${DOMAIN}\` | \`http://${SERVER_IP}:3003\` |
| Ollama API | \`http://${SERVER_IP}:11434\` | same |
| Browserless | \`http://${SERVER_IP}:3005\` | same |
| Time Machine | \`smb://${SERVER_IP}/CoreX_Backup\` | same |
| Coolify | \`http://${SERVER_IP}:8000\` | same |

### External Access (via Cloudflare Tunnel)
*These work from anywhere on the internet.*

| Service | Public URL |
|---------|-----------|
| Nextcloud | \`https://nextcloud.${DOMAIN}\` |
| Immich | \`https://photos.${DOMAIN}\` |
| Vaultwarden | \`https://vault.${DOMAIN}\` |
| n8n | \`https://n8n.${DOMAIN}\` |
| Stalwart Mail | \`https://mail.${DOMAIN}\` |
| Uptime Kuma | \`https://status.${DOMAIN}\` |
| Grafana | \`https://grafana.${DOMAIN}\` |
| Open WebUI | \`https://ai.${DOMAIN}\` |

---

## 🛡️ Security Summary

| Layer | Tool | Status |
|-------|------|--------|
| Firewall | UFW | Active — default deny, per-port allow |
| SSH | Port \`${SSH_PORT}\`, root disabled, max 3 attempts | Hardened |
| Brute Force | Fail2ban | 3 failures → 24hr ban |
| IPS | CrowdSec | Community threat intel active |
| Kernel | sysctl hardening | Anti-spoof, SYN flood protection |
| Updates | unattended-upgrades | Auto security patches daily |
| Containers | no-new-privileges | Privilege escalation blocked |

---

## 💾 Storage Layout

| Mount | Path | Size | Purpose |
|-------|------|------|---------|
| Time Machine | \`${MOUNT_TM}\` | 400 GB | macOS backups (dedicated partition) |
| Data Pool | \`${MOUNT_POOL}\` | ~600 GB | All service data, configs, backups |
| Local Disk | \`/\` | OS disk | Ubuntu OS + Docker Engine only |

### Data Pool Structure
\`\`\`
${MOUNT_POOL}/
├── docker-configs/    ← docker-compose.yml per service
│   ├── traefik/
│   ├── nextcloud/
│   ├── immich/
│   ├── ...
├── service-data/      ← Persistent data (DBs, uploads, mail)
│   ├── nextcloud-html/
│   ├── immich-upload/
│   ├── vaultwarden/
│   ├── ollama/
│   ├── ...
└── backups/           ← Restic encrypted repository
    └── restic-repo/
\`\`\`

---

## 📋 Post-Install Setup Guide

### Step 1: AdGuard Home (DNS — do this FIRST)

This makes all \`*.${DOMAIN}\` URLs work on your local network without hitting Cloudflare.

1. Open **\`http://${SERVER_IP}:3000\`** in your browser
2. Complete the setup wizard:
   - Listen on all interfaces, port 53
   - Set admin username and password *(save these!)*
3. Go to **Filters → DNS Rewrites** and add:
   | Domain | Answer |
   |--------|--------|
   | \`*.${DOMAIN}\` | \`${SERVER_IP}\` |
   | \`${DOMAIN}\` | \`${SERVER_IP}\` |
4. Go to your **router settings** → DNS → set primary DNS to \`${SERVER_IP}\`
5. Test: \`nslookup nextcloud.${DOMAIN}\` should return \`${SERVER_IP}\`

### Step 2: Cloudflare Tunnel (External Access)

This allows access from outside your home network (phone on cellular, travel, etc.)

1. Go to **\`https://one.dash.cloudflare.com\`**
2. Navigate to **Networks → Tunnels → your tunnel → Public Hostnames**
3. Add these hostnames:

| Public Hostname | Service Type | URL |
|-----------------|-------------|-----|
| \`n8n.${DOMAIN}\` | HTTP | \`n8n:5678\` |
| \`photos.${DOMAIN}\` | HTTP | \`immich-server:2283\` |
| \`nextcloud.${DOMAIN}\` | HTTP | \`nextcloud:80\` |
| \`vault.${DOMAIN}\` | HTTP | \`vaultwarden:80\` |
| \`mail.${DOMAIN}\` | HTTP | \`stalwart:8080\` |
| \`status.${DOMAIN}\` | HTTP | \`uptime-kuma:3001\` |
| \`grafana.${DOMAIN}\` | HTTP | \`grafana:3000\` |
| \`ai.${DOMAIN}\` | HTTP | \`open-webui:8080\` |

> ⚠️ **Use container names, NOT \`localhost\`!** Cloudflared runs inside Docker on \`proxy-net\`.
> For each hostname → Additional Settings → TLS → enable **"No TLS Verify"**

### Step 3: Portainer (Docker Management)

1. Open **\`https://${SERVER_IP}:9443\`** immediately (browser will warn about self-signed cert — proceed)
2. Create admin username + password on first visit
3. Select "Docker Standalone" → Connect
4. You can now manage all containers, view logs, restart services from the UI

### Step 4: Nextcloud (Files & Sync)

1. Open **\`https://nextcloud.${DOMAIN}\`**
2. Create admin account on first visit
3. Download apps: [Nextcloud Desktop](https://nextcloud.com/install/#install-clients) / iOS / Android
4. **Recommended:** Install these Nextcloud apps from the admin panel:
   - Calendar, Contacts, Notes, Talk (video calls), Deck (kanban)

### Step 5: Immich (Photos)

1. Open **\`https://photos.${DOMAIN}\`**
2. Create admin account
3. Download the Immich app: [iOS](https://apps.apple.com/app/immich/id1613945652) / [Android](https://play.google.com/store/apps/details?id=app.alextran.immich)
4. In the app: Server URL → \`https://photos.${DOMAIN}\`
5. Enable **Auto Backup** in app settings → your photos sync automatically
6. Face recognition and smart search activate after ML container processes your library

### Step 6: Vaultwarden (Passwords)

1. Open **\`https://vault.${DOMAIN}\`** → Register a new account
2. Download Bitwarden apps: [Browser Extension](https://bitwarden.com/download/) / iOS / Android
3. In each app: Settings → Self-hosted → Server URL: \`https://vault.${DOMAIN}\`
4. **Admin panel:** \`https://vault.${DOMAIN}/admin\` → enter token: \`${VAULTWARDEN_ADMIN_TOKEN}\`
5. After creating your accounts, set \`SIGNUPS_ALLOWED: "false"\` in docker-compose.yml

### Step 7: n8n (Workflow Automation)

1. Open **\`https://n8n.${DOMAIN}\`**
2. Create owner account
3. Start building workflows: Webhooks, Cron triggers, API integrations
4. Useful starter workflows: RSS to email, backup notifications, monitoring alerts

### Step 8: Time Machine (macOS Backups)

1. On your Mac: **System Settings → General → Time Machine → Add Backup Disk**
2. Select **\`CoreX_Backup\`** from the network shares list
3. Credentials:
   - Username: \`timemachine\`
   - Password: \`${TM_PASSWORD}\`
4. Backups run automatically every hour
5. If the share doesn't appear, try: Finder → Go → Connect to Server → \`smb://${SERVER_IP}/CoreX_Backup\`

### Step 9: Stalwart Mail (Email Server)

1. Open **\`https://mail.${DOMAIN}\`**
2. Login with auto-generated credentials:
   - Username: \`admin\`
   - Password: \`${STALWART_ADMIN_PASS}\`
3. **Change the admin password immediately** in Settings → Account → Password
4. **DNS Records** (add in Cloudflare DNS):
   | Type | Name | Value |
   |------|------|-------|
   | MX | \`${DOMAIN}\` | \`mail.${DOMAIN}\` (priority 10) |
   | TXT | \`${DOMAIN}\` | \`v=spf1 mx ~all\` |
   | TXT | \`_dmarc.${DOMAIN}\` | \`v=DMARC1; p=quarantine; rua=mailto:admin@${DOMAIN}\` |
   | CNAME | \`_dkim.${DOMAIN}\` | *(get from Stalwart admin → DKIM settings)* |
5. **Tip:** For better deliverability, set up an SMTP relay (e.g., SMTP2GO free tier)

### Step 10: Grafana (Dashboards)

1. Open **\`https://grafana.${DOMAIN}\`**
2. Login: username \`admin\` / password \`${GRAFANA_ADMIN_PASS}\`
3. Go to **Connections → Data Sources → Add → Prometheus**
4. URL: \`http://prometheus:9090\` → Save & Test
5. Go to **Dashboards → Import** → try ID \`1860\` (Node Exporter Full) for system metrics

### Step 11: Uptime Kuma (Status Monitoring)

1. Open **\`https://status.${DOMAIN}\`** → Create admin account
2. Add monitors for each service:
   | Name | Type | URL |
   |------|------|-----|
   | Nextcloud | HTTP(s) | \`https://nextcloud.${DOMAIN}\` |
   | Immich | HTTP(s) | \`http://immich-server:2283\` |
   | Vaultwarden | HTTP(s) | \`http://vaultwarden:80\` |
   | n8n | HTTP(s) | \`http://n8n:5678\` |
   | Ollama | HTTP(s) | \`http://ollama:11434\` |
   | Mail | TCP | \`stalwart:993\` |
3. Create a **Status Page** → share the public URL with your team

### Step 12: Open WebUI (AI Chat)

1. Open **\`https://ai.${DOMAIN}\`** → Create account (first user = admin)
2. Select model: \`llama3.2:3b\` should already be available
3. To download more models: Settings → Models → pull from Ollama library
4. Recommended models:
   - \`llama3.2:3b\` — fast, good for chat (3GB)
   - \`mistral:7b\` — balanced quality/speed (7GB)
   - \`codellama:7b\` — coding assistant (7GB)

### Step 13: Coolify (Web Hosting)

1. SSH into server: \`ssh -p ${SSH_PORT} user@${SERVER_IP}\`
2. Run: \`cd ${DOCKER_ROOT}/coolify && sudo ./install.sh\`
3. Open **\`http://${SERVER_IP}:8000\`** → Create admin account immediately
4. Connect your GitHub/GitLab for automatic deployments
5. Deploy Laravel, Next.js, static sites with one click

### Step 14: SSH Key Setup (Lock Down SSH)

\`\`\`bash
# From your LOCAL machine (Mac/PC), NOT the server:
ssh-copy-id -p ${SSH_PORT} your_username@${SERVER_IP}

# Test key login works:
ssh -p ${SSH_PORT} your_username@${SERVER_IP}

# If it works, disable password auth on the SERVER:
sudo sed -i 's/^#\\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo systemctl restart sshd
\`\`\`

---

## 🔄 Backup & Restore

### Daily Automatic Backup
Runs every day at **3:00 AM** via cron. Backs up all service data + configs.

### Manual Commands
\`\`\`bash
# Run a backup now
sudo corex-backup.sh

# List all snapshots
sudo RESTIC_REPOSITORY=${BACKUP_ROOT}/restic-repo RESTIC_PASSWORD='${RESTIC_PASSWORD}' restic snapshots

# Restore latest snapshot (stops containers, restores, restarts)
sudo corex-restore.sh

# Restore a specific snapshot
sudo corex-restore.sh abc123ef
\`\`\`

### Migrate to New SSD
\`\`\`bash
# 1. Partition and mount new SSD with same mount points
# 2. Copy backup repo:
rsync -avP ${BACKUP_ROOT}/restic-repo/ /new-ssd/backups/restic-repo/
# 3. Restore:
sudo corex-restore.sh latest
# 4. Everything comes back online ✨
\`\`\`

---

## 🛠️ Useful Commands

\`\`\`bash
# Check all running containers
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# Restart a specific service
cd ${DOCKER_ROOT}/nextcloud && docker compose restart

# View logs for a service
docker logs -f --tail 50 nextcloud

# Check CrowdSec decisions (blocked IPs)
docker exec crowdsec cscli decisions list

# Check CrowdSec metrics
docker exec crowdsec cscli metrics

# Check Fail2ban status
sudo fail2ban-client status sshd

# Check UFW rules
sudo ufw status numbered

# Disk usage on SSD
df -h ${MOUNT_TM} ${MOUNT_POOL}

# Check backup log
tail -20 /var/log/corex-backup.log

# Update all containers
for dir in ${DOCKER_ROOT}/*/; do
  if [[ -f "\$dir/docker-compose.yml" ]]; then
    echo "Updating \$(basename \$dir)..."
    (cd "\$dir" && docker compose pull && docker compose up -d)
  fi
done
\`\`\`

---

## 📁 File Locations

| What | Path |
|------|------|
| This document | \`${DOCS_FILE}\` |
| Raw credentials | \`${CRED_FILE}\` |
| Service compose files | \`${DOCKER_ROOT}/<service>/docker-compose.yml\` |
| Service data | \`${DATA_ROOT}/<service>/\` |
| Backup repository | \`${BACKUP_ROOT}/restic-repo/\` |
| Backup script | \`/usr/local/bin/corex-backup.sh\` |
| Restore script | \`/usr/local/bin/corex-restore.sh\` |
| Backup log | \`/var/log/corex-backup.log\` |
| SSH config | \`/etc/ssh/sshd_config\` |
| UFW rules | \`/etc/ufw/\` |
| Fail2ban config | \`/etc/fail2ban/jail.local\` |
| Kernel hardening | \`/etc/sysctl.d/99-corex.conf\` |

---

*CoreX Pro v7.0 — Own your data. Own your stack. 🏴*
DOCSEOF

    chmod 600 "$DOCS_FILE"
    log_success "Dashboard docs saved to $DOCS_FILE"

    # ── Print summary to terminal ───────────────────────────────────────────
    clear
    echo ""
    echo -e "${GREEN}${BOLD}"
    echo "  ╔══════════════════════════════════════════════════════════════╗"
    echo "  ║        CoreX Pro v7.0 — Installation Complete! 🎉          ║"
    echo "  ╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    echo -e "  ${CYAN}QUICK ACCESS${NC}"
    echo "  ──────────────────────────────────────────────────────────────"
    printf "  %-22s %s\n" "Traefik" "http://${SERVER_IP}:8080"
    printf "  %-22s %s\n" "AdGuard Home" "http://${SERVER_IP}:3000  ← SETUP FIRST!"
    printf "  %-22s %s\n" "Portainer" "https://${SERVER_IP}:9443"
    printf "  %-22s %s\n" "Nextcloud" "https://nextcloud.${DOMAIN}"
    printf "  %-22s %s\n" "Photos (Immich)" "https://photos.${DOMAIN}"
    printf "  %-22s %s\n" "Passwords (Vault)" "https://vault.${DOMAIN}"
    printf "  %-22s %s\n" "n8n Automation" "https://n8n.${DOMAIN}"
    printf "  %-22s %s\n" "Mail Server" "https://mail.${DOMAIN}"
    printf "  %-22s %s\n" "Status Page" "https://status.${DOMAIN}"
    printf "  %-22s %s\n" "Grafana" "https://grafana.${DOMAIN}"
    printf "  %-22s %s\n" "AI Chat" "https://ai.${DOMAIN}"
    printf "  %-22s %s\n" "Time Machine" "smb://${SERVER_IP}/CoreX_Backup"
    printf "  %-22s %s\n" "Coolify" "http://${SERVER_IP}:8000  ← RUN INSTALL"
    echo ""

    echo -e "  ${YELLOW}${BOLD}READ THE FULL GUIDE:${NC}"
    echo "    cat $DOCS_FILE"
    echo ""
    echo -e "  ${YELLOW}${BOLD}VIEW PASSWORDS:${NC}"
    echo "    cat $CRED_FILE"
    echo ""
    echo -e "  ${YELLOW}${BOLD}FIRST 3 THINGS TO DO:${NC}"
    echo "    1. AdGuard: http://${SERVER_IP}:3000 → setup → DNS Rewrites *.${DOMAIN} → ${SERVER_IP}"
    echo "    2. Cloudflare Tunnel: set public hostnames (see docs for exact mapping)"
    echo "    3. Create admin accounts on Portainer, Nextcloud, Immich, Vaultwarden"
    echo ""
    echo -e "  ${GREEN}All data on SSD. You're sovereign. 🏴${NC}"
    echo ""
}

################################################################################
# MAIN EXECUTION
# Runs all phases in order. Safe to re-run (idempotent password loading,
# skip-format option for drive, docker network create is no-op if exists).
################################################################################

main() {
    check_root
    phase0_precheck    # Verify internet, RAM, generate/load passwords
    phase1_drive       # Partition & mount external SSD
    phase2_security    # SSH, Fail2ban, CrowdSec, kernel, UFW
    phase3_docker      # Install Docker, create networks
    phase4_directories # Create directory structure on SSD
    phase5_deploy      # Deploy all 14 services
    phase6_backup      # Restic backup system + cron
    phase7_summary     # Save credentials, print dashboard
}

main "$@"