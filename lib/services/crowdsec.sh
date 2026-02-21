#!/bin/bash
# lib/services/crowdsec.sh — CoreX Pro v2
# CrowdSec — Community Intrusion Prevention System
#
# NOTES:
#   - Monitors host logs for attack patterns (brute force, CVEs, bots)
#   - Shares threat intel with global community (you block bad IPs proactively)
#   - Complements Fail2ban (CrowdSec = community intel, Fail2ban = SSH jail)
#   - Collections: linux, traefik, http-cve, sshd

# ── Metadata ──────────────────────────────────────────────────────────────────
SERVICE_NAME="crowdsec"
SERVICE_LABEL="CrowdSec — Community Intrusion Prevention"
SERVICE_CATEGORY="security"
SERVICE_REQUIRED=false
SERVICE_NEEDS_DOMAIN=false
SERVICE_NEEDS_EMAIL=false
SERVICE_RAM_MB=256
SERVICE_DISK_GB=2
SERVICE_DESCRIPTION="AI-powered intrusion prevention. Learns from the global security community to block attackers before they target you."

# ── Functions ─────────────────────────────────────────────────────────────────

crowdsec_dirs() {
    mkdir -p "${DOCKER_ROOT}/crowdsec"
    mkdir -p "${DATA_ROOT}/crowdsec-db" "${DATA_ROOT}/crowdsec-config"
    chown -R 1000:1000 "${DATA_ROOT}/crowdsec-db" "${DATA_ROOT}/crowdsec-config"
}

crowdsec_firewall() {
    : # CrowdSec reads host logs; no inbound ports needed
}

crowdsec_deploy() {
    crowdsec_dirs
    local dir="${DOCKER_ROOT}/crowdsec"

    cat > "${dir}/docker-compose.yml" << DCEOF
services:
  crowdsec:
    image: crowdsecurity/crowdsec:latest
    container_name: crowdsec
    restart: unless-stopped
    environment:
      COLLECTIONS: "crowdsecurity/linux crowdsecurity/traefik crowdsecurity/http-cve crowdsecurity/sshd"
      TZ: "${TIMEZONE}"
    volumes:
      - ${DATA_ROOT}/crowdsec-db:/var/lib/crowdsec/data
      - ${DATA_ROOT}/crowdsec-config:/etc/crowdsec
      - /var/log:/var/log:ro
    networks: [proxy-net]
    security_opt: ["no-new-privileges:true"]
networks:
  proxy-net: { external: true }
DCEOF

    docker compose -f "${dir}/docker-compose.yml" up -d \
        || log_warning "CrowdSec may not have started — check: docker ps"
    state_service_installed "crowdsec"
    log_success "CrowdSec deployed (community threat intelligence active)"
}

crowdsec_destroy() {
    local dir="${DOCKER_ROOT}/crowdsec"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" down
    state_service_removed "crowdsec"
}

crowdsec_status() {
    if container_running "crowdsec"; then echo "HEALTHY"
    elif container_exists "crowdsec"; then echo "UNHEALTHY"
    else echo "MISSING"; fi
}

crowdsec_repair() {
    local dir="${DOCKER_ROOT}/crowdsec"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" up -d --force-recreate
}

crowdsec_credentials() {
    echo "CrowdSec: no web UI"
    echo "  Check decisions: docker exec crowdsec cscli decisions list"
    echo "  Check metrics:   docker exec crowdsec cscli metrics"
}
