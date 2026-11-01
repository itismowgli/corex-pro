#!/bin/bash
# lib/services/vaultwarden.sh — CoreX Pro v2
# Vaultwarden — Password Manager (Bitwarden-compatible)
#
# NOTES:
#   - Lightweight Rust reimplementation of Bitwarden server
#   - Compatible with all official Bitwarden clients (mobile, desktop, extension)
#   - Admin panel at https://vault.DOMAIN/admin (token-protected)
#   - Set SIGNUPS_ALLOWED=false after creating your accounts

# ── Metadata ──────────────────────────────────────────────────────────────────
SERVICE_NAME="vaultwarden"
SERVICE_LABEL="Vaultwarden — Password Manager (replaces 1Password / Bitwarden)"
SERVICE_CATEGORY="security"
SERVICE_REQUIRED=false
SERVICE_NEEDS_DOMAIN=true
SERVICE_NEEDS_EMAIL=false
SERVICE_RAM_MB=128
SERVICE_DISK_GB=1
SERVICE_DESCRIPTION="Self-hosted password manager. Works with all Bitwarden apps. Unlimited passwords, secure notes, and 2FA on your own hardware."

# Uptime Kuma check, seeded by lib/kuma.sh so it is recreated on a fresh
# install rather than living only in Kuma's database. Tab separated:
# name, url, accepted status codes. The name is the key, so changing it
# creates a second monitor and orphans the first.
SERVICE_MONITORS="Vaultwarden	https://vault.${DOMAIN:-}	[\"200-299\"]"

# ── Functions ─────────────────────────────────────────────────────────────────

vaultwarden_dirs() {
    mkdir -p "${DOCKER_ROOT}/vaultwarden" "${DATA_ROOT}/vaultwarden"
    chown -R 1000:1000 "${DATA_ROOT}/vaultwarden"
}

vaultwarden_firewall() {
    : # Traefik handles all HTTPS; no extra ports needed
}

# The admin panel manages every account on the server and is guarded by one
# token. It is published with the rest of the vault, so without this the
# internet could reach it. A second router on /admin carries the LAN allowlist:
# home and Tailscale keep the panel, a request through the tunnel gets a 403,
# and the vault itself stays reachable from anywhere.
#
# Written only when the allowlist middleware exists. A router naming a
# middleware Traefik cannot find answers 404 for the whole hostname rather
# than falling back (gotcha #44), which would take the vault down with it.
_vaultwarden_admin_labels() {
    local lan="${DOCKER_ROOT:-/mnt/corex-data/docker-configs}/traefik/dynamic/corex-lan.yml"
    [[ -f "$lan" ]] || return 0
    printf '%s\n' \
        "      - \"traefik.http.routers.vw-admin.rule=Host(\`vault.${DOMAIN}\`) && PathPrefix(\`/admin\`)\"" \
        "      - \"traefik.http.routers.vw-admin.entrypoints=websecure\"" \
        "      - \"traefik.http.routers.vw-admin.tls.certresolver=myresolver\"" \
        "      - \"traefik.http.routers.vw-admin.service=vw\"" \
        "      - \"traefik.http.routers.vw-admin.priority=1000\"" \
        "      - \"traefik.http.routers.vw-admin.middlewares=corex-lan@file\""
}

vaultwarden_deploy() {
    vaultwarden_dirs
    local dir="${DOCKER_ROOT}/vaultwarden"
    local admin_labels
    admin_labels="$(_vaultwarden_admin_labels)"
    [[ -n "$admin_labels" ]] || log_warning "Vaultwarden's admin panel is reachable wherever the vault is. Restrict it with: corex manage lan-only add <any router>"

    cat > "${dir}/docker-compose.yml" << DCEOF
services:
  vaultwarden:
    image: vaultwarden/server:latest
    container_name: vaultwarden
    restart: unless-stopped
    volumes:
      - ${DATA_ROOT}/vaultwarden:/data
    environment:
      DOMAIN: "https://vault.${DOMAIN}"
      ADMIN_TOKEN: "${VAULTWARDEN_ADMIN_TOKEN}"
      SIGNUPS_ALLOWED: "false"
      LOG_LEVEL: warn
    networks: [proxy-net]
    security_opt: ["no-new-privileges:true"]
    deploy:
      resources:
        limits:
          memory: 256m
          cpus: "0.5"
        reservations:
          memory: 64m
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.vw.rule=Host(\`vault.${DOMAIN}\`)"
      - "traefik.http.routers.vw.entrypoints=websecure"
      - "traefik.http.routers.vw.tls.certresolver=myresolver"
      - "traefik.http.services.vw.loadbalancer.server.port=80"
${admin_labels}
networks:
  proxy-net: { external: true }
DCEOF

    docker compose -f "${dir}/docker-compose.yml" up -d \
        || log_warning "Vaultwarden may not have started — check: docker ps"
    state_service_installed "vaultwarden"
    log_success "Vaultwarden deployed (vault.${DOMAIN})"
}

vaultwarden_destroy() {
    local dir="${DOCKER_ROOT}/vaultwarden"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" down
    state_service_removed "vaultwarden"
}

vaultwarden_status() {
    if container_running "vaultwarden"; then echo "HEALTHY"
    elif container_exists "vaultwarden"; then echo "UNHEALTHY"
    else echo "MISSING"; fi
}

vaultwarden_repair() {
    # Regenerate the compose file first. Without this, repair recreated the
    # container from a compose file that could be months old, so CoreX fixes
    # to env vars, resource limits, security_opt, published ports or Traefik
    # labels never reached an existing install. vaultwarden_deploy is idempotent
    # by design (see CLAUDE.md "Idempotency pattern"), so calling it here is
    # safe and is what makes `corex doctor` able to deliver fixes at all.
    vaultwarden_deploy
    local dir="${DOCKER_ROOT}/vaultwarden"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" up -d --force-recreate
}

vaultwarden_credentials() {
    echo "Vaultwarden: https://vault.${DOMAIN}"
    echo "  Admin panel: https://vault.${DOMAIN}/admin"
    echo "  Admin token: ${VAULTWARDEN_ADMIN_TOKEN}"
    echo "  Signups: DISABLED by default. To enable: set SIGNUPS_ALLOWED=true in compose"
    echo "  Create accounts via: admin panel → Users → Invite"
}
