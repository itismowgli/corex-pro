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
#
# PERFORMANCE TUNING (v2.3.0):
#   - PHP output_buffering=Off → stream files directly (KB/s → MB/s fix)
#   - OPcache + JIT + APCu → faster page loads and metadata lookups
#   - Apache mod_deflate bypass for binary files → no CPU bottleneck
#   - Apache mod_reqtimeout extended → large uploads don't timeout
#   - MariaDB innodb tuning → faster file listing queries
#   - Traefik middleware → CalDAV/CardDAV + HSTS headers

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

# ── Private Helpers ───────────────────────────────────────────────────────────

# Generates PHP, Apache, and Nextcloud config.php performance tuning files.
# Called by both nextcloud_deploy() and nextcloud_repair() so existing
# installations get the tuning via repair without a full redeploy.
_nextcloud_write_perf_configs() {
    local dir="${DOCKER_ROOT}/nextcloud"

    # ── PHP performance config (zzz- prefix = loaded last, wins) ─────
    cat > "${dir}/zzz-corex-performance.ini" << 'PHPEOF'
; CoreX Pro — Nextcloud PHP Performance Tuning
; Optimized for large file transfers over LAN

; ── CRITICAL: disable output buffering for streaming ─────────────
; Default (4096) forces PHP to buffer+flush in tiny 4K chunks.
; Setting to Off lets PHP stream file data directly to Apache,
; which is the #1 fix for KB/s → MB/s transfer speed on LAN.
output_buffering = Off

; ── OPcache (precompile PHP — faster page loads) ─────────────────
opcache.enable = 1
opcache.memory_consumption = 256
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 10000
opcache.revalidate_freq = 60
opcache.save_comments = 1
opcache.jit = 1255
opcache.jit_buffer_size = 128M

; ── APCu (local memory cache for Nextcloud metadata) ─────────────
apc.enable_cli = 1
apc.shm_size = 128M

; ── Upload & execution limits (1 hour for large files) ───────────
upload_max_filesize = 16G
post_max_size = 16G
max_execution_time = 3600
max_input_time = 3600
memory_limit = 1G
PHPEOF

    # ── Apache performance config (large file transfer tuning) ───────
    cat > "${dir}/corex-apache-perf.conf" << 'APEOF'
# CoreX Pro — Apache Large File Transfer Optimization
#
# Disables gzip on binary payloads (prevents CPU bottleneck)
# and extends request timeouts for multi-GB uploads.

# Skip compression for binary/media files (CPU savings → faster transfers)
<IfModule mod_deflate.c>
  SetEnvIfNoCase Request_URI "\.(gif|jpe?g|png|webp|mp4|mkv|avi|mov|zip|tar|gz|bz2|7z|rar|iso|pdf|heic|heif)$" no-gzip dont-vary
  SetEnvIfNoCase Content-Type "^(image|video|audio|application/zip|application/x-)" no-gzip dont-vary
</IfModule>

# Extend request read timeout for large uploads
# header: 2 minutes for slow clients
# body: unlimited (0) so multi-GB uploads never get killed mid-transfer
<IfModule mod_reqtimeout.c>
  RequestReadTimeout header=120 body=0
</IfModule>
APEOF

    # ── Nextcloud config.php injection hook ──────────────────────────
    # Runs on every container start; adds APCu local cache if missing.
    # The Nextcloud image auto-configures Redis via REDIS_HOST env var
    # but does NOT add APCu as local memcache — this hook fixes that.
    mkdir -p "${dir}/hooks/before-starting"
    cat > "${dir}/hooks/before-starting/corex-memcache.sh" << 'HOOKEOF'
#!/bin/bash
# CoreX Pro — inject APCu local memory cache into Nextcloud config.php
CONFIG="/var/www/html/config/config.php"
[ -f "$CONFIG" ] || exit 0

# APCu as local (single-server) memory cache — speeds up metadata lookups
if ! grep -q "memcache.local" "$CONFIG"; then
    sed -i "s|);|  'memcache.local' => '\\\\OC\\\\Memcache\\\\APCu',\n);|" "$CONFIG"
fi

# Ensure Redis is used for file locking (prevents corruption on parallel access)
if ! grep -q "memcache.locking" "$CONFIG"; then
    sed -i "s|);|  'memcache.locking' => '\\\\OC\\\\Memcache\\\\Redis',\n);|" "$CONFIG"
fi

# Set default phone region to suppress admin warning
if ! grep -q "default_phone_region" "$CONFIG"; then
    sed -i "s|);|  'default_phone_region' => 'US',\n);|" "$CONFIG"
fi
HOOKEOF
    chmod +x "${dir}/hooks/before-starting/corex-memcache.sh"
}

# ── Functions ─────────────────────────────────────────────────────────────────

nextcloud_dirs() {
    mkdir -p "${DOCKER_ROOT}/nextcloud"
    mkdir -p "${DOCKER_ROOT}/nextcloud/hooks/before-starting"
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
    _nextcloud_write_perf_configs
    local dir="${DOCKER_ROOT}/nextcloud"

    cat > "${dir}/docker-compose.yml" << DCEOF
services:
  db:
    image: mariadb:10.11
    container_name: nextcloud-db
    restart: unless-stopped
    command: >-
      --transaction-isolation=READ-COMMITTED
      --binlog-format=ROW
      --innodb-read-only-compressed=OFF
      --innodb-buffer-pool-size=256M
      --innodb-log-file-size=64M
      --innodb-flush-method=O_DIRECT
      --innodb-flush-log-at-trx-commit=2
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
    command: redis-server --save 60 1 --loglevel warning
    networks: [proxy-net]

  app:
    image: nextcloud:stable
    container_name: nextcloud
    restart: unless-stopped
    volumes:
      - ${DATA_ROOT}/nextcloud-html:/var/www/html
      - ./zzz-corex-performance.ini:/usr/local/etc/php/conf.d/zzz-corex-performance.ini:ro
      - ./corex-apache-perf.conf:/etc/apache2/conf-enabled/corex-perf.conf:ro
      - ./hooks/before-starting:/docker-entrypoint-hooks.d/before-starting:ro
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
      # ── Performance: flush response chunks immediately ─────────────
      - "traefik.http.services.nextcloud.loadbalancer.responseForwarding.flushInterval=100ms"
      # ── CalDAV/CardDAV service discovery (iOS/macOS calendar sync) ─
      - "traefik.http.middlewares.nc-caldav.redirectregex.permanent=true"
      - "traefik.http.middlewares.nc-caldav.redirectregex.regex=^https://(.*)/.well-known/(?:card|cal)dav"
      - "traefik.http.middlewares.nc-caldav.redirectregex.replacement=https://\${1}/remote.php/dav/"
      # ── Security headers (HSTS + preload) ──────────────────────────
      - "traefik.http.middlewares.nc-headers.headers.stsSeconds=15552000"
      - "traefik.http.middlewares.nc-headers.headers.stsIncludeSubdomains=true"
      - "traefik.http.middlewares.nc-headers.headers.stsPreload=true"
      # ── Apply middleware chain ──────────────────────────────────────
      - "traefik.http.routers.nextcloud.middlewares=nc-caldav,nc-headers"
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
    nextcloud_dirs
    _nextcloud_write_perf_configs
    local dir="${DOCKER_ROOT}/nextcloud"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" up -d --force-recreate
}

nextcloud_credentials() {
    echo "Nextcloud: https://nextcloud.${DOMAIN} (create admin on first visit)"
    echo "  DB user: nextcloud / pass: ${NEXTCLOUD_DB_PASS}"
    echo "  MySQL root: ${MYSQL_ROOT_PASS}"
}
