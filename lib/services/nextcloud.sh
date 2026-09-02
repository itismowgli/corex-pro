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
# CoreX Pro — configure Nextcloud via occ (idempotent, injection-safe)
#
# All config changes use occ instead of sed to avoid fragile PHP array
# manipulation. config:system:set writes to config.php (no DB needed);
# config:app:set writes to the database (retry loop handles DB readiness).
#
# occ must run as www-data (uid 33): Nextcloud refuses to run it as root, and
# running it as root also leaves root-owned session/cache artifacts that break
# later calls. Dropping privileges is compatible with no-new-privileges.
#
# Nextcloud 34 REMOVED gosu from the image. Hardcoding it meant every occ call
# failed with "gosu: command not found", which combined with the retry loop
# blocked container startup for minutes and applied no configuration at all
# (Traefik served 502 throughout).
#
# Each candidate is TESTED rather than assumed: a binary can be present yet
# still fail to yield uid 33 under the container's security policy, and
# probing with `command -v` alone was not sufficient in practice. The chosen
# mechanism is logged so a future failure is diagnosable from the container
# logs alone.
CONFIG="/var/www/html/config/config.php"
[ -f "$CONFIG" ] || exit 0

_RUNAS=""
for _cand in "gosu www-data" \
             "setpriv --reuid=33 --regid=33 --clear-groups" \
             "runuser -u www-data --"; do
    # shellcheck disable=SC2086
    set -- $_cand
    command -v "$1" >/dev/null 2>&1 || continue
    if [ "$($_cand id -u 2>/dev/null)" = "33" ]; then
        _RUNAS="$_cand"
        break
    fi
done

# su takes a single command string rather than argv, so it needs a separate
# code path and is kept as the last resort.
if [ -z "$_RUNAS" ] && command -v su >/dev/null 2>&1; then
    if [ "$(su -s /bin/sh -p www-data -c 'id -u' 2>/dev/null)" = "33" ]; then
        _RUNAS="SU"
    fi
fi

if [ -z "$_RUNAS" ]; then
    echo "[corex] WARNING: no working way to drop privileges to www-data (uid 33)." >&2
    echo "[corex] Tried gosu, setpriv, runuser, su. Skipping config hook." >&2
    echo "[corex] Apply settings manually:" >&2
    echo "[corex]   docker exec -u www-data nextcloud php occ <command>" >&2
    exit 0
fi
echo "[corex] dropping privileges via: ${_RUNAS}"

# _occ: run an occ command as www-data with up to 6 retries (30s total).
# config:system:set calls usually succeed on the first attempt.
# config:app:set calls may need retries while the database is initialising.
_occ() {
    _i=1
    while [ "$_i" -le 6 ]; do
        if [ "$_RUNAS" = "SU" ]; then
            if su -s /bin/sh -p www-data -c "php /var/www/html/occ $*" 2>&1; then
                return 0
            fi
        # shellcheck disable=SC2086
        elif $_RUNAS php /var/www/html/occ "$@" 2>&1; then
            return 0
        fi
        _i=$((_i + 1))
        sleep 5
    done
    echo "[corex] WARNING: occ $* failed after retries" >&2
    return 1
}

# APCu as local (single-server) memory cache — speeds up metadata lookups
_occ config:system:set memcache.local --value '\OC\Memcache\APCu' || true

# Redis for distributed file locking — prevents corruption on parallel access
_occ config:system:set memcache.locking --value '\OC\Memcache\Redis' || true

# Suppress admin panel "default_phone_region not set" warning
_occ config:system:set default_phone_region --value 'US' || true

# Set max_chunk_size to 10MB for Cloudflare compatibility.
# Default 100MB exceeds Cloudflare free plan's body limit → HTTP 413.
# config:app:set writes to DB — retry loop covers DB startup delay.
_occ config:app:set files max_chunk_size --value 10485760 || true

# ── Maintenance window ───────────────────────────────────────────────
# Without this, Nextcloud runs heavy daily jobs (file scans, previews,
# cleanup) whenever cron fires, including peak usage. On a mini server
# those jobs are also a thermal event, so pinning them to 01:00 UTC
# matters more here than on rented hardware. Value is an hour 0-23 UTC.
_occ config:system:set maintenance_window_start --type=integer --value=1 || true

