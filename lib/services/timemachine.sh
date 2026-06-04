#!/bin/bash
# lib/services/timemachine.sh — CoreX Pro v2
# Time Machine — macOS Backup Server via high-performance SMB3
#
# CRITICAL NOTES:
#   - Uses host networking (required for SMB and mDNS/Bonjour discovery)
#   - CANNOT be behind Traefik (host networking incompatible with Docker networks)
#   - Env var is PASSWORD (not TM_PASSWORD) for mbentley/timemachine image
#   - Data stored on corex-data pool (not dedicated partition) for flexibility
#   - macOS discovers via Bonjour automatically; manual: smb://SERVER_IP/CoreX_Backup
#   - Custom smb.conf overlay enables SMB3 multichannel + large MTU for Gbps transfers

# ── Metadata ──────────────────────────────────────────────────────────────────
SERVICE_NAME="timemachine"
SERVICE_LABEL="Time Machine — macOS Backup Server (High-Speed SMB3)"
SERVICE_CATEGORY="backup"
SERVICE_REQUIRED=false
SERVICE_NEEDS_DOMAIN=false
SERVICE_NEEDS_EMAIL=false
SERVICE_RAM_MB=256
SERVICE_DISK_GB=0
SERVICE_DESCRIPTION="macOS Time Machine backup server over high-performance SMB3. Multi-gigabit LAN transfers with multichannel support. Your Mac backs up automatically over Wi-Fi."

# ── Functions ─────────────────────────────────────────────────────────────────

timemachine_dirs() {
    mkdir -p "${DOCKER_ROOT}/timemachine"
    mkdir -p "${MOUNT_POOL}/timemachine-data"
    chown -R 1000:1000 "${MOUNT_POOL}/timemachine-data"
}

timemachine_firewall() {
    # SMB and NetBIOS — LAN only (restrict to local subnet)
    local lan_subnet="${SERVER_IP%.*}.0/24"
    ufw allow from "$lan_subnet" to any port 445 proto tcp   comment 'SMB (Time Machine)' 2>/dev/null || true
    ufw allow from "$lan_subnet" to any port 137:139 proto tcp comment 'NetBIOS (Time Machine)' 2>/dev/null || true
    ufw allow 5353/udp comment 'mDNS (Bonjour/Avahi discovery)' 2>/dev/null || true
}

timemachine_deploy() {
    timemachine_dirs
    local dir="${DOCKER_ROOT}/timemachine"

    # ── High-performance SMB3 configuration ──────────────────────────────────
    # This overlay is bind-mounted into the container and merged with the
    # default smb.conf. It enables SMB3 multichannel, large read/write sizes,
    # and async I/O for multi-gigabit LAN transfer speeds.
    cat > "${dir}/smb-performance.conf" << 'SMBEOF'
[global]
# ── Protocol: force SMB3 minimum (disables insecure SMB1/SMB2) ───────────────
server min protocol = SMB3_00
client min protocol = SMB3_00

# ── Multichannel: use all available NICs simultaneously ──────────────────────
server multi channel support = yes

# ── I/O performance: large buffers + async operations ────────────────────────
# max xmit = max read/write chunk size per SMB request (8MB)
# These directly control throughput per TCP stream
socket options = TCP_NODELAY IPTOS_LOWDELAY SO_RCVBUF=2097152 SO_SNDBUF=2097152
read raw = yes
write raw = yes
max xmit = 8388608
getwd cache = yes
use sendfile = yes
aio read size = 1
aio write size = 1
min receivefile size = 16384

# ── Caching + oplocks (let client cache aggressively) ────────────────────────
oplocks = yes
level2 oplocks = yes
kernel oplocks = no
strict locking = no

# ── Security: signing optional on LAN (performance), required on WAN ─────────
server signing = default
client signing = default

# ── Logging: minimal to avoid I/O overhead ───────────────────────────────────
log level = 1
SMBEOF

    cat > "${dir}/docker-compose.yml" << DCEOF
services:
  timemachine:
    image: mbentley/timemachine:smb
    container_name: timemachine
    restart: unless-stopped
    network_mode: host
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    environment:
      TM_USERNAME: timemachine
      PASSWORD: "${TM_PASSWORD}"
      TM_UID: "1000"
      TM_GID: "1000"
      SHARE_NAME: CoreX_Backup
      VOLUME_SIZE_LIMIT: "0"
      SET_PERMISSIONS: "false"
      CUSTOM_SMB_CONF: "true"
      SMB_INHERIT_PERMISSIONS: "no"
    volumes:
      - ${MOUNT_POOL}/timemachine-data:/opt/timemachine
      - ${DOCKER_ROOT}/timemachine/smb-performance.conf:/etc/samba/smb-performance.conf:ro
volumes: {}
DCEOF

    docker compose -f "${dir}/docker-compose.yml" up -d \
        || log_warning "Time Machine may not have started — check: docker ps"
    state_service_installed "timemachine"
    log_success "Time Machine deployed (high-perf SMB3:445, smb://${SERVER_IP}/CoreX_Backup)"
}

timemachine_destroy() {
    local dir="${DOCKER_ROOT}/timemachine"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" down
    state_service_removed "timemachine"
}

timemachine_status() {
    if container_running "timemachine"; then echo "HEALTHY"
    elif container_exists "timemachine"; then echo "UNHEALTHY"
    else echo "MISSING"; fi
}

timemachine_repair() {
    local dir="${DOCKER_ROOT}/timemachine"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" up -d --force-recreate
}

timemachine_credentials() {
    echo "Time Machine: smb://${SERVER_IP}/CoreX_Backup"
    echo "  Username: timemachine"
    echo "  Password: ${TM_PASSWORD}"
}
