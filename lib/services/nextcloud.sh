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
# PERFORMANCE TUNING (v2.3.0+):
#   - PHP output_buffering=Off → stream files directly (KB/s → MB/s fix)
#   - OPcache + APCu → faster page loads and metadata lookups
#   - JIT disabled → prevents segfaults in chunked upload code paths
#   - Apache mod_deflate bypass for binary files → no CPU bottleneck
#   - Apache mod_reqtimeout extended → large uploads don't timeout
#   - Apache LimitRequestBody 0 → removes body size limit (PHP enforces its own)
#   - MariaDB innodb tuning → faster file listing queries
#   - Traefik middleware → CalDAV/CardDAV + HSTS headers
#   - max_chunk_size 10MB → Cloudflare compatibility (before-starting hook)
#   - Apache streaming headers → byte-range + proxy bypass for file transfers

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
; JIT disabled — known to cause segfaults in Nextcloud's chunked upload
; and WebDAV code paths (tracing mode 1255 is especially unstable).
; OPcache without JIT still provides 95% of the performance benefit.
; Nextcloud is I/O-bound, not CPU-bound, so JIT adds risk with no gain.
opcache.jit = 0
opcache.jit_buffer_size = 0

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

# Remove Apache request body size limit entirely.
# PHP enforces its own upload_max_filesize (16G). Without this, Apache may
# inherit a restrictive LimitRequestBody from Nextcloud's .htaccess or the
# Docker image entrypoint, causing "Unknown error" on large uploads.
# 0 = unlimited (Apache delegates to PHP limits).
LimitRequestBody 0

# ── File transfer streaming optimization ───────────────────────────
# Ensures chunked uploads get fast acknowledgments and proxies don't
# buffer or transform file responses. Applies to all WebDAV file paths.
<IfModule mod_headers.c>
  # Advertise byte-range support for progressive downloads/streaming
  Header set Accept-Ranges "bytes" "expr=%{REQUEST_URI} =~ m#/remote\.php/dav/files/#"

  # Tell proxies (Cloudflare, Traefik) not to buffer file responses.
  # Without this, proxies may buffer multi-GB responses in memory and
  # add latency to chunked upload acknowledgments.
  Header set X-Accel-Buffering "no" "expr=%{REQUEST_URI} =~ m#/remote\.php/dav/files/#"
  Header set Cache-Control "no-transform" "expr=%{REQUEST_URI} =~ m#/remote\.php/dav/files/#"
</IfModule>
APEOF

    # ── Nextcloud config.php injection hook ──────────────────────────
    # Runs on every container start; adds APCu local cache if missing.
    # The Nextcloud image auto-configures Redis via REDIS_HOST env var
    # but does NOT add APCu as local memcache — this hook fixes that.
    #
    # Also sets max_chunk_size to 10MB for Cloudflare compatibility.
    # Nextcloud default is 100MB, but Cloudflare free plan rejects
    # request bodies > 100MB, causing HTTP 413 on large uploads when
    # accessed through the tunnel. 10MB is safe for all Cloudflare plans.
    mkdir -p "${dir}/hooks/before-starting"
    cat > "${dir}/hooks/before-starting/corex-memcache.sh" << 'HOOKEOF'
#!/bin/bash
# CoreX Pro — inject cache config + chunk size into Nextcloud config.php
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

# Set max_chunk_size to 10MB (10485760 bytes) for Cloudflare compatibility.
# Default is 100MB (104857600) which exceeds Cloudflare free plan's 100MB
# body limit, causing HTTP 413 errors on large file uploads via the tunnel.
# 10MB chunks work on all Cloudflare plans and have minimal overhead on LAN.
#
# Must run as www-data (uid 33) — running as root creates cache files with
# wrong ownership, causing subsequent occ commands to fail.
# Wait up to 30s for the database (health check should ensure readiness,
# but retry defensively in case of transient connection issues).
for i in $(seq 1 6); do
    # Use gosu (ships with Nextcloud Docker image) instead of su.
    # gosu drops privileges via setuid(2) syscall, not SUID binary —
    # compatible with no-new-privileges security policy and doesn't
    # create root-owned session/cache artifacts.
    if gosu www-data php /var/www/html/occ config:app:set files max_chunk_size --value 10485760 2>&1; then
        break
    fi
    sleep 5
done

