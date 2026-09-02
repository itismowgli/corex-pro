#!/bin/bash
# lib/services/n8n.sh — CoreX Pro v2
# n8n — Workflow Automation (Zapier alternative)
#
# CRITICAL NOTES:
#   - Runs as user 1000:1000 (must match data dir ownership on SSD)
#   - N8N_PROTOCOL=https and WEBHOOK_URL are required for webhooks behind Traefik
#   - Without these, webhook URLs in n8n will show http:// and won't work externally

# ── Metadata ──────────────────────────────────────────────────────────────────
SERVICE_NAME="n8n"
SERVICE_LABEL="n8n — Workflow Automation (replaces Zapier / Make)"
SERVICE_CATEGORY="productivity"
SERVICE_REQUIRED=false
SERVICE_NEEDS_DOMAIN=true
SERVICE_NEEDS_EMAIL=false
SERVICE_RAM_MB=512
SERVICE_DISK_GB=2
SERVICE_DESCRIPTION="Visual workflow automation. Connect any app to any app. 400+ integrations. Replaces Zapier, Make (formerly Integromat), and IFTTT."

# ── Functions ─────────────────────────────────────────────────────────────────

n8n_dirs() {
    mkdir -p "${DOCKER_ROOT}/n8n" "${DATA_ROOT}/n8n"
    chown -R 1000:1000 "${DATA_ROOT}/n8n"
}

n8n_firewall() {
    ufw allow 5678/tcp comment 'n8n Workflow Automation' 2>/dev/null || true
}

# ── _n8n_subdomain ────────────────────────────────────────────────────────────
# The hostname n8n answers on, "n8n" unless overridden.
#
# A hostname can become unusable through no fault of the service. Google Safe
# Browsing flagged n8n.DOMAIN as a "Dangerous site" on a clean install, and
# once a name is flagged it is blocked in Chrome everywhere, including over the
# LAN, because the block is on the name and not on the address serving it. The
# service kept returning HTTP 200 the whole time.
#
# A review request through Google Search Console takes days and can recur, so
# the practical escape is a different name. Order of preference:
#
#   1. $N8N_SUBDOMAIN from the environment
#   2. n8n_subdomain in state.json, so it survives a repair
#   3. "n8n"
#
# Set it once and every generated file follows: the Traefik router, N8N_HOST
# and WEBHOOK_URL. Add the new name in Cloudflare if the service is published.
_n8n_subdomain() {
    local sub="${N8N_SUBDOMAIN:-}"
    if [[ -z "$sub" ]] && declare -f state_get >/dev/null 2>&1; then
        sub=$(state_get "n8n_subdomain" 2>/dev/null)
        [[ "$sub" == "null" ]] && sub=""
    fi
    printf '%s' "${sub:-n8n}"
}

n8n_deploy() {
    n8n_dirs
    local dir="${DOCKER_ROOT}/n8n"
    local sub
    sub=$(_n8n_subdomain)
    # Persist it, so a later repair regenerates the same hostname rather than
    # silently reverting to the default and breaking the URL again.
    if [[ "$sub" != "n8n" ]] && declare -f state_set >/dev/null 2>&1; then
        state_set "n8n_subdomain" "$sub" 2>/dev/null || true
    fi

    cat > "${dir}/docker-compose.yml" << DCEOF
services:
  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    ports: ["5678:5678"]
    user: "1000:1000"
    environment:
      N8N_HOST: "${sub}.${DOMAIN}"
      N8N_PORT: "5678"
      N8N_PROTOCOL: https
      WEBHOOK_URL: "https://${sub}.${DOMAIN}"
      N8N_ENCRYPTION_KEY: "${N8N_ENCRYPTION_KEY}"
      GENERIC_TIMEZONE: "${TIMEZONE}"
    volumes:
      - ${DATA_ROOT}/n8n:/home/node/.n8n
    networks: [proxy-net]
    deploy:
      resources:
        limits:
          memory: 512m
          cpus: "0.5"
        reservations:
          memory: 128m
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(\`${sub}.${DOMAIN}\`)"
      - "traefik.http.routers.n8n.entrypoints=websecure"
      - "traefik.http.routers.n8n.tls.certresolver=myresolver"
      - "traefik.http.services.n8n.loadbalancer.server.port=5678"
networks:
  proxy-net: { external: true }
DCEOF

    docker compose -f "${dir}/docker-compose.yml" up -d \
        || log_warning "n8n may not have started — check: docker ps"
    state_service_installed "n8n"
    log_success "n8n deployed (5678, n8n.${DOMAIN})"
}

n8n_destroy() {
    local dir="${DOCKER_ROOT}/n8n"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" down
    state_service_removed "n8n"
}

n8n_status() {
    if container_running "n8n"; then echo "HEALTHY"
    elif container_exists "n8n"; then echo "UNHEALTHY"
    else echo "MISSING"; fi
}

n8n_repair() {
    # Regenerate the compose file first. Without this, repair recreated the
    # container from a compose file that could be months old, so CoreX fixes
    # to env vars, resource limits, security_opt, published ports or Traefik
    # labels never reached an existing install. n8n_deploy is idempotent
    # by design (see CLAUDE.md "Idempotency pattern"), so calling it here is
    # safe and is what makes `corex doctor` able to deliver fixes at all.
    n8n_deploy
    local dir="${DOCKER_ROOT}/n8n"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" up -d --force-recreate
}

n8n_credentials() {
    echo "n8n: https://$(_n8n_subdomain).${DOMAIN} (create owner on first visit)"
    echo "  Encryption key: ${N8N_ENCRYPTION_KEY}"
}
