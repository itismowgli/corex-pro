#!/bin/bash
# lib/services/crowdsec.sh — CoreX Pro v2
# CrowdSec — Community Intrusion Prevention System
#
# NOTES:
#   - Monitors host logs for attack patterns (brute force, CVEs, bots)
#   - Shares threat intel with global community (you block bad IPs proactively)
#   - Complements Fail2ban (CrowdSec = community intel, Fail2ban = SSH jail)
#   - Collections: linux, traefik, http-cve, sshd, nextcloud, nginx
#   - Firewall bouncer (crowdsec-firewall-bouncer-iptables) runs on HOST and
#     adds iptables DROP rules for flagged IPs. Connects to CrowdSec LAPI
#     on 127.0.0.1:8081 (container port 8080 forwarded to host port 8081
#     to avoid conflict with Traefik API on 127.0.0.1:8080).

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

# ── Private helpers ───────────────────────────────────────────────────────────

# Install and configure the iptables firewall bouncer on the host.
# The bouncer reads decisions from the CrowdSec LAPI and adds DROP rules.
_crowdsec_install_bouncer() {
    log_info "Installing CrowdSec firewall bouncer (iptables)..."

    # Install the package (idempotent)
    if ! command -v crowdsec-firewall-bouncer &>/dev/null; then
        curl -s https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh \
            | bash 2>/dev/null || true
        apt-get install -y crowdsec-firewall-bouncer-iptables 2>/dev/null \
            || log_warning "Could not install crowdsec-firewall-bouncer-iptables — skipping bouncer setup"
    fi

    # Wait up to 30s for CrowdSec LAPI to become available
    local attempts=0
    until docker exec crowdsec cscli version &>/dev/null || [[ $attempts -ge 6 ]]; do
        sleep 5
        (( attempts++ )) || true
    done

    if ! docker exec crowdsec cscli version &>/dev/null; then
        log_warning "CrowdSec LAPI not ready after 30s — bouncer not configured"
        return 1
    fi

    # Generate or regenerate the bouncer API key (--force = safe on re-run)
    local BOUNCER_KEY
    BOUNCER_KEY=$(docker exec crowdsec \
        cscli bouncers add corex-firewall-bouncer --force -o raw 2>/dev/null) || {
        log_warning "Failed to generate bouncer API key"
        return 1
    }

    # Write bouncer config pointing at the LAPI on host-exposed port 8081
    cat > /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml << BEOF
mode: iptables
pid_dir: /var/run/
update_frequency: 10s
log_mode: file
log_dir: /var/log/
log_level: info
api_url: http://127.0.0.1:8081
api_key: ${BOUNCER_KEY}
disable_ipv6: false
deny_action: DROP
deny_log: false
iptables_chains:
  - INPUT
  - FORWARD
  - DOCKER-USER
BEOF

    systemctl enable crowdsec-firewall-bouncer 2>/dev/null || true
    systemctl restart crowdsec-firewall-bouncer 2>/dev/null \
        || log_warning "Bouncer service did not start — check: systemctl status crowdsec-firewall-bouncer"

    log_success "CrowdSec firewall bouncer configured (blocks flagged IPs via iptables)"
}

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
    # Expose LAPI on 127.0.0.1:8081 for the host firewall bouncer.
    # Port 8081 avoids conflict with Traefik API (127.0.0.1:8080).
    ports:
      - "127.0.0.1:8081:8080"
    environment:
      COLLECTIONS: "crowdsecurity/linux crowdsecurity/traefik crowdsecurity/http-cve crowdsecurity/sshd crowdsecurity/nextcloud crowdsecurity/nginx"
      TZ: "${TIMEZONE}"
    volumes:
      - ${DATA_ROOT}/crowdsec-db:/var/lib/crowdsec/data
      - ${DATA_ROOT}/crowdsec-config:/etc/crowdsec
      - /var/log:/var/log:ro
    networks: [proxy-net]
    security_opt: ["no-new-privileges:true"]
    deploy:
      resources:
        limits:
          memory: 256m
          cpus: "0.5"
        reservations:
          memory: 64m
networks:
  proxy-net: { external: true }
DCEOF

    docker compose -f "${dir}/docker-compose.yml" up -d \
        || log_warning "CrowdSec may not have started — check: docker ps"

    # Install host bouncer after container is up
    _crowdsec_install_bouncer || true

    state_service_installed "crowdsec"
    log_success "CrowdSec deployed (community threat intelligence + iptables blocking active)"
}

crowdsec_destroy() {
    # Stop and remove the host bouncer first
    systemctl stop crowdsec-firewall-bouncer 2>/dev/null || true
    systemctl disable crowdsec-firewall-bouncer 2>/dev/null || true
    apt-get remove -y crowdsec-firewall-bouncer-iptables 2>/dev/null || true

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
    # Restart bouncer so it re-reads the (possibly regenerated) config
    systemctl restart crowdsec-firewall-bouncer 2>/dev/null || true
}

crowdsec_credentials() {
    echo "CrowdSec: no web UI"
    echo "  Active decisions:    docker exec crowdsec cscli decisions list"
    echo "  Metrics:             docker exec crowdsec cscli metrics"
    echo "  Bouncer status:      systemctl status crowdsec-firewall-bouncer"
    echo "  iptables DROP rules: iptables -L INPUT | grep -i drop"
}