# ── Patch .htaccess for LimitRequestBody (Umbrel pattern) ────────
# Nextcloud regenerates .htaccess on startup and updates. The
# APACHE_BODY_LIMIT env var handles the Apache config, but .htaccess
# can override it (AllowOverride All). This background process waits
# for .htaccess to exist and injects LimitRequestBody 0 if missing.
# Ref: https://github.com/getumbrel/umbrel-apps/blob/master/nextcloud/hooks/post-start
(
    HTACCESS="/var/www/html/.htaccess"
    # Wait up to 30 seconds for .htaccess to be created
    for attempt in $(seq 1 300); do
        [ -f "$HTACCESS" ] && break
        sleep 0.1
    done
    if [ -f "$HTACCESS" ] && ! grep -q '^LimitRequestBody' "$HTACCESS"; then
        echo "" >> "$HTACCESS"
        echo "# CoreX Pro — allow unlimited upload body size (PHP enforces limits)" >> "$HTACCESS"
        echo "LimitRequestBody 0" >> "$HTACCESS"
    fi
) &
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

# Writes the docker-compose.yml for Nextcloud and satellite containers.
# Called by both nextcloud_deploy() and nextcloud_repair() so compose
# changes (added/removed containers) take effect on repair.
_nextcloud_write_compose() {
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
    # ── Health check: before-starting hook runs occ which needs DB ────
    # Without this, depends_on only waits for container start, not
    # MariaDB readiness. Adapted from Umbrel's Nextcloud config.
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 30s
      interval: 10s
      timeout: 5s
      retries: 5
    networks: [proxy-net]

  redis:
    image: redis:alpine
    container_name: nextcloud-redis
    restart: unless-stopped
    command: redis-server --save 60 1 --loglevel warning
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      start_period: 5s
      interval: 10s
      timeout: 3s
      retries: 3
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
      # ── CRITICAL: Apache 2.4.54+ defaults LimitRequestBody to 1GB ──
      # Without this, uploads > 1GB silently fail with "Unknown error".
      # 0 = unlimited (PHP enforces its own upload_max_filesize = 16G).
      # Ref: https://github.com/nextcloud/docker/issues/1796
      APACHE_BODY_LIMIT: "0"
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
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
      - "traefik.http.middlewares.nc-caldav.redirectregex.replacement=https://\$\$1/remote.php/dav/"
      # ── Security headers ───────────────────────────────────────────
      - "traefik.http.middlewares.nc-headers.headers.stsSeconds=15552000"
      - "traefik.http.middlewares.nc-headers.headers.stsIncludeSubdomains=true"
      - "traefik.http.middlewares.nc-headers.headers.stsPreload=true"
      - "traefik.http.middlewares.nc-headers.headers.customResponseHeaders.X-Robots-Tag=noindex,nofollow"
      - "traefik.http.middlewares.nc-headers.headers.customResponseHeaders.Permissions-Policy=interest-cohort=()"
      # ── Apply middleware chain ──────────────────────────────────────
      - "traefik.http.routers.nextcloud.middlewares=nc-caldav,nc-headers"

  # ── Background job runner (Umbrel pattern) ───────────────────────
  # Runs Nextcloud cron tasks in a separate container so background
  # jobs don't compete with web request PHP workers. Shares the same
  # data volume and image as the app container.
  cron:
    image: nextcloud:stable
    container_name: nextcloud-cron
    restart: unless-stopped
    entrypoint: /cron.sh
    volumes:
      - ${DATA_ROOT}/nextcloud-html:/var/www/html
      - ./zzz-corex-performance.ini:/usr/local/etc/php/conf.d/zzz-corex-performance.ini:ro
    environment:
      MYSQL_HOST: nextcloud-db
      REDIS_HOST: nextcloud-redis
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
    networks: [proxy-net]

networks:
  proxy-net: { external: true }
DCEOF
}

nextcloud_deploy() {
    nextcloud_dirs
    _nextcloud_write_perf_configs
    _nextcloud_write_compose

    local dir="${DOCKER_ROOT}/nextcloud"
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
    if container_running "nextcloud" && container_running "nextcloud-cron"; then echo "HEALTHY"
    elif container_running "nextcloud"; then echo "HEALTHY"
    elif container_exists "nextcloud"; then echo "UNHEALTHY"
    else echo "MISSING"; fi
}

nextcloud_repair() {
    nextcloud_dirs
    _nextcloud_write_perf_configs
    _nextcloud_write_compose
    local dir="${DOCKER_ROOT}/nextcloud"
    docker compose -f "${dir}/docker-compose.yml" up -d --force-recreate --remove-orphans
}

nextcloud_credentials() {
    echo "Nextcloud: https://nextcloud.${DOMAIN} (create admin on first visit)"
    echo "  DB user: nextcloud / pass: ${NEXTCLOUD_DB_PASS}"
    echo "  MySQL root: ${MYSQL_ROOT_PASS}"
}
