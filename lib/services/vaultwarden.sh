#!/bin/bash
# lib/services/vaultwarden.sh — CoreX Pro v2
# Vaultwarden — Password Manager (Bitwarden-compatible)
#
# NOTES:
#   - Lightweight Rust reimplementation of Bitwarden server
#   - Compatible with all official Bitwarden clients (mobile, desktop, extension)
#   - Admin panel at https://vault.DOMAIN/admin (token-protected)
#   - Set SIGNUPS_ALLOWED=false after creating your accounts

# ── Metadata ──────────────────────────────────────────────────────────────────
SERVICE_NAME="vaultwarden"
SERVICE_LABEL="Vaultwarden — Password Manager (replaces 1Password / Bitwarden)"
SERVICE_CATEGORY="security"
SERVICE_REQUIRED=false
SERVICE_NEEDS_DOMAIN=true
SERVICE_NEEDS_EMAIL=false
SERVICE_RAM_MB=128
SERVICE_DISK_GB=1
SERVICE_DESCRIPTION="Self-hosted password manager. Works with all Bitwarden apps. Unlimited passwords, secure notes, and 2FA on your own hardware."

# ── Functions ─────────────────────────────────────────────────────────────────

vaultwarden_dirs() {
    mkdir -p "${DOCKER_ROOT}/vaultwarden" "${DATA_ROOT}/vaultwarden"
    chown -R 1000:1000 "${DATA_ROOT}/vaultwarden"
}

vaultwarden_firewall() {
    : # Traefik handles all HTTPS; no extra ports needed
}

vaultwarden_deploy() {
    vaultwarden_dirs
    local dir="${DOCKER_ROOT}/vaultwarden"

    cat > "${dir}/docker-compose.yml" << DCEOF
services:
  vaultwarden:
    image: vaultwarden/server:latest
    container_name: vaultwarden
    restart: unless-stopped
    volumes:
      - ${DATA_ROOT}/vaultwarden:/data
    environment:
      DOMAIN: "https://vault.${DOMAIN}"
      ADMIN_TOKEN: "${VAULTWARDEN_ADMIN_TOKEN}"
      SIGNUPS_ALLOWED: "true"
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

    docker compose -f "${dir}/docker-compose.yml" up -d \
        || log_warning "Vaultwarden may not have started — check: docker ps"
    state_service_installed "vaultwarden"
    log_success "Vaultwarden deployed (vault.${DOMAIN})"
}

vaultwarden_destroy() {
    local dir="${DOCKER_ROOT}/vaultwarden"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" down
    state_service_removed "vaultwarden"
}

vaultwarden_status() {
    if container_running "vaultwarden"; then echo "HEALTHY"
    elif container_exists "vaultwarden"; then echo "UNHEALTHY"
    else echo "MISSING"; fi
}

vaultwarden_repair() {
    local dir="${DOCKER_ROOT}/vaultwarden"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" up -d --force-recreate
}

vaultwarden_credentials() {
    echo "Vaultwarden: https://vault.${DOMAIN} (register on first visit)"
    echo "  Admin panel: https://vault.${DOMAIN}/admin"
    echo "  Admin token: ${VAULTWARDEN_ADMIN_TOKEN}"
}
