#!/bin/bash
# lib/services/portainer.sh — CoreX Pro v2
# Portainer CE — Docker Management UI
#
# CRITICAL NOTES:
#   - Uses HTTPS on port 9443 with a self-signed cert (browser warning is normal)
#   - Traefik label must use scheme=https (Portainer speaks HTTPS, not HTTP)
#   - Data stored on SSD (not anonymous volume) so it's included in backups
#   - FIRST VISITOR BECOMES ADMIN — create account immediately after install

# ── Metadata ──────────────────────────────────────────────────────────────────
SERVICE_NAME="portainer"
SERVICE_LABEL="Portainer — Docker Management UI"
SERVICE_CATEGORY="core"
SERVICE_REQUIRED=true
SERVICE_NEEDS_DOMAIN=false
SERVICE_NEEDS_EMAIL=false
SERVICE_RAM_MB=128
SERVICE_DISK_GB=1
SERVICE_DESCRIPTION="Web UI to manage all your Docker containers, images, and volumes. Replaces the Docker CLI for most tasks."

# ── Functions ─────────────────────────────────────────────────────────────────

portainer_dirs() {
    mkdir -p "${DOCKER_ROOT}/portainer" "${DATA_ROOT}/portainer"
    chown -R 1000:1000 "${DATA_ROOT}/portainer"
}

portainer_firewall() {
    ufw allow 9443/tcp comment 'Portainer (HTTPS UI)' 2>/dev/null || true
}

portainer_deploy() {
    mkdir -p "${DOCKER_ROOT}/portainer" "${DATA_ROOT}/portainer"
    chown -R 1000:1000 "${DATA_ROOT}/portainer"
    local dir="${DOCKER_ROOT}/portainer"

    cat > "${dir}/docker-compose.yml" << DCEOF
services:
  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: unless-stopped
    ports: ["9443:9443"]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ${DATA_ROOT}/portainer:/data
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

    docker compose -f "${dir}/docker-compose.yml" up -d \
        || log_warning "Portainer may not have started — check: docker ps"
    state_service_installed "portainer"
    log_success "Portainer deployed (https://${SERVER_IP}:9443)"
}

portainer_destroy() {
    local dir="${DOCKER_ROOT}/portainer"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" down
    state_service_removed "portainer"
}

portainer_status() {
    if container_running "portainer"; then echo "HEALTHY"
    elif container_exists "portainer"; then echo "UNHEALTHY"
    else echo "MISSING"; fi
}

portainer_repair() {
    local dir="${DOCKER_ROOT}/portainer"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" up -d --force-recreate
}

portainer_credentials() {
    echo "Portainer: https://${SERVER_IP}:9443 (create admin on first visit)"
}
