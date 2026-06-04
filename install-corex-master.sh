#!/bin/bash
################################################################################
#
#   ██████╗ ██████╗ ██████╗ ███████╗██╗  ██╗    ██████╗ ██████╗  ██████╗
#  ██╔════╝██╔═══██╗██╔══██╗██╔════╝╚██╗██╔╝    ██╔══██╗██╔══██╗██╔═══██╗
#  ██║     ██║   ██║██████╔╝█████╗   ╚███╔╝     ██████╔╝██████╔╝██║   ██║
#  ██║     ██║   ██║██╔══██╗██╔══╝   ██╔██╗     ██╔═══╝ ██╔══██╗██║   ██║
#  ╚██████╗╚██████╔╝██║  ██║███████╗██╔╝ ██╗    ██║     ██║  ██║╚██████╔╝
#   ╚═════╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝    ╚═╝     ╚═╝  ╚═╝ ╚═════╝
#
#  CoreX Pro v2 — Sovereign Hybrid Homelab
#  "Brains on System. Muscle on SSD."
#
#  Thin orchestrator — all logic lives in lib/ modules.
#  Service modules in lib/services/ are auto-discovered.
#
#  USAGE:
#    sudo bash install-corex-master.sh
#    (or invoked via: sudo bash corex.sh install)
#
################################################################################

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Load shared libraries ─────────────────────────────────────────────────────
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/state.sh"
source "${SCRIPT_DIR}/lib/wizard.sh"
source "${SCRIPT_DIR}/lib/preflight.sh"
source "${SCRIPT_DIR}/lib/drive.sh"
source "${SCRIPT_DIR}/lib/security.sh"
source "${SCRIPT_DIR}/lib/docker.sh"
source "${SCRIPT_DIR}/lib/directories.sh"
source "${SCRIPT_DIR}/lib/backup.sh"
source "${SCRIPT_DIR}/lib/summary.sh"

# ── Root check ────────────────────────────────────────────────────────────────
check_root

# ── Detect repair/upgrade path ────────────────────────────────────────────────
# If state.json exists, corex is already installed → run doctor instead
_detect_existing_install() {
    if [[ -f "$COREX_STATE_FILE" ]]; then
        log_warning "CoreX Pro is already installed."
        echo ""
        echo "  To health-check and repair: sudo bash corex.sh doctor"
        echo "  To manage services:         sudo bash corex.sh manage status"
        echo "  To add a service:           sudo bash corex.sh manage add <service>"
        echo "  To update all services:     sudo bash corex.sh manage update --all"
        echo ""
        local confirm
        read -r -p "Re-run full installer anyway? This may overwrite configs (y/N): " confirm
        [[ "$confirm" == "y" || "$confirm" == "Y" ]] || exit 0
    fi
}

# ── Deploy a single service ───────────────────────────────────────────────────
_deploy_service() {
    local svc="$1"
    local module="${SCRIPT_DIR}/lib/services/${svc}.sh"

    if [[ ! -f "$module" ]]; then
        log_warning "No module found for '${svc}' — skipping"
        return 0
    fi

    # shellcheck disable=SC1090
    source "$module"

    log_step "Deploying: ${svc}"

    local dirs_fn="${svc}_dirs"
    local fw_fn="${svc}_firewall"
    local deploy_fn="${svc}_deploy"

    declare -f "$dirs_fn"   &>/dev/null && "$dirs_fn"
    declare -f "$fw_fn"     &>/dev/null && "$fw_fn"
    declare -f "$deploy_fn" &>/dev/null && "$deploy_fn" \
        || log_warning "${svc}_deploy not implemented — skipping"
}

