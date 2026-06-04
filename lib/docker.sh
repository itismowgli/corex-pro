#!/bin/bash
# lib/docker.sh — CoreX Pro v2
# Phase 3: Docker installation and network creation.
# Extracted from install-corex-master.sh Phase 3.

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

phase3_docker() {
    log_step "═══ PHASE 3: Docker Installation ═══"

    if ! command -v docker &>/dev/null; then
        log_info "Installing Docker Engine..."
        curl -fsSL https://get.docker.com | sh || log_error "Docker installation failed."
    else
        log_success "Docker already installed."
    fi

    # ── Docker daemon configuration ───────────────────────────────────────────
    # Apply log rotation and optional SSD data-root before starting daemon.
    local daemon_config='{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }'

    # Move Docker image layers/containers to SSD if opted in during wizard
    if [[ "${DOCKER_ON_SSD:-false}" == "true" ]]; then
        log_info "Configuring Docker data-root on SSD..."
        mkdir -p "/mnt/corex-data/docker-engine"
        daemon_config="${daemon_config},
  \"data-root\": \"/mnt/corex-data/docker-engine\""
    fi

    daemon_config="${daemon_config}
}"

    mkdir -p /etc/docker
    echo "$daemon_config" > /etc/docker/daemon.json
    log_success "Docker daemon: log rotation 10MB×3, json-file driver configured"

    systemctl enable --now docker
    # Reload daemon if config changed while Docker was already running
    systemctl restart docker 2>/dev/null || true
    log_success "Docker running."

    # Create the three isolated Docker networks
    # proxy-net:      All web services + Traefik + Cloudflared
    # monitoring-net: Prometheus + Grafana + exporters
    # ai-net:         Ollama + Open WebUI + Browserless
    docker network create proxy-net      2>/dev/null || true
    docker network create monitoring-net 2>/dev/null || true
    docker network create ai-net         2>/dev/null || true

    log_success "Docker networks ready (proxy-net, monitoring-net, ai-net)"
}
