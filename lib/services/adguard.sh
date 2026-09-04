#!/bin/bash
# lib/services/adguard.sh — CoreX Pro v2
# AdGuard Home — DNS Server & Ad Blocker
#
# CRITICAL NOTES:
#   - FIRST RUN: wizard listens on port 3000 inside container
#   - AFTER SETUP: switches to port 80 inside container (or configured port)
#   - We detect which state we're in from AdGuardHome.yaml
#   - systemd-resolved MUST be disabled; resolv.conf locked with chattr +i
#   - After setup: add DNS rewrites *.domain → SERVER_IP in AdGuard UI

# ── Metadata ──────────────────────────────────────────────────────────────────
SERVICE_NAME="adguard"
SERVICE_LABEL="AdGuard Home — DNS & Ad Blocker"
SERVICE_CATEGORY="core"
SERVICE_REQUIRED=true
SERVICE_NEEDS_DOMAIN=false
SERVICE_NEEDS_EMAIL=false
SERVICE_RAM_MB=64
SERVICE_DISK_GB=1
# UFW rules this service opens, as full `ufw allow` specs. cmd_remove
# revokes them, because leaving a port open with nothing behind it is all
# of the exposure and none of the service.
SERVICE_FIREWALL_SPECS=("53" "3000/tcp" "5353/udp")
SERVICE_DESCRIPTION="Network-wide ad blocker and DNS server. Blocks ads on all devices. Required for local domain routing (*.yourdomain → server IP)."

# Uptime Kuma check, seeded by lib/kuma.sh so it is recreated on a fresh
# install rather than living only in Kuma's database. Tab separated:
# name, url, accepted status codes. The name is the key, so changing it
# creates a second monitor and orphans the first.
SERVICE_MONITORS="AdGuard Home	http://${SERVER_IP:-}:3000	[\"200-299\",\"302\"]"

# ── Functions ─────────────────────────────────────────────────────────────────

adguard_dirs() {
    mkdir -p "${DOCKER_ROOT}/adguard"
    mkdir -p "${DATA_ROOT}/adguard-work" "${DATA_ROOT}/adguard-conf"
}

adguard_firewall() {
    ufw allow 53    comment 'DNS (AdGuard Home, TCP+UDP)'    2>/dev/null || true
    ufw allow 3000/tcp comment 'AdGuard Home Setup UI'       2>/dev/null || true
    ufw allow 5353/udp comment 'mDNS (Avahi/Bonjour)'       2>/dev/null || true
}

