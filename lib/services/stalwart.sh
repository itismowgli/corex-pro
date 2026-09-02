#!/bin/bash
# lib/services/stalwart.sh — CoreX Pro v2
# Stalwart Mail — Full Email Server (Gmail alternative)
#
# CRITICAL NOTES:
#   - Admin password is AUTO-GENERATED on first run and printed to container logs
#   - Capture with: docker logs stalwart | grep -oP "password '\K[^']+"
#   - REQUIRES a proper domain with MX/SPF/DKIM/DMARC DNS records
#   - Ports 25, 587, 465, 143, 993 must be open (ISPs sometimes block 25)
#   - Change admin password immediately after first login

# ── Metadata ──────────────────────────────────────────────────────────────────
SERVICE_NAME="stalwart"
SERVICE_LABEL="Stalwart Mail — Email Server (replaces Gmail / Fastmail)"
SERVICE_CATEGORY="communication"
SERVICE_REQUIRED=false
SERVICE_NEEDS_DOMAIN=true
SERVICE_NEEDS_EMAIL=false
SERVICE_RAM_MB=512
SERVICE_DISK_GB=5
SERVICE_DESCRIPTION="Self-hosted email server with SMTP, IMAP, CalDAV, and CardDAV. Full email independence. Requires a proper domain with DNS records configured."

# ── Functions ─────────────────────────────────────────────────────────────────

stalwart_dirs() {
    mkdir -p "${DOCKER_ROOT}/stalwart" "${DATA_ROOT}/stalwart-data"
    chown -R 1000:1000 "${DATA_ROOT}/stalwart-data"
}

stalwart_firewall() {
    ufw allow 25/tcp  comment 'SMTP (inbound mail)'             2>/dev/null || true
    ufw allow 587/tcp comment 'SMTP Submission (outbound mail)' 2>/dev/null || true
    ufw allow 465/tcp comment 'SMTPS (encrypted submission)'    2>/dev/null || true
    ufw allow 143/tcp comment 'IMAP (mail retrieval)'           2>/dev/null || true
    ufw allow 993/tcp comment 'IMAPS (encrypted mail retrieval)' 2>/dev/null || true
}

