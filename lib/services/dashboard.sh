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

# ── Thermal gate ──────────────────────────────────────────────────────────────
# The image build compiles a TypeScript app and a Go binary, which is minutes
# of full-CPU work, and this class of hardware trips at TjMax with no warning
# (gotcha #17). Starting one on an already-hot box is how a dashboard rebuild
# becomes an unplanned power cut, so it is refused rather than merely logged.
_dashboard_thermal_gate() {
    local t=0 z v
    if command -v sensors &>/dev/null; then
        t=$(sensors -u 2>/dev/null | awk '/^(Tctl|Tdie|Package id 0):/{getline; print $2; exit}')
    fi
    if [[ -z "${t:-}" || "$t" == "0" ]]; then
        for z in /sys/class/thermal/thermal_zone*/temp; do
            [[ -r "$z" ]] || continue
            v=$(( $(cat "$z" 2>/dev/null || echo 0) / 1000 ))
            (( v > ${t%%.*} )) && t=$v
        done
    fi
    t=${t%%.*}; t=${t:-0}
    (( t == 0 )) && return 0          # no sensor is not a reason to refuse

    if (( t >= 85 )); then
        log_error "CPU is at ${t}C. The dashboard build would very likely trip the thermal cutout. Let it cool and retry."
    elif (( t >= 78 )); then
        log_warning "CPU is at ${t}C before a multi-minute build. Watch: corex manage health"
    fi
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

    # The action buttons go through the CoreX agent's unix socket, which is
    # 0660 root:corex-agent. Joining that group is what makes them work while
    # the container keeps running as nobody: corex-manage.sh needs root, and
    # the alternatives were running this container as root or giving it sudo.
    local agent_gid group_block
    agent_gid=$(getent group corex-agent 2>/dev/null | cut -d: -f3)
    group_block="      - \"${docker_gid}\""
    [[ -n "$agent_gid" ]] && group_block="${group_block}"$'\n'"      - \"${agent_gid}\""

    cat > "${dir}/docker-compose.yml" << DCEOF
services:
  dashboard:
    # Built from source in this repo rather than pulled.
    #
    # ghcr.io/itismowgli/corex-dashboard:latest was never published — pulling
    # it fails with "error from registry: denied", which meant the dashboard
    # documented as auto-installed since v3.0.0 had in fact never started for
    # anyone. All the sources are in dashboard/: a Vite and React app under
    # web/, built in the first Dockerfile stage, then embedded into the Go
    # binary with //go:embed. pull_policy: build stops Compose trying the
    # registry first. First install spends a few minutes compiling.
    image: corex-dashboard:local
    build:
      context: ${SCRIPT_DIR:-/opt/corex-pro}/dashboard
      dockerfile: Dockerfile
    pull_policy: build
    container_name: corex-dashboard
    restart: unless-stopped
    group_add:
${group_block}
    volumes:
      # /root/corex-credentials.txt was mounted here and never read by the
      # dashboard. It is 0600 root and the container runs as nobody, so the
      # mount only ever exposed every service password to a web-facing
      # container without granting it anything.
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /etc/corex:/etc/corex:ro
      # The directory, not the socket itself. Bind-mounting the socket file
      # pins one inode, so restarting the agent would leave the dashboard
      # holding a stale mount and every button failing until the container was
      # restarted too.
      - /run/corex:/run/corex
      - ${SCRIPT_DIR:-/opt/corex-pro}:/opt/corex-pro:ro
    environment:
      COREX_MANAGE: "/opt/corex-pro/corex-manage.sh"
      COREX_AGENT_SOCKET: "/run/corex/agent.sock"
      COREX_AGENT_TOKEN_FILE: "/etc/corex/agent.token"
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

    # Build, then start. Two compilers run here, npm and go, so it is the
    # second hottest thing CoreX does after a service with no published image
    # (gotcha #31). It is refused outright on an already-hot box and runs at
    # the lowest priority either way, so the thermal guardian wins any
    # argument with it. BuildKit ignores --cpuset-cpus, which is why nice is
    # the lever here rather than a CPU mask.
    _dashboard_thermal_gate
    log_info "Building the dashboard image (npm then go, a few minutes on first install)..."
    # The exit status is checked, and taken from the build rather than from
    # tail. A failed build followed by `up -d` starts the previous image, the
    # container comes up, and every check after this point passes: the script
    # reported "deployed" on an image that had not been built, which is the
    # same class of fault as reporting a service healthy because its container
    # is running. PIPESTATUS because the pipe would otherwise hand us tail's
    # status, which is always zero.
    local build_rc=0
    nice -n 19 docker compose -f "${dir}/docker-compose.yml" build 2>&1 | tail -25
    build_rc=${PIPESTATUS[0]}
    if (( build_rc != 0 )); then
        log_warning "The dashboard image failed to build (exit ${build_rc}). The previous image is untouched."
        echo "    Reproduce it with:"
        echo "      cd ${dir} && docker compose build"
        echo "    Build the interface on its own for a clearer error:"
        echo "      cd ${SCRIPT_DIR:-/opt/corex-pro}/dashboard/web && npm ci && npm run build"
        return 1
    fi
    docker compose -f "${dir}/docker-compose.yml" up -d 2>&1 | tail -5

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
