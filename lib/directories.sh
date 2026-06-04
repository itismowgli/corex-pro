#!/bin/bash
# lib/directories.sh — CoreX Pro v2
# Phase 4: Directory structure creation on the external SSD.
# Creates dirs for both core and selected services.

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

phase4_directories() {
    log_step "═══ PHASE 4: Directory Structure ═══"

    # SELECTED_SERVICES array is set by wizard.sh before this phase runs.
    # Only create directories for selected + always-required services to avoid
    # cluttering the filesystem with dirs for uninstalled services.
    local selected=("${SELECTED_SERVICES[@]:-traefik adguard portainer}")

    _svc_selected() {
        local svc="$1"
        local s
        for s in "${selected[@]}"; do [[ "$s" == "$svc" ]] && return 0; done
        return 1
    }

    # ── Core (always created) ─────────────────────────────────────────────────
    mkdir -p "${DOCKER_ROOT}"/{traefik,portainer,adguard,cloudflared}
    mkdir -p "${DATA_ROOT}"/{portainer,adguard-work,adguard-conf}

    # ── Selected services ─────────────────────────────────────────────────────
    _svc_selected "nextcloud"   && mkdir -p "${DATA_ROOT}"/{nextcloud-db,nextcloud-html} \
        "${DOCKER_ROOT}/nextcloud/hooks/before-starting"
    _svc_selected "immich"      && mkdir -p "${DATA_ROOT}"/{immich-db,immich-upload} \
        "${DOCKER_ROOT}/immich"
    _svc_selected "stalwart"    && mkdir -p "${DATA_ROOT}/stalwart-data" "${DOCKER_ROOT}/stalwart"
    _svc_selected "vaultwarden" && mkdir -p "${DATA_ROOT}/vaultwarden" "${DOCKER_ROOT}/vaultwarden"
    _svc_selected "n8n"         && mkdir -p "${DATA_ROOT}/n8n" "${DOCKER_ROOT}/n8n"
    _svc_selected "ai"          && mkdir -p "${DATA_ROOT}"/{ollama,open-webui,browserless} \
        "${DOCKER_ROOT}/ai"
    _svc_selected "monitoring"  && mkdir -p "${DATA_ROOT}"/{uptime-kuma,grafana,prometheus} \
        "${DOCKER_ROOT}/monitoring"
    _svc_selected "timemachine" && mkdir -p "${MOUNT_POOL}/timemachine-data" "${DOCKER_ROOT}/timemachine"
    _svc_selected "coolify"     && mkdir -p "${DOCKER_ROOT}/coolify"
    _svc_selected "crowdsec"    && mkdir -p "${DATA_ROOT}"/{crowdsec-db,crowdsec-config} \
        "${DOCKER_ROOT}/crowdsec"
    _svc_selected "dashboard"   && mkdir -p "${DOCKER_ROOT}/dashboard"

    # ── Backup directory (always) ─────────────────────────────────────────────
    mkdir -p "${BACKUP_ROOT}"

    # ── Ownership ─────────────────────────────────────────────────────────────
    chown -R 1000:1000 "${DOCKER_ROOT}" "${DATA_ROOT}"
    [[ -d "${MOUNT_POOL}/timemachine-data" ]] && \
        chown -R 1000:1000 "${MOUNT_POOL}/timemachine-data"
    [[ -d "${DATA_ROOT}/nextcloud-html" ]]  && chown -R 33:33 "${DATA_ROOT}/nextcloud-html"
    [[ -d "${DATA_ROOT}/grafana" ]]         && chown -R 472:472 "${DATA_ROOT}/grafana"
    [[ -d "${DATA_ROOT}/prometheus" ]]      && chown -R 65534:65534 "${DATA_ROOT}/prometheus"

    log_success "Directory structure created on SSD (selected services only)."
}
