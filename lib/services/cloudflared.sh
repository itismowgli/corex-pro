#!/bin/bash
# lib/services/cloudflared.sh — CoreX Pro v2
# Cloudflare Tunnel — Secure External Access (zero port forwarding)
#
# CRITICAL NOTES:
#   - Must be on proxy-net to reach other containers by name
#   - In CF Dashboard, use CONTAINER NAMES not localhost as targets
#   - Enable "No TLS Verify" in CF dashboard for Traefik-proxied services
#   - Token comes from: one.dash.cloudflare.com → Networks → Tunnels

# ── Metadata ──────────────────────────────────────────────────────────────────
SERVICE_NAME="cloudflared"
SERVICE_LABEL="Cloudflare Tunnel — Secure External Access"
SERVICE_CATEGORY="core"
SERVICE_REQUIRED=false
SERVICE_NEEDS_DOMAIN=true
SERVICE_NEEDS_EMAIL=false
SERVICE_RAM_MB=64
SERVICE_DISK_GB=0
SERVICE_DESCRIPTION="Expose your services to the internet without opening any ports on your router. Encrypted tunnel through Cloudflare's network."

# ── Functions ─────────────────────────────────────────────────────────────────

cloudflared_dirs() {
    mkdir -p "${DOCKER_ROOT}/cloudflared"
}

cloudflared_firewall() {
    : # Cloudflared makes outbound connections only; no inbound ports needed
}

# ── _cloudflared_token ────────────────────────────────────────────────────────
# Resolve the tunnel token, in order of preference:
#
#   1. $CLOUDFLARE_TUNNEL_TOKEN from the environment (a fresh token wins)
#   2. ${DOCKER_ROOT}/cloudflared/.tunnel-token — the persisted copy
#   3. cloudflare_tunnel_token in state.json — legacy location, migrated out
#   4. the --token argument in an existing docker-compose.yml — last resort
#
# The token used to live in state.json, which is mode 0644 and bind-mounted
# into the dashboard container: a live tunnel credential inside a web-facing
# service. It now lives in a 0600 dotfile next to the service that needs it,
# matching every other CoreX secret. Sources 3 and 4 exist only so upgrading
# an installed box does not lose the token, and both migrate it forward.
_cloudflared_token() {
    local dir="${DOCKER_ROOT}/cloudflared"
    local token_file="${dir}/.tunnel-token"
    local token=""

    if [[ -n "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]] \
        && [[ "$CLOUDFLARE_TUNNEL_TOKEN" != "PASTE_YOUR_TUNNEL_TOKEN_HERE" ]]; then
        token="$CLOUDFLARE_TUNNEL_TOKEN"
    elif [[ -s "$token_file" ]]; then
        token=$(cat "$token_file")
    elif declare -f state_get >/dev/null 2>&1; then
        token=$(state_get "cloudflare_tunnel_token" 2>/dev/null)
        [[ "$token" == "null" ]] && token=""
    fi

    # Recover from the running compose file if nothing else has it. Without
    # this, a repair on a box whose state.json was rebuilt would find no token
    # and tear the tunnel down.
    if [[ -z "$token" && -f "${dir}/docker-compose.yml" ]]; then
        token=$(grep -m1 -oE -- '--token[[:space:]]+[^[:space:]]+' \
            "${dir}/docker-compose.yml" 2>/dev/null | awk '{print $2}')
    fi

    [[ -z "$token" || "$token" == "PASTE_YOUR_TUNNEL_TOKEN_HERE" ]] && return 1

    # Persist forward, then remove the legacy copy from state.json.
    mkdir -p "$dir"
    if [[ ! -s "$token_file" ]] || [[ "$(cat "$token_file")" != "$token" ]]; then
        printf '%s\n' "$token" > "$token_file"
        chmod 600 "$token_file"
    fi
    declare -f state_strip_secrets >/dev/null 2>&1 && state_strip_secrets

    printf '%s' "$token"
}

cloudflared_deploy() {
    cloudflared_dirs
    local dir="${DOCKER_ROOT}/cloudflared"

    # Resolve the token BEFORE touching the running container. The old order
    # was `docker rm -f cloudflared` and then the token check, so a repair on
    # a box with no token in state.json destroyed the live tunnel and then
    # returned a warning — one repair took all external access down.
    local token
    if ! token=$(_cloudflared_token); then
        log_warning "Cloudflare Tunnel skipped (no token configured)"
        log_warning "  Add your token later: corex-manage add cloudflared"
        if container_running "cloudflared"; then
            log_warning "  Existing tunnel left running — not touching it"
        fi
        return 0
    fi
    CLOUDFLARE_TUNNEL_TOKEN="$token"

    # Clean up any old container
    docker rm -f cloudflared 2>/dev/null || true

    cat > "${dir}/docker-compose.yml" << DCEOF
services:
  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared
    restart: unless-stopped
    command: tunnel --no-autoupdate run --token ${CLOUDFLARE_TUNNEL_TOKEN}
    networks: [proxy-net]
    security_opt: ["no-new-privileges:true"]
    deploy:
      resources:
        limits:
          memory: 128m
          cpus: "0.25"
        reservations:
          memory: 32m
networks:
  proxy-net: { external: true }
DCEOF
    # The compose file embeds the tunnel token on the command line, so it is
    # a credential file and must not be world-readable.
    chmod 600 "${dir}/docker-compose.yml"

    docker compose -f "${dir}/docker-compose.yml" up -d \
        || log_warning "Cloudflared may not have started — check: docker ps"
    state_service_installed "cloudflared"
    log_success "Cloudflare Tunnel active"
}

cloudflared_destroy() {
    local dir="${DOCKER_ROOT}/cloudflared"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" down
    state_service_removed "cloudflared"
}

cloudflared_status() {
    if container_running "cloudflared"; then echo "HEALTHY"
    elif container_exists "cloudflared"; then echo "UNHEALTHY"
    else echo "MISSING"; fi
}

cloudflared_repair() {
    # Regenerate the compose file first. Without this, repair recreated the
    # container from a compose file that could be months old, so CoreX fixes
    # to env vars, resource limits, security_opt, published ports or Traefik
    # labels never reached an existing install. cloudflared_deploy is idempotent
    # by design (see CLAUDE.md "Idempotency pattern"), so calling it here is
    # safe and is what makes `corex doctor` able to deliver fixes at all.
    cloudflared_deploy
    local dir="${DOCKER_ROOT}/cloudflared"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" up -d --force-recreate
}

cloudflared_credentials() {
    echo "Cloudflare Tunnel: managed at one.dash.cloudflare.com"
    echo "  Public Hostnames → use container names (not localhost)"
}
