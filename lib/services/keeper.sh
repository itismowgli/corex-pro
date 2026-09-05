#!/bin/bash
# Keeper calendar sync. Upstream: https://github.com/ridafkih/keeper.sh#self-hosted
SERVICE_NAME="keeper"
SERVICE_LABEL="Keeper — Calendar Sync"
SERVICE_CATEGORY="productivity"
SERVICE_REQUIRED=false
SERVICE_NEEDS_DOMAIN=true
SERVICE_NEEDS_EMAIL=false
SERVICE_RAM_MB=1024
SERVICE_DISK_GB=5
SERVICE_FIREWALL_SPECS=()
SERVICE_DESCRIPTION="Sync personal, work and Nextcloud calendars through Google, Outlook or CalDAV. Runs continuously so calendar changes keep syncing."
SERVICE_MONITORS="Keeper	https://keeper.${DOMAIN:-}	[\"200-299\",\"307\"]"
KEEPER_IMAGE="${KEEPER_IMAGE:-ghcr.io/ridafkih/keeper-standalone:2.18.7}"

keeper_dirs() {
    mkdir -p "${DOCKER_ROOT}/keeper" "${DATA_ROOT}/keeper-db"
}
keeper_firewall() { :; }

_keeper_secrets() {
    local file="${DOCKER_ROOT}/keeper/.secrets.env"
    if [[ ! -s "$file" ]]; then
        # Missing keys with an existing database must never silently replace
        # the encryption key and make stored calendar credentials unreadable.
        if [[ -n "$(ls -A "${DATA_ROOT}/keeper-db" 2>/dev/null)" ]]; then
            log_warning "Restore Keeper's .secrets.env from backup before starting its existing database."
            return 1
        fi
        (umask 077
         printf 'BETTER_AUTH_SECRET=%s\nENCRYPTION_KEY=%s\nPOSTGRES_PASSWORD=%s\n' \
            "$(openssl rand -base64 32)" "$(openssl rand -base64 32)" "$(openssl rand -hex 24)" > "$file") || return 1
    fi
    local key
    for key in BETTER_AUTH_SECRET ENCRYPTION_KEY POSTGRES_PASSWORD; do
        grep -qE "^${key}=.+" "$file" || { log_warning "Keeper secret missing: $key"; return 1; }
    done
    chmod 600 "$file"
    # Optional provider credentials live in a separate private env file.
    # Compose reads it directly; credentials are never evaluated as shell code.
    local providers="${DOCKER_ROOT}/keeper/providers.env"
    if [[ ! -e "$providers" ]]; then
        (umask 077; printf '%s\n' '# Optional: GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, MICROSOFT_CLIENT_ID, MICROSOFT_CLIENT_SECRET' > "$providers")
    fi
    chmod 600 "$providers"
}

keeper_deploy() {
    [[ -n "${DOMAIN:-}" ]] || { log_warning "Keeper needs a configured domain."; return 1; }
    keeper_dirs || return 1
    _keeper_secrets || return 1
    local dir="${DOCKER_ROOT}/keeper"
    cat > "${dir}/docker-compose.yml" << DCEOF
services:
  keeper:
    image: ${KEEPER_IMAGE}
    container_name: keeper
    restart: unless-stopped
    stop_grace_period: 60s
    env_file:
      - .secrets.env
      - providers.env
    environment:
      BETTER_AUTH_URL: "https://keeper.${DOMAIN}"
      TRUSTED_ORIGINS: "https://keeper.${DOMAIN}"
      COMMERCIAL_MODE: "false"
      WORKER_JOB_QUEUE_ENABLED: "true"
      WORKER_CONCURRENCY: "2"
      DATABASE_POOL_MAX: "3"
      CRON_FLUSH_POOL_MAX: "2"
      TZ: "${TIMEZONE:-UTC}"
    volumes:
      - ${DATA_ROOT}/keeper-db:/var/lib/postgresql/data
    networks: [proxy-net]
    security_opt: ["no-new-privileges:true"]
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    deploy:
      resources:
        limits:
          memory: 1536m
          cpus: "1.0"
        reservations:
          memory: 256m
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.keeper.rule=Host(\`keeper.${DOMAIN}\`)"
      - "traefik.http.routers.keeper.entrypoints=websecure"
      - "traefik.http.routers.keeper.tls.certresolver=myresolver"
      - "traefik.http.services.keeper.loadbalancer.server.port=80"
networks:
  proxy-net: { external: true }
DCEOF
    docker compose -f "${dir}/docker-compose.yml" config --quiet || return 1
    docker compose -f "${dir}/docker-compose.yml" up -d || return 1
    state_service_installed keeper
    log_success "Keeper deployed: https://keeper.${DOMAIN}"
    log_info "Connect Nextcloud with CalDAV and an app password. Google/Outlook require your own OAuth apps; see docs/keeper.md."
}
keeper_destroy() {
    docker compose -f "${DOCKER_ROOT}/keeper/docker-compose.yml" down || return 1
    state_service_removed keeper
}
keeper_status() {
    if container_running keeper; then echo HEALTHY
    elif container_exists keeper; then echo UNHEALTHY
    else echo MISSING; fi
}
keeper_repair() { keeper_deploy; }
keeper_credentials() {
    echo "Keeper: https://keeper.${DOMAIN}"
    echo "  Provider credentials: ${DOCKER_ROOT}/keeper/providers.env (0600)"
    echo "  Back up .secrets.env with the database; the encryption key cannot be regenerated."
}
