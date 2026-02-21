#!/bin/bash
# lib/services/adguard.sh — CoreX Pro v2
# AdGuard Home — DNS Server & Ad Blocker
#
# CRITICAL NOTES:
#   - FIRST RUN: wizard listens on port 3000 inside container
#   - AFTER SETUP: switches to port 80 inside container (or configured port)
#   - We detect which state we're in from AdGuardHome.yaml
#   - systemd-resolved MUST be disabled; resolv.conf locked with chattr +i
#   - After setup: add DNS rewrites *.domain → SERVER_IP in AdGuard UI

# ── Metadata ──────────────────────────────────────────────────────────────────
SERVICE_NAME="adguard"
SERVICE_LABEL="AdGuard Home — DNS & Ad Blocker"
SERVICE_CATEGORY="core"
SERVICE_REQUIRED=true
SERVICE_NEEDS_DOMAIN=false
SERVICE_NEEDS_EMAIL=false
SERVICE_RAM_MB=64
SERVICE_DISK_GB=1
SERVICE_DESCRIPTION="Network-wide ad blocker and DNS server. Blocks ads on all devices. Required for local domain routing (*.yourdomain → server IP)."

# ── Functions ─────────────────────────────────────────────────────────────────

adguard_dirs() {
    mkdir -p "${DOCKER_ROOT}/adguard"
    mkdir -p "${DATA_ROOT}/adguard-work" "${DATA_ROOT}/adguard-conf"
}

adguard_firewall() {
    ufw allow 53    comment 'DNS (AdGuard Home, TCP+UDP)'    2>/dev/null || true
    ufw allow 3000/tcp comment 'AdGuard Home Setup UI'       2>/dev/null || true
    ufw allow 5353/udp comment 'mDNS (Avahi/Bonjour)'       2>/dev/null || true
}

adguard_deploy() {
    mkdir -p "${DOCKER_ROOT}/adguard"
    mkdir -p "${DATA_ROOT}/adguard-work" "${DATA_ROOT}/adguard-conf"
    local dir="${DOCKER_ROOT}/adguard"

    # Disable systemd-resolved which holds port 53
    systemctl disable --now systemd-resolved 2>/dev/null || true
    rm -f /etc/resolv.conf
    printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /etc/resolv.conf
    # Lock so systemd can't overwrite on reboot
    chattr +i /etc/resolv.conf 2>/dev/null || true

    # Detect if AdGuard has already been configured (setup wizard completed)
    local ADGUARD_INTERNAL_PORT="3000"
    if [[ -f "${DATA_ROOT}/adguard-conf/AdGuardHome.yaml" ]]; then
        local CONFIGURED_PORT
        CONFIGURED_PORT=$(grep -A5 "http:" "${DATA_ROOT}/adguard-conf/AdGuardHome.yaml" \
            | grep "address:" | grep -oP ':\K[0-9]+' | head -1)
        if [[ -n "$CONFIGURED_PORT" ]]; then
            ADGUARD_INTERNAL_PORT="$CONFIGURED_PORT"
            log_info "AdGuard already configured — internal port is $ADGUARD_INTERNAL_PORT"
        fi
    else
        log_info "AdGuard first run — wizard will listen on port 3000"
    fi

    cat > "${dir}/docker-compose.yml" << DCEOF
services:
  adguard:
    image: adguard/adguardhome:latest
    container_name: adguard
    restart: unless-stopped
    ports:
      - "53:53/tcp"
      - "53:53/udp"
      - "3000:${ADGUARD_INTERNAL_PORT}/tcp"
    volumes:
      - ${DATA_ROOT}/adguard-work:/opt/adguardhome/work
      - ${DATA_ROOT}/adguard-conf:/opt/adguardhome/conf
    networks: [proxy-net]
networks:
  proxy-net: { external: true }
DCEOF

    docker compose -f "${dir}/docker-compose.yml" up -d \
        || log_warning "AdGuard may not have started — check: docker ps"
    state_service_installed "adguard"
    log_success "AdGuard Home deployed (DNS:53, Admin:3000)"
}

adguard_destroy() {
    local dir="${DOCKER_ROOT}/adguard"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" down
    state_service_removed "adguard"
}

adguard_status() {
    if container_running "adguard"; then echo "HEALTHY"
    elif container_exists "adguard"; then echo "UNHEALTHY"
    else echo "MISSING"; fi
}

adguard_repair() {
    local dir="${DOCKER_ROOT}/adguard"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" up -d --force-recreate
}

adguard_credentials() {
    echo "AdGuard Home: http://${SERVER_IP}:3000 (set during wizard)"
}
