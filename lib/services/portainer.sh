#!/bin/bash
# lib/services/portainer.sh — CoreX Pro v2
# Portainer CE — Docker Management UI
#
# CRITICAL NOTES:
#   - Uses HTTPS on port 9443 with a self-signed cert (browser warning is normal)
#   - Traefik label must use scheme=https (Portainer speaks HTTPS, not HTTP)
#   - Data stored on SSD (not anonymous volume) so it's included in backups
#   - FIRST VISITOR BECOMES ADMIN — create account immediately after install

# ── Metadata ──────────────────────────────────────────────────────────────────
SERVICE_NAME="portainer"
SERVICE_LABEL="Portainer — Docker Management UI"
SERVICE_CATEGORY="core"
SERVICE_REQUIRED=true
SERVICE_NEEDS_DOMAIN=false
SERVICE_NEEDS_EMAIL=false
SERVICE_RAM_MB=128
SERVICE_DISK_GB=1
# UFW rules this service opens, as full `ufw allow` specs. cmd_remove
# revokes them, because leaving a port open with nothing behind it is all
# of the exposure and none of the service.
SERVICE_FIREWALL_SPECS=("9443/tcp")
SERVICE_DESCRIPTION="Web UI to manage all your Docker containers, images, and volumes. Replaces the Docker CLI for most tasks."

# Uptime Kuma check, seeded by lib/kuma.sh so it is recreated on a fresh
# install rather than living only in Kuma's database. Tab separated:
# name, url, accepted status codes. The name is the key, so changing it
# creates a second monitor and orphans the first.
# 302 is accepted because a service behind the shared login answers with a
# redirect to the portal, and that redirect means the router is up and the
# portal is answering. Without it the monitor reported Portainer DOWN the
# moment Authelia went in front of it, and a monitor that cries wolf is worse
# than no monitor: it trains you to ignore the next alert.
SERVICE_MONITORS="Portainer	https://portainer.${DOMAIN:-}	[\"200-299\",\"302\"]"

# ── Functions ─────────────────────────────────────────────────────────────────

portainer_dirs() {
    mkdir -p "${DOCKER_ROOT}/portainer" "${DATA_ROOT}/portainer"
    chown -R 1000:1000 "${DATA_ROOT}/portainer"
}

portainer_firewall() {
    ufw allow 9443/tcp comment 'Portainer (HTTPS UI)' 2>/dev/null || true
}

portainer_deploy() {
    mkdir -p "${DOCKER_ROOT}/portainer" "${DATA_ROOT}/portainer"
    chown -R 1000:1000 "${DATA_ROOT}/portainer"
    local dir="${DOCKER_ROOT}/portainer"

    # The shared login, when Authelia is installed and lists this router.
    # Empty otherwise: an empty middlewares label is rejected by Traefik, and
    # a label naming a middleware that does not exist puts the router into an
    # error state and answers 404. See sso_label_for in lib/common.sh.
    local sso_label=""
    declare -f sso_label_for >/dev/null 2>&1 && sso_label="$(sso_label_for portainer)"

    local cold_labels=""
    if declare -f state_get >/dev/null && [[ "$(state_get cold_portainer 2>/dev/null)" == true ]]; then
        # Append after shared authentication, never replace/bypass it.
        if [[ -n "$sso_label" ]]; then
            sso_label="${sso_label%\"},portainer-cold\""
        else
            sso_label='      - "traefik.http.routers.portainer.middlewares=portainer-cold"'
        fi
        cold_labels=$(cat <<'LABELS'
      - "sablier.enable=true"
      - "sablier.group=corex-portainer"
      - "traefik.docker.allownonrunning=true"
      - "traefik.http.middlewares.portainer-cold.plugin.sablier.group=corex-portainer"
      - "traefik.http.middlewares.portainer-cold.plugin.sablier.sablierUrl=http://corex-sablier:10000"
      - "traefik.http.middlewares.portainer-cold.plugin.sablier.sessionDuration=15m"
      - "traefik.http.middlewares.portainer-cold.plugin.sablier.keepAliveInterval=30s"
      - "traefik.http.middlewares.portainer-cold.plugin.sablier.dynamic.displayName=Portainer is waking up"
      - "traefik.http.middlewares.portainer-cold.plugin.sablier.dynamic.showDetails=false"
      - "traefik.http.middlewares.portainer-cold.plugin.sablier.ignoreUserAgent=(?i)uptime-kuma"
LABELS
)
    fi

    cat > "${dir}/docker-compose.yml" << DCEOF
services:
  portainer:
    # Pin the deployed release so a routine repair cannot apply an unreviewed
    # database migration or behavior change from the floating latest tag.
    image: portainer/portainer-ce:2.45.0
    container_name: portainer
    restart: unless-stopped
    ports: ["9443:9443"]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ${DATA_ROOT}/portainer:/data
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
      - "traefik.http.routers.portainer.rule=Host(\`portainer.${DOMAIN}\`)"
      - "traefik.http.routers.portainer.entrypoints=websecure"
      - "traefik.http.routers.portainer.tls.certresolver=myresolver"
      - "traefik.http.services.portainer.loadbalancer.server.port=9443"
      - "traefik.http.services.portainer.loadbalancer.server.scheme=https"
      # Portainer's self-signed cert is issued for 0.0.0.0, so Traefik cannot
      # verify it against the container IP and returns 500 for every request.
      # insecure-backend@file skips verification for this backend only.
      - "traefik.http.services.portainer.loadbalancer.serverstransport=insecure-backend@file"
${sso_label}
${cold_labels}
networks:
  proxy-net: { external: true }
DCEOF

    local up_args=(-d)
    [[ "${PORTAINER_FORCE_RECREATE:-false}" == "true" ]] && up_args+=(--force-recreate)
    docker compose -f "${dir}/docker-compose.yml" up "${up_args[@]}" \
        || { log_warning "Portainer did not start. Check: docker ps"; return 1; }
    state_service_installed "portainer"
    log_success "Portainer deployed (https://${SERVER_IP}:9443)"
}

portainer_destroy() {
    local dir="${DOCKER_ROOT}/portainer"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" down
    state_service_removed "portainer"
}

portainer_status() {
    if container_running "portainer"; then echo "HEALTHY"
    elif container_exists "portainer"; then
        if declare -f state_get >/dev/null && [[ "$(state_get cold_portainer 2>/dev/null)" == true ]] &&
            [[ "$(docker inspect -f '{{.State.ExitCode}}' portainer 2>/dev/null)" == 0 ]]; then echo "SLEEPING"
        else echo "UNHEALTHY"; fi
    else echo "MISSING"; fi
}

portainer_repair() {
    # Regenerate the compose file first. Without this, repair recreated the
    # container from a compose file that could be months old, so CoreX fixes
    # to env vars, resource limits, security_opt, published ports or Traefik
    # labels never reached an existing install. portainer_deploy is idempotent
    # by design (see CLAUDE.md "Idempotency pattern"), so calling it here is
    # safe and is what makes `corex doctor` able to deliver fixes at all.
    # Regenerate and force-recreate in one Compose pass. A second `up` caused
    # two back-to-back restarts for every repair.
    PORTAINER_FORCE_RECREATE=true portainer_deploy
}

portainer_credentials() {
    echo "Portainer: https://${SERVER_IP}:9443 (create admin on first visit)"
}
