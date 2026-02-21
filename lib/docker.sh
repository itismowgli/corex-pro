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

    systemctl enable --now docker
    log_success "Docker running."

    # Create the three isolated Docker networks
    # proxy-net:      All web services + Traefik + Cloudflared
    # monitoring-net: Prometheus + Grafana + exporters
    # ai-net:         Ollama + Open WebUI + Browserless
    docker network create proxy-net     2>/dev/null || true
    docker network create monitoring-net 2>/dev/null || true
    docker network create ai-net        2>/dev/null || true

    log_success "Docker networks ready (proxy-net, monitoring-net, ai-net)"
}