adguard_deploy() {
    mkdir -p "${DOCKER_ROOT}/adguard"
    mkdir -p "${DATA_ROOT}/adguard-work" "${DATA_ROOT}/adguard-conf"
    local dir="${DOCKER_ROOT}/adguard"

    # Disable systemd-resolved which holds port 53
    systemctl disable --now systemd-resolved 2>/dev/null || true
    # The lock has to come off before the file can be replaced. A previous run
    # of this function set it (gotcha #7), so on every run after the first the
    # rm failed with EPERM and the file was left exactly as it was. Nothing
    # said so, because the failure was the last command in a function nobody
    # checked the status of.
    chattr -i /etc/resolv.conf 2>/dev/null || true
    rm -f /etc/resolv.conf 2>/dev/null || true
    printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /etc/resolv.conf 2>/dev/null \
        || log_warning "Could not rewrite /etc/resolv.conf"
    # Lock again so systemd-resolved cannot overwrite it on reboot.
    chattr +i /etc/resolv.conf 2>/dev/null || true

    # AdGuard moves its own admin port from 3000 to 80 once the setup wizard
    # has run, so the port has to be read from its config and never assumed.
    #
    # Reading it is fussier than it looks. `grep -A5 "http:"` used to be
    # enough and is not any more: current AdGuard writes pprof and a doh
    # routes list inside the http block first, so `address:` is eleven lines
    # down and the window missed it. The fallback was 3000, which produced a
    # `3000:3000` mapping against a container listening on 80, and the admin
    # panel simply stopped answering on the LAN. `corex manage lan-setup` was
    # fixed for this in v2.1.1; this copy was not.
    #
    # The address line is matched at its own indentation, two spaces, so it is
    # a direct child of http: and cannot be confused with bind_hosts or a
    # bootstrap entry elsewhere in the file.
    local ADGUARD_INTERNAL_PORT="3000"
    local yaml="${DATA_ROOT}/adguard-conf/AdGuardHome.yaml"
    if [[ -f "$yaml" ]]; then
        local CONFIGURED_PORT
        CONFIGURED_PORT=$(sed -n '/^http:/,/^[a-z_]/p' "$yaml" \
            | grep -m1 '^  address:' | grep -oE '[0-9]+$')
        if [[ -n "$CONFIGURED_PORT" ]]; then
            ADGUARD_INTERNAL_PORT="$CONFIGURED_PORT"
            log_info "AdGuard already configured, internal port is $ADGUARD_INTERNAL_PORT"
        else
            log_warning "Could not read the admin port from ${yaml}, assuming 3000"
        fi
    else
        log_info "AdGuard first run, the wizard will listen on port 3000"
    fi

    # AdGuard gets a Traefik router so the shared login can be put in front
    # of it. It did not have one before: the admin panel was reached on
    # SERVER_IP:3000 and nothing else, which is fine on the LAN and means the
    # panel has only its own password when it is reached over the tunnel.
    #
    # Port 3000 stays published, and that is the point rather than an
    # oversight. AdGuard is the DNS, so auth.DOMAIN does not resolve on the
    # LAN while AdGuard is down: a login that needs DNS must never be the only
    # way to fix DNS.
    local sso_label=""
    declare -f sso_label_for >/dev/null 2>&1 && sso_label="$(sso_label_for adguard)"

    # No domain means no router. AdGuard is the one module that installs in
    # local-only mode, and a Host rule built from an empty domain is
    # `Host(`adguard.`)`, which Traefik rejects.
    local adguard_labels=""
    if [[ -n "${DOMAIN:-}" ]]; then
        adguard_labels="$(cat << ALEOF
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.adguard.rule=Host(\`adguard.${DOMAIN}\`)"
      - "traefik.http.routers.adguard.entrypoints=websecure"
      - "traefik.http.routers.adguard.tls.certresolver=myresolver"
      # The port inside the container, which AdGuard moves from 3000 to 80
      # once its setup wizard has run, so it is read from AdGuardHome.yaml
      # rather than hardcoded. No apostrophe in this comment on purpose: it is
      # a heredoc body inside a command substitution, and bash scans that for
      # quotes, so one apostrophe here is an unterminated string.
      # See CLAUDE.md "Heredoc markers convention".
      - "traefik.http.services.adguard.loadbalancer.server.port=${ADGUARD_INTERNAL_PORT}"
${sso_label}
ALEOF
)"
    fi

    cat > "${dir}/docker-compose.yml" << DCEOF
services:
  adguard:
    image: adguard/adguardhome:latest
    container_name: adguard
    restart: unless-stopped
    ports:
      - "53:53/tcp"
      - "53:53/udp"
      - "3000:${ADGUARD_INTERNAL_PORT}/tcp"
    volumes:
      - ${DATA_ROOT}/adguard-work:/opt/adguardhome/work
      - ${DATA_ROOT}/adguard-conf:/opt/adguardhome/conf
    networks: [proxy-net]
    deploy:
      resources:
        limits:
          memory: 256m
          cpus: "0.5"
        reservations:
          memory: 64m
${adguard_labels}
networks:
  proxy-net: { external: true }
DCEOF

    docker compose -f "${dir}/docker-compose.yml" up -d \
        || log_warning "AdGuard may not have started — check: docker ps"
    state_service_installed "adguard"
    log_success "AdGuard Home deployed (DNS:53, Admin:3000)"
}

adguard_destroy() {
    local dir="${DOCKER_ROOT}/adguard"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" down
    state_service_removed "adguard"
}

adguard_status() {
    if container_running "adguard"; then echo "HEALTHY"
    elif container_exists "adguard"; then echo "UNHEALTHY"
    else echo "MISSING"; fi
}

adguard_repair() {
    # Regenerate the compose file first. Without this, repair recreated the
    # container from a compose file that could be months old, so CoreX fixes
    # to env vars, resource limits, security_opt, published ports or Traefik
    # labels never reached an existing install. adguard_deploy is idempotent
    # by design (see CLAUDE.md "Idempotency pattern"), so calling it here is
    # safe and is what makes `corex doctor` able to deliver fixes at all.
    adguard_deploy
    local dir="${DOCKER_ROOT}/adguard"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" up -d --force-recreate
}

adguard_credentials() {
    echo "AdGuard Home: http://${SERVER_IP}:3000 (set during wizard)"
}
