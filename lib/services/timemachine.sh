#!/bin/bash
# lib/services/timemachine.sh — CoreX Pro v2
# Time Machine — macOS Backup Server via SMB
#
# CRITICAL NOTES:
#   - Uses host networking (required for SMB and mDNS/Bonjour discovery)
#   - CANNOT be behind Traefik (host networking incompatible with Docker networks)
#   - Env var is PASSWORD (not TM_PASSWORD) for mbentley/timemachine image
#   - Data stored on corex-data pool (not dedicated partition) for flexibility
#   - macOS discovers via Bonjour automatically; manual: smb://SERVER_IP/CoreX_Backup

# ── Metadata ──────────────────────────────────────────────────────────────────
SERVICE_NAME="timemachine"
SERVICE_LABEL="Time Machine — macOS Backup Server (SMB)"
SERVICE_CATEGORY="backup"
SERVICE_REQUIRED=false
SERVICE_NEEDS_DOMAIN=false
SERVICE_NEEDS_EMAIL=false
SERVICE_RAM_MB=256
SERVICE_DISK_GB=0
SERVICE_DESCRIPTION="macOS Time Machine backup server over SMB. Your Mac backs up automatically over Wi-Fi. Requires a Mac on the same network."

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

    cat > "${dir}/docker-compose.yml" << DCEOF
services:
  timemachine:
    image: mbentley/timemachine:smb
    container_name: timemachine
    restart: unless-stopped
    network_mode: host
    environment:
      TM_USERNAME: timemachine
      PASSWORD: "${TM_PASSWORD}"
      TM_UID: "1000"
      TM_GID: "1000"
      SHARE_NAME: CoreX_Backup
      VOLUME_SIZE_LIMIT: "0"
      SET_PERMISSIONS: "false"
    volumes:
      - ${MOUNT_POOL}/timemachine-data:/opt/timemachine
volumes: {}
DCEOF

    docker compose -f "${dir}/docker-compose.yml" up -d \
        || log_warning "Time Machine may not have started — check: docker ps"
    state_service_installed "timemachine"
    log_success "Time Machine deployed (SMB:445, smb://${SERVER_IP}/CoreX_Backup)"
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
