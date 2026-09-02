#!/bin/bash
# lib/services/dashboard.sh — CoreX Pro v2
# CoreX Dashboard — Web UI (Go + HTMX, ~15MB image)
#
# NOTES:
#   - Single Go binary serving REST API + HTMX templates
#   - Auth via Traefik BasicAuth middleware (password in state.json)
#   - 5 tabs: Services, Storage, Monitoring, Network, System
#   - Shells out to corex-manage.sh — no direct Docker socket access
#   - Accessible at https://dashboard.DOMAIN

# ── Metadata ──────────────────────────────────────────────────────────────────
SERVICE_NAME="dashboard"
SERVICE_LABEL="CoreX Dashboard — Web UI (replaces CLI for daily ops)"
SERVICE_CATEGORY="core"
SERVICE_REQUIRED=false
SERVICE_NEEDS_DOMAIN=true
SERVICE_NEEDS_EMAIL=false
SERVICE_RAM_MB=64
SERVICE_DISK_GB=1
SERVICE_DESCRIPTION="Browser-based management UI. Start/stop/update services, view storage, stream logs, and manage SSL certificates — all without SSH."

# ── Functions ─────────────────────────────────────────────────────────────────

dashboard_dirs() {
    mkdir -p "${DOCKER_ROOT}/dashboard"
}

dashboard_firewall() {
    : # Traefik handles all HTTPS; no extra ports needed
}

dashboard_deploy() {
    dashboard_dirs
    local dir="${DOCKER_ROOT}/dashboard"

    # Generate the BasicAuth password if not set, and PERSIST it.
    #
    # This must be stable across re-runs: repair calls deploy (so that compose
    # fixes actually reach existing installs), and a freshly generated password
    # here would silently change the dashboard login to a value nothing
    # records — locking the operator out of the GUI with no way back except
    # reading this file. Kept out of corex-credentials.txt because that file's
    # format is parsed by exact grep patterns in phase 0.
    local pass_file="${dir}/.dashboard-password"
    if [[ -z "${DASHBOARD_PASS:-}" ]] && [[ -s "$pass_file" ]]; then
        DASHBOARD_PASS=$(cat "$pass_file")
    fi
    if [[ -z "${DASHBOARD_PASS:-}" ]]; then
        DASHBOARD_PASS=$(openssl rand -base64 32 | tr -d '/+=' | head -c 24)
    fi
    printf '%s' "$DASHBOARD_PASS" > "$pass_file"
    chmod 600 "$pass_file"
    export DASHBOARD_PASS

    # Generate htpasswd hash for Traefik BasicAuth
    local DASHBOARD_HASH
    DASHBOARD_HASH=$(openssl passwd -apr1 "${DASHBOARD_PASS}" | sed 's/\$/\$\$/g')

    # The container needs to read the Docker socket to report service health.
    # Without membership of the socket's group every `docker ps` fails with
    # "permission denied", which made the GUI report all services UNHEALTHY
    # while they were running perfectly. Adding the group beats running the
    # container as root.
    local docker_gid
    docker_gid=$(stat -c '%g' /var/run/docker.sock 2>/dev/null || echo 999)

    cat > "${dir}/docker-compose.yml" << DCEOF
services:
  dashboard:
    # Built from source in this repo rather than pulled.
    #
    # ghcr.io/itismowgli/corex-dashboard:latest was never published — pulling
    # it fails with "error from registry: denied", which meant the dashboard
    # documented as auto-installed since v3.0.0 had in fact never started for
    # anyone. All the sources are in dashboard/ (main.go plus templates and
    # static embedded via //go:embed), so building locally removes the
    # registry dependency entirely. pull_policy: build stops Compose trying
    # the registry first. First install spends ~1-2 min compiling.
    image: corex-dashboard:local
    build:
      context: ${SCRIPT_DIR:-/opt/corex-pro}/dashboard
      dockerfile: Dockerfile
    pull_policy: build
    container_name: corex-dashboard
    restart: unless-stopped
    group_add:
      - "${docker_gid}"
    volumes:
      # /root/corex-credentials.txt was mounted here and never read by the
      # dashboard. It is 0600 root and the container runs as nobody, so the
      # mount only ever exposed every service password to a web-facing
      # container without granting it anything.
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /etc/corex:/etc/corex:ro
      - ${SCRIPT_DIR:-/opt/corex-pro}:/opt/corex-pro:ro
    environment:
      COREX_MANAGE: "/opt/corex-pro/corex-manage.sh"
      SERVER_IP: "${SERVER_IP}"
      DOMAIN: "${DOMAIN}"
    networks: [proxy-net]
    security_opt: ["no-new-privileges:true"]
    deploy:
      resources:
        limits:
          memory: 128m
          cpus: "0.25"
        reservations:
          memory: 32m
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.dashboard.rule=Host(\`dashboard.${DOMAIN}\`)"
      - "traefik.http.routers.dashboard.entrypoints=websecure"
      - "traefik.http.routers.dashboard.tls.certresolver=myresolver"
      - "traefik.http.services.dashboard.loadbalancer.server.port=8080"
      - "traefik.http.middlewares.dash-auth.basicauth.users=admin:${DASHBOARD_HASH}"
      - "traefik.http.routers.dashboard.middlewares=dash-auth"
networks:
  proxy-net: { external: true }
DCEOF

    # Build + start. The build can take a couple of minutes on first install.
    log_info "Building the dashboard image (first run takes 1-2 minutes)..."
    docker compose -f "${dir}/docker-compose.yml" up -d --build 2>&1 | tail -5

    # Verify it is ACTUALLY running before claiming success. The previous
    # version logged "deployed" even when the image pull had failed, so a
    # completely absent dashboard reported as installed — which is how this
    # went unnoticed from v3.0.0 onwards.
    local up=false i
    for i in $(seq 1 12); do
        if container_running "corex-dashboard"; then up=true; break; fi
        sleep 5
    done

    state_service_installed "dashboard"
    if [[ "$up" == "true" ]]; then
        log_success "CoreX Dashboard deployed (https://dashboard.${DOMAIN})"
        log_info "  Login: admin / $(cat "${dir}/.dashboard-password" 2>/dev/null)"
    else
        log_warning "Dashboard container did not start. Check:"
        echo "    docker compose -f ${dir}/docker-compose.yml logs"
        echo "    docker compose -f ${dir}/docker-compose.yml build"
    fi
}

dashboard_destroy() {
    local dir="${DOCKER_ROOT}/dashboard"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" down
    state_service_removed "dashboard"
}

dashboard_status() {
    if container_running "corex-dashboard"; then echo "HEALTHY"
    elif container_exists "corex-dashboard"; then echo "UNHEALTHY"
    else echo "MISSING"; fi
}

dashboard_repair() {
    # Regenerate the compose file first. Without this, repair recreated the
    # container from a compose file that could be months old, so CoreX fixes
    # to env vars, resource limits, security_opt, published ports or Traefik
    # labels never reached an existing install. dashboard_deploy is idempotent
    # by design (see CLAUDE.md "Idempotency pattern"), so calling it here is
    # safe and is what makes `corex doctor` able to deliver fixes at all.
    dashboard_deploy
    local dir="${DOCKER_ROOT}/dashboard"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" up -d --force-recreate
}

dashboard_credentials() {
    echo "CoreX Dashboard: https://dashboard.${DOMAIN}"
    echo "  Username: admin"
    echo "  Password: ${DASHBOARD_PASS:-see credentials file}"
}
