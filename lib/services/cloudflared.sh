#!/bin/bash
# lib/services/cloudflared.sh — CoreX Pro v2
# Cloudflare Tunnel — Secure External Access (zero port forwarding)
#
# CRITICAL NOTES:
#   - Must be on proxy-net to reach other containers by name
#   - In CF Dashboard, use CONTAINER NAMES not localhost as targets
#   - Enable "No TLS Verify" in CF dashboard for Traefik-proxied services
#   - Token comes from: one.dash.cloudflare.com → Networks → Tunnels

# ── Metadata ──────────────────────────────────────────────────────────────────
SERVICE_NAME="cloudflared"
SERVICE_LABEL="Cloudflare Tunnel — Secure External Access"
SERVICE_CATEGORY="core"
SERVICE_REQUIRED=false
SERVICE_NEEDS_DOMAIN=true
SERVICE_NEEDS_EMAIL=false
SERVICE_RAM_MB=64
SERVICE_DISK_GB=0
SERVICE_DESCRIPTION="Expose your services to the internet without opening any ports on your router. Encrypted tunnel through Cloudflare's network."

# ── Functions ─────────────────────────────────────────────────────────────────

cloudflared_dirs() {
    mkdir -p "${DOCKER_ROOT}/cloudflared"
}

cloudflared_firewall() {
    : # Cloudflared makes outbound connections only; no inbound ports needed
}

cloudflared_deploy() {
    cloudflared_dirs
    local dir="${DOCKER_ROOT}/cloudflared"

    # Clean up any old container
    docker rm -f cloudflared 2>/dev/null || true

    if [[ "${CLOUDFLARE_TUNNEL_TOKEN:-}" == "PASTE_YOUR_TUNNEL_TOKEN_HERE" ]] \
        || [[ -z "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]]; then
        log_warning "Cloudflare Tunnel skipped (no token configured)"
        log_warning "  Add your token later: corex-manage add cloudflared"
        return 0
    fi

    cat > "${dir}/docker-compose.yml" << DCEOF
services:
  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared
    restart: unless-stopped
    command: tunnel --no-autoupdate run --token ${CLOUDFLARE_TUNNEL_TOKEN}
    networks: [proxy-net]
    security_opt: ["no-new-privileges:true"]
networks:
  proxy-net: { external: true }
DCEOF

    docker compose -f "${dir}/docker-compose.yml" up -d \
        || log_warning "Cloudflared may not have started — check: docker ps"
    state_service_installed "cloudflared"
    log_success "Cloudflare Tunnel active"
}

cloudflared_destroy() {
    local dir="${DOCKER_ROOT}/cloudflared"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" down
    state_service_removed "cloudflared"
}

cloudflared_status() {
    if container_running "cloudflared"; then echo "HEALTHY"
    elif container_exists "cloudflared"; then echo "UNHEALTHY"
    else echo "MISSING"; fi
}

cloudflared_repair() {
    local dir="${DOCKER_ROOT}/cloudflared"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" up -d --force-recreate
}

cloudflared_credentials() {
    echo "Cloudflare Tunnel: managed at one.dash.cloudflare.com"
    echo "  Public Hostnames → use container names (not localhost)"
}
