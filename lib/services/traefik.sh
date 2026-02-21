#!/bin/bash
# lib/services/traefik.sh — CoreX Pro v2
# Traefik v3 — Reverse Proxy & TLS Termination
#
# CRITICAL NOTES:
#   - loadbalancer.server.port = CONTAINER port, NOT host port
#   - acme.json MUST be chmod 600 or Traefik refuses to start
#   - Uses TLS-ALPN-01 challenge (no port 80 needed for cert issuance)
#   - exposedByDefault=false means only labeled containers are routed

# ── Metadata (auto-discovered by wizard) ──────────────────────────────────────
SERVICE_NAME="traefik"
SERVICE_LABEL="Traefik — Reverse Proxy (required for HTTPS routing)"
SERVICE_CATEGORY="core"
SERVICE_REQUIRED=true
SERVICE_NEEDS_DOMAIN=false
SERVICE_NEEDS_EMAIL=true
SERVICE_RAM_MB=128
SERVICE_DISK_GB=1
SERVICE_DESCRIPTION="Automatic HTTPS for all your services. Manages SSL certificates via Let's Encrypt. Required for all domain-based services."

# ── Functions ─────────────────────────────────────────────────────────────────

traefik_dirs() {
    mkdir -p "${DOCKER_ROOT}/traefik"
}

traefik_firewall() {
    ufw allow 80/tcp   comment 'HTTP (Traefik redirects to HTTPS)' 2>/dev/null || true
    ufw allow 443/tcp  comment 'HTTPS (Traefik TLS termination)'   2>/dev/null || true
    ufw allow 8080/tcp comment 'Traefik Dashboard'                 2>/dev/null || true
}

traefik_deploy() {
    mkdir -p "${DOCKER_ROOT}/traefik"
    local dir="${DOCKER_ROOT}/traefik"

    # acme.json must exist with chmod 600 before container starts
    touch "${dir}/acme.json" && chmod 600 "${dir}/acme.json"

    # Static config: entrypoints, providers, certificate resolvers
    cat > "${dir}/traefik.yml" << TEOF
api:
  insecure: true
  dashboard: true
entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":443"
providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
    network: proxy-net
certificatesResolvers:
  myresolver:
    acme:
      tlsChallenge: {}
      email: "${EMAIL}"
      storage: /acme.json
TEOF

    cat > "${dir}/docker-compose.yml" << DCEOF
services:
  traefik:
    image: traefik:v3.0
    container_name: traefik
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "8080:8080"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik.yml:/traefik.yml:ro
      - ./acme.json:/acme.json
    networks: [proxy-net]
    security_opt: ["no-new-privileges:true"]
networks:
  proxy-net: { external: true }
DCEOF

    docker compose -f "${dir}/docker-compose.yml" up -d \
        || log_warning "Traefik may not have started — check: docker ps"
    state_service_installed "traefik"
    log_success "Traefik deployed (80→443, dashboard:8080)"
}

traefik_destroy() {
    local dir="${DOCKER_ROOT}/traefik"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" down
    state_service_removed "traefik"
}

traefik_status() {
    if container_running "traefik"; then echo "HEALTHY"
    elif container_exists "traefik"; then echo "UNHEALTHY"
    else echo "MISSING"; fi
}

traefik_repair() {
    local dir="${DOCKER_ROOT}/traefik"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" up -d --force-recreate
}

traefik_credentials() {
    echo "Traefik Dashboard: http://${SERVER_IP}:8080 (no auth)"
}
