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
# UFW rules this service opens, as full `ufw allow` specs. cmd_remove
# revokes them, because leaving a port open with nothing behind it is all
# of the exposure and none of the service.
SERVICE_FIREWALL_SPECS=("53" "3000/tcp" "5353/udp")
SERVICE_DESCRIPTION="Network-wide ad blocker and DNS server. Blocks ads on all devices. Required for local domain routing (*.yourdomain → server IP)."

# Uptime Kuma check, seeded by lib/kuma.sh so it is recreated on a fresh
# install rather than living only in Kuma's database. Tab separated:
# name, url, accepted status codes. The name is the key, so changing it
# creates a second monitor and orphans the first.
SERVICE_MONITORS="AdGuard Home	http://${SERVER_IP:-}:3000	[\"200-299\",\"302\"]"

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
    deploy:
      resources:
        limits:
          memory: 256m
          cpus: "0.5"
        reservations:
          memory: 64m
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
    # Regenerate the compose file first. Without this, repair recreated the
    # container from a compose file that could be months old, so CoreX fixes
    # to env vars, resource limits, security_opt, published ports or Traefik
    # labels never reached an existing install. adguard_deploy is idempotent
    # by design (see CLAUDE.md "Idempotency pattern"), so calling it here is
    # safe and is what makes `corex doctor` able to deliver fixes at all.
    adguard_deploy
    local dir="${DOCKER_ROOT}/adguard"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" up -d --force-recreate
}

adguard_credentials() {
    echo "AdGuard Home: http://${SERVER_IP}:3000 (set during wizard)"
}
