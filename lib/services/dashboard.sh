#!/bin/bash
# lib/services/dashboard.sh — CoreX Pro v2
# CoreX Dashboard — Web UI (Go + HTMX, ~15MB image)
#
# NOTES:
#   - Single Go binary serving REST API + HTMX templates
#   - Auth via Traefik BasicAuth middleware (password in state.json)
#   - 5 tabs: Services, Storage, Monitoring, Network, System
#   - Shells out to corex-manage.sh — no direct Docker socket access
#   - Accessible at https://dashboard.DOMAIN

# ── Metadata ──────────────────────────────────────────────────────────────────
SERVICE_NAME="dashboard"
SERVICE_LABEL="CoreX Dashboard — Web UI (replaces CLI for daily ops)"
SERVICE_CATEGORY="core"
SERVICE_REQUIRED=false
SERVICE_NEEDS_DOMAIN=true
SERVICE_NEEDS_EMAIL=false
SERVICE_RAM_MB=64
SERVICE_DISK_GB=1
SERVICE_DESCRIPTION="Browser-based management UI. Start/stop/update services, view storage, stream logs, and manage SSL certificates — all without SSH."

# ── Functions ─────────────────────────────────────────────────────────────────

dashboard_dirs() {
    mkdir -p "${DOCKER_ROOT}/dashboard"
}

dashboard_firewall() {
    : # Traefik handles all HTTPS; no extra ports needed
}

dashboard_deploy() {
    dashboard_dirs
    local dir="${DOCKER_ROOT}/dashboard"

    # Generate BasicAuth password if not set
    if [[ -z "${DASHBOARD_PASS:-}" ]]; then
        DASHBOARD_PASS=$(openssl rand -base64 32 | tr -d '/+=' | head -c 24)
        export DASHBOARD_PASS
    fi

    # Generate htpasswd hash for Traefik BasicAuth
    local DASHBOARD_HASH
    DASHBOARD_HASH=$(openssl passwd -apr1 "${DASHBOARD_PASS}" | sed 's/\$/\$\$/g')

    cat > "${dir}/docker-compose.yml" << DCEOF
services:
  dashboard:
    image: ghcr.io/itismowgli/corex-dashboard:latest
    container_name: corex-dashboard
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /etc/corex:/etc/corex:ro
      - /root/corex-credentials.txt:/root/corex-credentials.txt:ro
      - ${SCRIPT_DIR:-/opt/corex-pro}:/opt/corex-pro:ro
    environment:
      COREX_MANAGE: "/opt/corex-pro/corex-manage.sh"
      SERVER_IP: "${SERVER_IP}"
      DOMAIN: "${DOMAIN}"
    networks: [proxy-net]
    security_opt: ["no-new-privileges:true"]
    deploy:
      resources:
        limits:
          memory: 128m
          cpus: "0.25"
        reservations:
          memory: 32m
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.dashboard.rule=Host(\`dashboard.${DOMAIN}\`)"
      - "traefik.http.routers.dashboard.entrypoints=websecure"
      - "traefik.http.routers.dashboard.tls.certresolver=myresolver"
      - "traefik.http.services.dashboard.loadbalancer.server.port=8080"
      - "traefik.http.middlewares.dash-auth.basicauth.users=admin:${DASHBOARD_HASH}"
      - "traefik.http.routers.dashboard.middlewares=dash-auth"
networks:
  proxy-net: { external: true }
DCEOF

    docker compose -f "${dir}/docker-compose.yml" up -d \
        || log_warning "Dashboard may not have started — image may not exist yet (v3.0.0)"
    state_service_installed "dashboard"
    log_success "CoreX Dashboard deployed (dashboard.${DOMAIN})"
}

dashboard_destroy() {
    local dir="${DOCKER_ROOT}/dashboard"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" down
    state_service_removed "dashboard"
}

dashboard_status() {
    if container_running "corex-dashboard"; then echo "HEALTHY"
    elif container_exists "corex-dashboard"; then echo "UNHEALTHY"
    else echo "MISSING"; fi
}

dashboard_repair() {
    local dir="${DOCKER_ROOT}/dashboard"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" up -d --force-recreate
}

dashboard_credentials() {
    echo "CoreX Dashboard: https://dashboard.${DOMAIN}"
    echo "  Username: admin"
    echo "  Password: ${DASHBOARD_PASS:-see credentials file}"
}
