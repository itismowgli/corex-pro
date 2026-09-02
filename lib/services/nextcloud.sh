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
#   - Memories → HEVC video transcoding (internal go-vod + ffmpeg)

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

  # ── HSTS ────────────────────────────────────────────────────────────
  # Traefik's nc-headers middleware also sets this, but Cloudflare Tunnel
  # connects directly to nextcloud:80 and never passes through Traefik —
  # so tunnel traffic would carry no HSTS header, and Nextcloud's own
  # setup checks report "Strict-Transport-Security not set". Setting it
  # here covers both paths. setifempty avoids duplicating Traefik's value
  # on the LAN path.
  Header always setifempty Strict-Transport-Security "max-age=15552000; includeSubDomains"
</IfModule>
APEOF

    # occ-based settings (APCu, Redis locking, chunk size, maintenance
    # window, log rotation, indices) are applied host-side after the
    # container is up — see _nextcloud_apply_occ.
}

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

# Writes the docker-compose.yml for Nextcloud and satellite containers.
# Called by both nextcloud_deploy() and nextcloud_repair() so compose
# changes (added/removed containers) take effect on repair.
# The whiteboard backend and the Nextcloud app authenticate to each other with
# a shared JWT secret, so it must stay stable across re-runs — regenerating it
# would silently break real-time collaboration until the app was reconfigured.
# It is kept in its own 0600 file rather than added to corex-credentials.txt,
# because that file's format is parsed by exact grep patterns in phase 0
# (see CLAUDE.md "What NOT to Do" #2) and is not worth destabilising for this.
_nextcloud_whiteboard_secret() {
    local f="${DOCKER_ROOT}/nextcloud/.whiteboard-secret"
    if [[ -s "$f" ]]; then
        WHITEBOARD_SECRET=$(cat "$f")
    else
        WHITEBOARD_SECRET=$(generate_pass)
        printf '%s' "$WHITEBOARD_SECRET" > "$f"
        chmod 600 "$f"
    fi
    export WHITEBOARD_SECRET
}

