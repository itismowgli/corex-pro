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

stalwart_deploy() {
    stalwart_dirs
    local dir="${DOCKER_ROOT}/stalwart"

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
    networks: [proxy-net]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.mail.rule=Host(\`mail.${DOMAIN}\`)"
      - "traefik.http.routers.mail.entrypoints=websecure"
      - "traefik.http.routers.mail.tls.certresolver=myresolver"
      - "traefik.http.services.mail.loadbalancer.server.port=8080"
networks:
  proxy-net: { external: true }
DCEOF

    docker compose -f "${dir}/docker-compose.yml" up -d \
        || log_warning "Stalwart may not have started — check: docker ps"

    # Stalwart generates its own admin password on first run
    log_info "Waiting for Stalwart to generate admin credentials..."
    local STALWART_ADMIN_PASS=""
    local i
    for i in {1..10}; do
        STALWART_ADMIN_PASS=$(docker logs stalwart 2>&1 | grep -oP "password '\K[^']+")
        if [[ -n "$STALWART_ADMIN_PASS" ]]; then
            break
        fi
        sleep 2
    done

    if [[ -n "$STALWART_ADMIN_PASS" ]]; then
        log_success "Stalwart Mail deployed — admin: 'admin' / '${STALWART_ADMIN_PASS}'"
    else
        log_warning "Stalwart deployed but could not capture admin password."
        log_warning "Run: docker logs stalwart | grep password"
        STALWART_ADMIN_PASS="(check: docker logs stalwart | grep password)"
    fi

    # Export so summary can use it
    export STALWART_ADMIN_PASS

    state_service_installed "stalwart"
    log_success "Stalwart Mail deployed (SMTP:25/587, IMAP:993, mail.${DOMAIN})"
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
    local dir="${DOCKER_ROOT}/stalwart"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" up -d --force-recreate
}

stalwart_credentials() {
    echo "Stalwart Mail: https://mail.${DOMAIN}"
    echo "  Admin user: admin"
    echo "  Admin pass: run 'docker logs stalwart | grep password'"
}