_stalwart_write_compose() {
    stalwart_dirs
    local dir="${DOCKER_ROOT}/stalwart"

    # Generate the admin password up front so it is known, not log-scraped.
    #
    # It must also be STABLE across re-runs. The previous version regenerated
    # it whenever STALWART_ADMIN_PASS was unset — the case for every
    # `corex manage repair stalwart` — so a repair silently changed the
    # administrator password to a value nothing recorded. Persisted in its own
    # 0600 file rather than corex-credentials.txt, whose format is parsed by
    # exact grep patterns in phase 0 (CLAUDE.md "What NOT to Do" #2).
    local pass_file="${dir}/.admin-password"
    if [[ -z "${STALWART_ADMIN_PASS:-}" ]] && [[ -s "$pass_file" ]]; then
        STALWART_ADMIN_PASS=$(cat "$pass_file")
    fi
    if [[ -z "${STALWART_ADMIN_PASS:-}" ]]; then
        STALWART_ADMIN_PASS=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
    fi
    printf '%s' "$STALWART_ADMIN_PASS" > "$pass_file"
    chmod 600 "$pass_file"
    export STALWART_ADMIN_PASS

    cat > "${dir}/docker-compose.yml" << DCEOF
services:
  stalwart:
    image: stalwartlabs/stalwart:latest
    container_name: stalwart
    restart: unless-stopped
    tty: true
    stdin_open: true
    ports:
      - "25:25"
      - "587:587"
      - "465:465"
      - "143:143"
      - "993:993"
      - "4190:4190"
    volumes:
      - ${DATA_ROOT}/stalwart-data:/opt/stalwart-mail
    environment:
      # Pin the administrator credential on first run.
      #
      # STALWART_ADMIN_USER / STALWART_ADMIN_SECRET are NOT read by current
      # Stalwart images. Setting them looked correct but did nothing, so
      # Stalwart fell back to "bootstrap mode": it generated its own random
      # temporary password, printed it once to the container log, and CoreX's
      # generated password was never in effect. If that log line was missed or
      # rotated away the instance became permanently unreachable — observed in
      # the field as a mail server nobody could ever log into.
      #
      # STALWART_RECOVERY_ADMIN is the supported variable, in user:password
      # form, and Stalwart's own bootstrap log message points at it.
      STALWART_RECOVERY_ADMIN: "admin:${STALWART_ADMIN_PASS}"
    networks: [proxy-net]
    deploy:
      resources:
        limits:
          memory: 512m
          cpus: "1.0"
        reservations:
          memory: 128m
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.mail.rule=Host(\`mail.${DOMAIN}\`)"
      - "traefik.http.routers.mail.entrypoints=websecure"
      - "traefik.http.routers.mail.tls.certresolver=myresolver"
      - "traefik.http.services.mail.loadbalancer.server.port=8080"
networks:
  proxy-net: { external: true }
DCEOF
}

stalwart_deploy() {
    _stalwart_write_compose
    # `dir` is local to the writer, so it must be re-declared here.
    local dir="${DOCKER_ROOT}/stalwart"

    docker compose -f "${dir}/docker-compose.yml" up -d \
        || log_warning "Stalwart may not have started — check: docker ps"

    state_service_installed "stalwart"
    log_success "Stalwart Mail deployed (SMTP:25/587, IMAP:993, mail.${DOMAIN})"
    log_info "Admin login: admin / password in ${dir}/.admin-password"
}

stalwart_destroy() {
    local dir="${DOCKER_ROOT}/stalwart"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" down
    state_service_removed "stalwart"
}

# ── _stalwart_proxy_banned ────────────────────────────────────────────────────
# Return 0 if Stalwart has banned one of the reverse proxies in front of it.
#
# Stalwart bans a source IP that probes scanner paths. Behind a proxy it sees
# the proxy's container IP, not the scanner's, so a single bot request to
# https://mail.DOMAIN//wp-content/.env bans cloudflared or Traefik — and with
# it every visitor arriving that way. Observed in the field: external mail
# access was dead for hours while the container reported healthy, because
# Traefik had a different container IP and the LAN path kept working.
#
# The durable fix is Stalwart's own proxy settings, which need a configured
# store (see stalwart_credentials and CLAUDE.md gotcha #23). Until then this
# at least makes the condition visible instead of silent.
_stalwart_proxy_banned() {
    container_running "stalwart" || return 1

    local proxy_ips="" c ip
    for c in cloudflared traefik; do
        container_running "$c" || continue
        ip=$(docker inspect "$c" \
            --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' \
            2>/dev/null)
        proxy_ips+=" $ip"
    done
    [[ -n "${proxy_ips// /}" ]] || return 1

    # Only consider bans since the container last started. Stalwart's ban list
    # is in memory, so a restart clears it — a fixed --since window reports a
    # ban that no longer exists.
    local started recent
    started=$(docker inspect stalwart --format '{{.State.StartedAt}}' 2>/dev/null)
    [[ -n "$started" ]] || return 1
    recent=$(docker logs --since "$started" stalwart 2>&1 \
        | grep -E "security.scan-ban|security.ip-blocked" | tail -50)
    [[ -n "$recent" ]] || return 1

    for ip in $proxy_ips; do
        [[ -n "$ip" ]] || continue
        # Pattern match rather than `| grep -q`, for the pipefail/SIGPIPE
        # reason described in _stalwart_bootstrap_mode.
        [[ "$recent" == *"$ip"* ]] && return 0
    done
    return 1
}

# ── _stalwart_bootstrap_mode ──────────────────────────────────────────────────
# Return 0 if Stalwart is still in bootstrap mode, meaning initial setup was
# never completed and nothing is persisted. A bootstrap-mode server answers
# HTTP and looks healthy but cannot send or receive mail.
_stalwart_bootstrap_mode() {
    container_running "stalwart" || return 1
    # No pipe into `grep -q` here: grep exits on the first match, docker logs
    # takes SIGPIPE, and `set -o pipefail` reports the pipeline as failing
    # with 141. Under pipefail that inverts the result of every such check, so
    # this reported "not in bootstrap mode" precisely when it was.
    local logs
    logs=$(docker logs stalwart 2>&1) || true
    [[ "$logs" == *"server.bootstrap-mode"* ]]
}

stalwart_status() {
    if ! container_running "stalwart"; then
        if container_exists "stalwart"; then echo "UNHEALTHY"; else echo "MISSING"; fi
        return 0
    fi
    # A running container is not enough. Both conditions below leave mail
    # completely unusable while `docker ps` shows it up.
    if _stalwart_proxy_banned; then echo "UNHEALTHY"; return 0; fi
    if _stalwart_bootstrap_mode; then echo "UNHEALTHY"; return 0; fi
    echo "HEALTHY"
}

stalwart_repair() {
    # Regenerate the compose file before recreating. Without this, repair
    # rebuilt the container from a stale compose file, so configuration fixes
    # never reached an existing install — the same trap fixed for Nextcloud
    # in v2.4.2.
    _stalwart_write_compose
    local dir="${DOCKER_ROOT}/stalwart"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" up -d --force-recreate

    # Recreating the container clears Stalwart's in-memory ban list, which is
    # the only remedy available until the proxy settings can be persisted.
    if _stalwart_proxy_banned; then
        log_warning "Stalwart had banned a reverse proxy IP — cleared by this restart"
        log_warning "  It will recur until proxyTrustedNetworks / useXForwarded are set"
        log_warning "  in Stalwart's own settings (see CLAUDE.md gotcha #23)"
    fi
    if _stalwart_bootstrap_mode; then
        log_warning "Stalwart is in bootstrap mode — initial setup is not finished"
        log_warning "  Finish it at https://mail.${DOMAIN:-your-domain} before relying on mail"
    fi
}

stalwart_credentials() {
    echo "Stalwart Mail: https://mail.${DOMAIN}"
    echo "  Admin user: admin"
    echo "  Admin pass: ${STALWART_ADMIN_PASS:-see ${DOCKER_ROOT}/stalwart/.admin-password}"
    echo "    (also kept at ${DOCKER_ROOT}/stalwart/.admin-password, mode 600)"
    echo "  After finishing initial setup, set these two in Stalwart's settings"
    echo "  or external mail dies whenever a bot scans the hostname:"
    echo "    Network > Proxy  -> proxyTrustedNetworks = 172.16.0.0/12"
    echo "    HTTP settings    -> useXForwarded = true"
}
