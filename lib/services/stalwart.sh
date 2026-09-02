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

stalwart_status() {
    if container_running "stalwart"; then echo "HEALTHY"
    elif container_exists "stalwart"; then echo "UNHEALTHY"
    else echo "MISSING"; fi
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
}

stalwart_credentials() {
    echo "Stalwart Mail: https://mail.${DOMAIN}"
    echo "  Admin user: admin"
    echo "  Admin user: admin"
    echo "  Admin pass: ${STALWART_ADMIN_PASS:-see ${DOCKER_ROOT}/stalwart/.admin-password}"
    echo "    (also kept at ${DOCKER_ROOT}/stalwart/.admin-password, mode 600)"
}
