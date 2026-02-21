#!/bin/bash
# lib/directories.sh — CoreX Pro v2
# Phase 4: Directory structure creation on the external SSD.
# Creates dirs for both core and selected services.

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

phase4_directories() {
    log_step "═══ PHASE 4: Directory Structure ═══"

    # Core compose directories (always created)
    mkdir -p "${DOCKER_ROOT}"/{traefik,portainer,adguard,cloudflared}

    # All service compose directories (created for selected services)
    mkdir -p "${DOCKER_ROOT}"/{nextcloud,stalwart,immich,vaultwarden,n8n,ai,monitoring,timemachine,coolify,crowdsec}

    # Core persistent data directories
    mkdir -p "${DATA_ROOT}"/{portainer,adguard-work,adguard-conf}

    # All service data directories
    mkdir -p "${DATA_ROOT}"/{nextcloud-db,nextcloud-html,immich-db,immich-upload,stalwart-data,vaultwarden,n8n,ollama,open-webui,browserless,uptime-kuma,grafana,prometheus,crowdsec-db,crowdsec-config}

    # Backup directory
    mkdir -p "${BACKUP_ROOT}"

    # Time Machine data on shared pool
    mkdir -p "${MOUNT_POOL}/timemachine-data"

    # Fix ownership
    chown -R 1000:1000 "${DOCKER_ROOT}" "${DATA_ROOT}" "${MOUNT_POOL}/timemachine-data"
    chown -R 33:33 "${DATA_ROOT}/nextcloud-html"      # www-data inside Nextcloud container
    chown -R 472:472 "${DATA_ROOT}/grafana"            # grafana user in container
    chown -R 65534:65534 "${DATA_ROOT}/prometheus"     # nobody:nogroup in container

    log_success "Directory structure created on SSD."
}
