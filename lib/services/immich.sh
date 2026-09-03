#!/bin/bash
# lib/services/immich.sh — CoreX Pro v2
# Immich — Photo & Video Management (Google Photos alternative)
#
# NOTES:
#   - ML container downloads models on first start (~1GB, takes time)
#   - Uses pgvecto-rs (Postgres with vector search) for face/object recognition
#   - model-cache is a named volume (doesn't need backup)

# ── Metadata ──────────────────────────────────────────────────────────────────
SERVICE_NAME="immich"
SERVICE_LABEL="Immich — Photo Backup (replaces Google Photos / iCloud)"
SERVICE_CATEGORY="storage"
SERVICE_REQUIRED=false
SERVICE_NEEDS_DOMAIN=true
SERVICE_NEEDS_EMAIL=false
SERVICE_RAM_MB=2048
SERVICE_DISK_GB=20
# UFW rules this service opens, as full `ufw allow` specs. cmd_remove
# revokes them, because leaving a port open with nothing behind it is all
# of the exposure and none of the service.
SERVICE_FIREWALL_SPECS=("2283/tcp")
SERVICE_DESCRIPTION="Automatic photo and video backup from your phone. Face recognition, smart search, albums. Replaces Google Photos and iCloud."

# Uptime Kuma check, seeded by lib/kuma.sh so it is recreated on a fresh
# install rather than living only in Kuma's database. Tab separated:
# name, url, accepted status codes. The name is the key, so changing it
# creates a second monitor and orphans the first.
SERVICE_MONITORS="Immich	https://photos.${DOMAIN:-}	[\"200-299\"]"

# ── Functions ─────────────────────────────────────────────────────────────────

immich_dirs() {
    mkdir -p "${DOCKER_ROOT}/immich"
    mkdir -p "${DATA_ROOT}/immich-db" "${DATA_ROOT}/immich-upload"
    chown -R 1000:1000 "${DATA_ROOT}/immich-db" "${DATA_ROOT}/immich-upload"
}

immich_firewall() {
    ufw allow 2283/tcp comment 'Immich Photo Management' 2>/dev/null || true
}

immich_deploy() {
    immich_dirs
    local dir="${DOCKER_ROOT}/immich"

    cat > "${dir}/docker-compose.yml" << DCEOF
services:
  immich-server:
    # Pinned, not :release. That tag moved this deployment from Immich 1.x to
    # 3.1.0 on a routine update, and 3.x dropped the pgvecto.rs extension the
    # database provided, so every start failed with "No vector extension
    # found" and the photo library was down. Bump this deliberately, checking
    # the release notes for database requirements. See CLAUDE.md gotcha #19.
    image: ghcr.io/immich-app/immich-server:v3.1.0
    container_name: immich-server
    restart: unless-stopped
    ports: ["2283:2283"]
    volumes:
      - ${DATA_ROOT}/immich-upload:/usr/src/app/upload
      - /etc/localtime:/etc/localtime:ro
    environment:
      DB_HOSTNAME: immich-db
      DB_PASSWORD: "${IMMICH_DB_PASS}"
      DB_USERNAME: postgres
      DB_DATABASE_NAME: immich
      REDIS_HOSTNAME: immich-redis
    depends_on:
      immich-db:
        condition: service_healthy
      immich-redis:
        condition: service_started
    networks: [proxy-net]
    deploy:
      resources:
        limits:
          memory: 1g
          cpus: "1.0"
        reservations:
          memory: 256m
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.immich.rule=Host(\`photos.${DOMAIN}\`)"
      - "traefik.http.routers.immich.entrypoints=websecure"
      - "traefik.http.routers.immich.tls.certresolver=myresolver"
      - "traefik.http.services.immich.loadbalancer.server.port=2283"

  immich-machine-learning:
    # Must track the server version exactly.
    image: ghcr.io/immich-app/immich-machine-learning:v3.1.0
    container_name: immich-ml
    restart: unless-stopped
    volumes: ["model-cache:/cache"]
    networks: [proxy-net]
    deploy:
      resources:
        limits:
          memory: 1g
          cpus: "1.0"
        reservations:
          memory: 256m

  immich-redis:
    image: redis:alpine
    container_name: immich-redis
    restart: unless-stopped
    networks: [proxy-net]
    deploy:
      resources:
        limits:
          memory: 128m
          cpus: "0.25"
        reservations:
          memory: 32m

  immich-db:
    # Immich's own Postgres image, carrying both VectorChord and pgvecto.rs.
    # Immich 3.x supports only vchord or pgvector, while existing CoreX
    # installs hold their embeddings in pgvecto.rs "vectors" columns. This
    # transitional image has both, so Immich migrates the embeddings itself on
    # first start. Once migrated, ghcr.io/immich-app/postgres:14-vectorchord0.4.3
    # is the leaner image to move to.
    image: ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0
    container_name: immich-db
    restart: unless-stopped
    # VectorChord builds its index in shared memory; the 64MB Docker default
    # is not enough.
    shm_size: 128mb
    environment:
      POSTGRES_PASSWORD: "${IMMICH_DB_PASS}"
      POSTGRES_USER: postgres
      POSTGRES_DB: immich
      POSTGRES_INITDB_ARGS: "--data-checksums"
    volumes:
      - ${DATA_ROOT}/immich-db:/var/lib/postgresql/data
    networks: [proxy-net]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      start_period: 30s
      interval: 10s
      timeout: 5s
      retries: 5
    deploy:
      resources:
        limits:
          memory: 512m
          cpus: "1.0"
        reservations:
          memory: 128m

volumes:
  model-cache:
networks:
  proxy-net: { external: true }
DCEOF

    docker compose -f "${dir}/docker-compose.yml" up -d \
        || log_warning "Immich may not have started — check: docker ps"
    state_service_installed "immich"
    log_success "Immich deployed (2283, photos.${DOMAIN})"
}

immich_destroy() {
    local dir="${DOCKER_ROOT}/immich"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" down
    state_service_removed "immich"
}

immich_status() {
    if container_running "immich-server"; then echo "HEALTHY"
    elif container_exists "immich-server"; then echo "UNHEALTHY"
    else echo "MISSING"; fi
}

immich_repair() {
    # Regenerate the compose file first. Without this, repair recreated the
    # container from a compose file that could be months old, so CoreX fixes
    # to env vars, resource limits, security_opt, published ports or Traefik
    # labels never reached an existing install. immich_deploy is idempotent
    # by design (see CLAUDE.md "Idempotency pattern"), so calling it here is
    # safe and is what makes `corex doctor` able to deliver fixes at all.
    immich_deploy
    local dir="${DOCKER_ROOT}/immich"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" up -d --force-recreate
}

immich_credentials() {
    echo "Immich: https://photos.${DOMAIN} (create admin on first visit)"
    echo "  DB pass: ${IMMICH_DB_PASS}"
}
