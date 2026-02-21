#!/bin/bash
# lib/services/nextcloud.sh — CoreX Pro v2
# Nextcloud — File Storage & Sync (Google Drive / Dropbox alternative)
#
# CRITICAL ENV VARS (must all be set or Nextcloud breaks behind proxy):
#   OVERWRITEPROTOCOL=https       — prevents redirect loops
#   OVERWRITEHOST=nextcloud.DOMAIN — tells NC its public URL
#   TRUSTED_PROXIES=172.16.0.0/12 — allows Traefik to forward X-Forwarded headers
#
# nextcloud-html directory MUST be owned by uid 33 (www-data inside container)

# ── Metadata ──────────────────────────────────────────────────────────────────
SERVICE_NAME="nextcloud"
SERVICE_LABEL="Nextcloud — File Storage (replaces Google Drive / Dropbox)"
SERVICE_CATEGORY="storage"
SERVICE_REQUIRED=false
SERVICE_NEEDS_DOMAIN=true
SERVICE_NEEDS_EMAIL=false
SERVICE_RAM_MB=2048
SERVICE_DISK_GB=10
SERVICE_DESCRIPTION="Sync files, calendar, and contacts across all your devices. Unlimited storage on your own hardware. Replaces Google Drive, iCloud, Dropbox."

# ── Functions ─────────────────────────────────────────────────────────────────

nextcloud_dirs() {
    mkdir -p "${DOCKER_ROOT}/nextcloud"
    mkdir -p "${DATA_ROOT}/nextcloud-html" "${DATA_ROOT}/nextcloud-db"
    # www-data inside the Nextcloud container runs as uid 33
    chown -R 33:33 "${DATA_ROOT}/nextcloud-html"
    chown -R 1000:1000 "${DATA_ROOT}/nextcloud-db"
}

nextcloud_firewall() {
    : # Traefik handles all HTTP/HTTPS; no extra ports needed
}

nextcloud_deploy() {
    nextcloud_dirs
    local dir="${DOCKER_ROOT}/nextcloud"

    cat > "${dir}/docker-compose.yml" << DCEOF
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
      MYSQL_HOST: nextcloud-db
      REDIS_HOST: nextcloud-redis
      OVERWRITEPROTOCOL: https
      OVERWRITEHOST: "nextcloud.${DOMAIN}"
      TRUSTED_PROXIES: "172.16.0.0/12 192.168.0.0/16"
      NEXTCLOUD_TRUSTED_DOMAINS: "nextcloud.${DOMAIN} ${SERVER_IP}"
      PHP_UPLOAD_LIMIT: 16G
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

    docker compose -f "${dir}/docker-compose.yml" up -d \
        || log_warning "Nextcloud may not have started — check: docker ps"
    state_service_installed "nextcloud"
    log_success "Nextcloud deployed (nextcloud.${DOMAIN})"
}

nextcloud_destroy() {
    local dir="${DOCKER_ROOT}/nextcloud"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" down
    state_service_removed "nextcloud"
}

nextcloud_status() {
    if container_running "nextcloud"; then echo "HEALTHY"
    elif container_exists "nextcloud"; then echo "UNHEALTHY"
    else echo "MISSING"; fi
}

nextcloud_repair() {
    local dir="${DOCKER_ROOT}/nextcloud"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" up -d --force-recreate
}

nextcloud_credentials() {
    echo "Nextcloud: https://nextcloud.${DOMAIN} (create admin on first visit)"
    echo "  DB user: nextcloud / pass: ${NEXTCLOUD_DB_PASS}"
    echo "  MySQL root: ${MYSQL_ROOT_PASS}"
}