# ── v1 → v2 migration ────────────────────────────────────────────────────────
# If Traefik is running but no state.json: reconstruct state from docker ps
_migrate_v1_to_v2() {
    if command -v docker &>/dev/null && docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^traefik$"; then
        if [[ ! -f "$COREX_STATE_FILE" ]]; then
            log_step "Detected v1 install — migrating to v2 state tracking"

            # Discover domain from existing traefik config
            local detected_domain=""
            local traefik_yml
            for traefik_yml in /mnt/corex-data/docker-configs/traefik/traefik.yml \
                               /opt/corex-pro/docker-configs/traefik/traefik.yml; do
                if [[ -f "$traefik_yml" ]]; then
                    detected_domain=$(grep -oP 'email:\s*\K\S+' "$traefik_yml" 2>/dev/null \
                        | sed 's/admin@//' | head -1) || true
                    break
                fi
            done

            local detected_ip
            detected_ip=$(hostname -I 2>/dev/null | awk '{print $1}')

            state_init
            state_set "mode" "with-domain"
            state_set "domain" "${detected_domain:-unknown}"
            state_set "server_ip" "${detected_ip:-unknown}"

            # Map running containers to service names
            local running_containers
            running_containers=$(docker ps --format '{{.Names}}' 2>/dev/null)
            local container svc
            declare -A CONTAINER_TO_SERVICE=(
                [traefik]=traefik [adguard]=adguard [portainer]=portainer
                [nextcloud]=nextcloud [mariadb]=nextcloud
                [immich-server]=immich [immich-postgres]=immich
                [vaultwarden]=vaultwarden [n8n]=n8n [stalwart]=stalwart
                [timemachine]=timemachine [coolify]=coolify
                [crowdsec]=crowdsec [cloudflared]=cloudflared
                [ollama]=ai [open-webui]=ai [uptime-kuma]=monitoring
                [grafana]=monitoring [prometheus]=monitoring
            )
            for container in $running_containers; do
                svc="${CONTAINER_TO_SERVICE[$container]:-}"
                [[ -n "$svc" ]] && state_service_installed "$svc" 2>/dev/null || true
            done

            log_success "v1→v2 state migration complete. Run: sudo bash corex.sh manage status"
            exit 0
        fi
    fi
}

################################################################################
# MAIN INSTALL FLOW
################################################################################

main() {
    # Check for v1 migration scenario
    _migrate_v1_to_v2

    # Check for existing v2 install
    _detect_existing_install

    # ── Phase 0: Wizard + Pre-flight ─────────────────────────────────────────
    log_step "═══ PHASE 0: Configuration Wizard ═══"
    declare -a SELECTED_SERVICES=()
    run_wizard   # Sets: DOMAIN, SERVER_IP, EMAIL, TIMEZONE, SSH_PORT, MODE, SELECTED_SERVICES

    # ── Export core env vars for all modules ──────────────────────────────────
    export DOMAIN SERVER_IP EMAIL TIMEZONE SSH_PORT MODE
    export MOUNT_POOL="${MOUNT_POOL:-/mnt/corex-data}"
    export DOCKER_ROOT="${DOCKER_ROOT:-${MOUNT_POOL}/docker-configs}"
    export DATA_ROOT="${DATA_ROOT:-${MOUNT_POOL}/service-data}"
    export BACKUP_ROOT="${BACKUP_ROOT:-${MOUNT_POOL}/backups}"
    export CRED_FILE="/root/corex-credentials.txt"
    export DOCS_FILE="/root/CoreX_Dashboard_Credentials.md"

    # ── Phase 0b: Pre-flight checks + password generation ────────────────────
    log_step "═══ PHASE 0b: Pre-flight Checks ═══"
    phase0_precheck

    # ── Phase 1: Drive setup ──────────────────────────────────────────────────
    log_step "═══ PHASE 1: Drive & Storage Setup ═══"
    phase1_drive

    # ── Phase 2: Security hardening ───────────────────────────────────────────
    log_step "═══ PHASE 2: Security Hardening ═══"
    phase2_security

    # ── Phase 3: Docker install + networks ───────────────────────────────────
    log_step "═══ PHASE 3: Docker & Networks ═══"
    phase3_docker

    # ── Phase 4: Directory structure ─────────────────────────────────────────
    log_step "═══ PHASE 4: Directory Structure ═══"
    phase4_directories

    # ── Phase 5: Deploy selected services ────────────────────────────────────
    log_step "═══ PHASE 5: Service Deployment ═══"
    echo ""
    echo -e "  Services to install: ${BOLD}${SELECTED_SERVICES[*]}${NC}"
    echo ""

    # Initialise state file
    state_init
    state_set "mode"      "$MODE"
    state_set "domain"    "${DOMAIN:-}"
    state_set "server_ip" "$SERVER_IP"
    state_set "email"     "${EMAIL:-}"
    state_set "ssh_port"  "$SSH_PORT"
    state_set "timezone"  "$TIMEZONE"
    if [[ "${CLOUDFLARE_TUNNEL_TOKEN:-}" != "PASTE_YOUR_TUNNEL_TOKEN_HERE" && -n "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]]; then
        state_set "cloudflare_tunnel_configured" "true"
        state_set "cloudflare_tunnel_token" "$CLOUDFLARE_TUNNEL_TOKEN"
    fi

    local svc
    for svc in "${SELECTED_SERVICES[@]}"; do
        _deploy_service "$svc"
    done

    # ── Phase 6: Backup ───────────────────────────────────────────────────────
    log_step "═══ PHASE 6: Backup Configuration ═══"
    phase6_backup

    # ── Phase 7: Summary & Credentials ───────────────────────────────────────
    phase7_summary
}

main "$@"