_nextcloud_write_compose() {
    local dir="${DOCKER_ROOT}/nextcloud"
    _nextcloud_whiteboard_secret

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
    image: nextcloud:34
    container_name: nextcloud
    restart: unless-stopped
    volumes:
      - ${DATA_ROOT}/nextcloud-html:/var/www/html
      - ./zzz-corex-performance.ini:/usr/local/etc/php/conf.d/zzz-corex-performance.ini:ro
      - ./corex-apache-perf.conf:/etc/apache2/conf-enabled/corex-perf.conf:ro
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
      # ── For the before-starting hook ──────────────────────────────
      # The hook heredoc is single-quoted, so these stay literal in the
      # script and expand at runtime from the container's environment.
      # Used to point the Whiteboard app at its WebSocket backend.
      COREX_DOMAIN: "${DOMAIN}"
      WHITEBOARD_SECRET: "${WHITEBOARD_SECRET}"
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
    image: nextcloud:34
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

  # ── Whiteboard real-time collaboration backend ──────────────────────
  # The Whiteboard app renders locally without this, but real-time
  # multi-user editing needs a separate WebSocket server — which is why
  # Nextcloud's setup checks flag "WebSocket server URL is not
  # configured" the moment the app is enabled.
  #
  # It authenticates to Nextcloud with a shared JWT secret, so
  # WHITEBOARD_SECRET here must match the whiteboard app's jwt_secret
  # (set via occ below). NEXTCLOUD_URL uses the internal container name:
  # the backend talks to Nextcloud over proxy-net, so routing it out
  # through Traefik or the tunnel would be a pointless round trip.
  whiteboard:
    image: ghcr.io/nextcloud-releases/whiteboard:release
    container_name: nextcloud-whiteboard
    restart: unless-stopped
    environment:
      NEXTCLOUD_URL: "http://nextcloud"
      JWT_SECRET_KEY: "${WHITEBOARD_SECRET}"
      # Storage strategy is left at the image default (in-memory).
      # STORAGE_STRATEGY=redis fails on this release with
      # "RedisStrategy.createRedisClient is not a function", and Redis there
      # exists to share state across MULTIPLE whiteboard backend instances —
      # which a single-server homelab does not run. In-memory is correct here.
    depends_on:
      app:
        condition: service_started
    networks: [proxy-net]
    security_opt: ["no-new-privileges:true"]
    deploy:
      resources:
        limits:
          memory: 512m
          cpus: "0.5"
        reservations:
          memory: 64m
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.ncwb.rule=Host(\`whiteboard.${DOMAIN}\`)"
      - "traefik.http.routers.ncwb.entrypoints=websecure"
      - "traefik.http.routers.ncwb.tls.certresolver=myresolver"
      - "traefik.http.services.ncwb.loadbalancer.server.port=3002"

networks:
  proxy-net: { external: true }
DCEOF
}

# ── Apply Nextcloud settings from the host ────────────────────────────────────
# This used to run as a before-starting hook inside the container. That was the
# wrong place: the hook fires before Nextcloud and the database are ready, it
# has to drop privileges to www-data in a context where gosu (removed in 34),
# setpriv, runuser and su all failed to yield uid 33, and when it went wrong the
# retry loop blocked container startup for minutes while Traefik served 502.
#
# `docker exec -u www-data` from the host does the same job, works reliably,
# runs only after the container is actually up, and cannot stall startup.
# Settings persist in config.php and the database, so applying them on deploy
# and repair is sufficient — a plain `docker restart` does not lose them.
_nextcloud_apply_occ() {
    local _o=(docker exec -u www-data nextcloud php occ)
    local i

    # 1. Wait for occ to respond at all (database startup).
    local ready=false
    for i in $(seq 1 24); do
        if "${_o[@]}" status >/dev/null 2>&1; then ready=true; break; fi
        sleep 5
    done
    if [[ "$ready" != "true" ]]; then
        log_warning "occ did not respond within 2 minutes — settings not applied."
        echo "    Check: docker exec -u www-data nextcloud php occ status"
        return 0
    fi

    # 2. Finish a pending schema upgrade. Pulling a new image leaves the
    #    database behind the code, and occ refuses almost every command until
    #    this completes — silently, which is how a stale instance goes
    #    unnoticed.
    if "${_o[@]}" status 2>/dev/null | grep -q 'needsDbUpgrade: true'; then
        log_step "Nextcloud needs a database upgrade — running occ upgrade..."
        "${_o[@]}" upgrade 2>&1 | tail -5 | sed 's/^/    /' || true
    fi

    # 3. Clear maintenance mode if it is stuck on. occ upgrade prints
    #    "Maintenance mode is kept active" and leaves the flag set, and an
    #    upgrade interrupted by a crash does the same. While it is set,
    #    Nextcloud serves HTTP 503 and every config command fails with
    #    "only AppAPI commands are loaded" — so this must be cleared BEFORE
    #    applying settings, or they all fail invisibly.
    if [[ "$("${_o[@]}" config:system:get maintenance 2>/dev/null)" == "true" ]]; then
        if "${_o[@]}" status 2>/dev/null | grep -q 'needsDbUpgrade: true'; then
            log_warning "Maintenance mode on and upgrade still pending — leaving it."
            return 0
        fi
        log_step "Clearing stuck maintenance mode (site returns 503 while set)..."
        "${_o[@]}" maintenance:mode --off 2>&1 | sed 's/^/    /' || true
    fi

    # 4. Apply settings. Failures are counted rather than swallowed: an
    #    earlier version sent everything to /dev/null with "|| true", so a run
    #    in which every single setting failed looked identical to success.
    local failed=0
    _set() {
        if ! "${_o[@]}" "$@" >/dev/null 2>&1; then
            log_warning "occ $1 ${2:-} failed"
            failed=$((failed + 1))
        fi
    }

    # APCu as local (single-server) memory cache — speeds up metadata lookups
    _set config:system:set memcache.local --value '\OC\Memcache\APCu'
    # Redis for distributed file locking — prevents corruption on parallel access
    _set config:system:set memcache.locking --value '\OC\Memcache\Redis'
    # Suppress admin panel "default_phone_region not set" warning
    _set config:system:set default_phone_region --value 'US'
    # 10MB chunks: the 100MB default exceeds Cloudflare's body limit (HTTP 413)
    _set config:app:set files max_chunk_size --value 10485760
    # Run heavy daily jobs at 01:00 UTC, not during peak use (also a thermal win)
    _set config:system:set maintenance_window_start --type=integer --value=1
    # nextcloud.log is written by PHP, so Docker's json-file rotation never
    # applies to it and it grows unbounded — 91MB observed in the field.
    _set config:system:set log_rotate_size --type=integer --value=10485760
    # Idempotent; a no-op when nothing is missing.
    "${_o[@]}" db:add-missing-indices >/dev/null 2>&1 || true

    # Point the Whiteboard app at its WebSocket backend. Skipped silently when
    # the app is not enabled, which is why this one is not counted as failure.
    if [[ -n "${WHITEBOARD_SECRET:-}" && -n "${DOMAIN:-}" ]]; then
        "${_o[@]}" config:app:set whiteboard collabBackendUrl \
            --value "https://whiteboard.${DOMAIN}" >/dev/null 2>&1 || true
        "${_o[@]}" config:app:set whiteboard jwt_secret_key \
            --value "${WHITEBOARD_SECRET}" >/dev/null 2>&1 || true
    fi

    if (( failed > 0 )); then
        log_warning "${failed} Nextcloud setting(s) failed to apply."
        echo "    Check: docker exec -u www-data nextcloud php occ status"
    else
        log_success "Nextcloud settings applied via occ"
    fi
}

nextcloud_deploy() {
    nextcloud_dirs
    _nextcloud_write_perf_configs
    _nextcloud_write_compose

    local dir="${DOCKER_ROOT}/nextcloud"
    docker compose -f "${dir}/docker-compose.yml" up -d \
        || log_warning "Nextcloud may not have started — check: docker ps"
    _nextcloud_apply_occ
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
    _nextcloud_apply_occ
}

nextcloud_credentials() {
    echo "Nextcloud: https://nextcloud.${DOMAIN} (create admin on first visit)"
    echo "  Whiteboard backend: https://whiteboard.${DOMAIN} (real-time collaboration)"
    echo "    For external access, add a Cloudflare Tunnel public hostname:"
    echo "      whiteboard.${DOMAIN} -> http://nextcloud-whiteboard:3002"
    echo "    LAN access works via the AdGuard wildcard + Traefik already."
    echo "  DB user: nextcloud / pass: ${NEXTCLOUD_DB_PASS}"
    echo "  MySQL root: ${MYSQL_ROOT_PASS}"
    echo "  Video streaming: Memories app (internal go-vod + ffmpeg transcoding)"
    echo "    iPhone .mov (HEVC) files play in all browsers via on-demand HLS transcoding"
}