# ── Bound Nextcloud's own log ────────────────────────────────────────
# nextcloud.log is written by PHP, not Docker, so the daemon's
# json-file rotation does not apply and it grows unbounded — observed
# at 91MB in the field. 10MB with rotation keeps it useful but finite.
_occ config:system:set log_rotate_size --type=integer --value=10485760 || true

# ── Add missing database indices ─────────────────────────────────────
# Nextcloud and its apps add indices over time but never apply them
# automatically, so the admin panel accrues "Database missing indices"
# warnings and queries stay slow. This is idempotent and a no-op when
# nothing is missing, so it is safe on every deploy.
# NOTE: the mimetype migration (occ maintenance:repair --include-expensive)
# is deliberately NOT run here — it can take a very long time on a large
# instance. Run it by hand during a maintenance window.
_occ db:add-missing-indices || true

# ── Whiteboard real-time collaboration ───────────────────────────────
# The app works standalone for basic drawing, but multi-user real-time
# editing needs the WebSocket backend, and Nextcloud reports
# "WebSocket server URL is not configured" until collabBackendUrl is
# set. Both values are no-ops if the whiteboard app is not enabled.
#
# The browser connects to this URL directly, so it must be reachable
# from the client: on the LAN that works via the AdGuard wildcard plus
# Traefik, but external access also needs a Cloudflare Tunnel public
# hostname for whiteboard.DOMAIN -> nextcloud-whiteboard:3002.
if [ -n "${WHITEBOARD_SECRET:-}" ] && [ -n "${COREX_DOMAIN:-}" ]; then
    _occ config:app:set whiteboard collabBackendUrl --value "https://whiteboard.${COREX_DOMAIN}" || true
    _occ config:app:set whiteboard jwt_secret_key --value "${WHITEBOARD_SECRET}" || true
fi

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

# ── Install ffmpeg for Memories video transcoding ──
# Memories v7+ ships its own go-vod binary (bin-ext/go-vod-amd64) and
# runs it internally — no external container needed. But go-vod calls
# ffmpeg as a subprocess, so ffmpeg must be in the container.
# Check first to skip on container restarts (only slow on recreate).
if ! command -v ffmpeg &>/dev/null; then
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq --no-install-recommends ffmpeg >/dev/null 2>&1
fi

# ── Install Memories for HEVC video streaming (HLS transcoding) ──
# iPhone .mov files use HEVC (H.265) which Chrome/Firefox cannot play
# natively — only Safari supports it. Memories v7 ships go-vod internally
# and transcodes on-demand to H.264 HLS adaptive bitrate streams.
# Falls back to the original stream if transcoding fails.
gosu www-data php occ app:install memories 2>/dev/null || true
gosu www-data php occ app:enable memories 2>/dev/null || true

# Configure transcoding via system config (config.php), NOT app config.
# Memories reads vod settings from config:system, not config:app.
# vod.external=false (default) = Memories runs its own go-vod from bin-ext/.
# No vod.connect needed — internal mode uses 127.0.0.1:47788 by default.
gosu www-data php occ config:system:set memories.vod.disable --value false --type bool 2>/dev/null || true
gosu www-data php occ config:system:set memories.vod.external --value false --type bool 2>/dev/null || true
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
    echo "  Whiteboard backend: https://whiteboard.${DOMAIN} (real-time collaboration)"
    echo "    For external access, add a Cloudflare Tunnel public hostname:"
    echo "      whiteboard.${DOMAIN} -> http://nextcloud-whiteboard:3002"
    echo "    LAN access works via the AdGuard wildcard + Traefik already."
    echo "  DB user: nextcloud / pass: ${NEXTCLOUD_DB_PASS}"
    echo "  MySQL root: ${MYSQL_ROOT_PASS}"
    echo "  Video streaming: Memories app (internal go-vod + ffmpeg transcoding)"
    echo "    iPhone .mov (HEVC) files play in all browsers via on-demand HLS transcoding"
}
