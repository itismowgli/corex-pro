#!/bin/bash
################################################################################
# CoreX Pro v2 — Post-Install Service Manager
#
# Usage: sudo bash corex-manage.sh <command> [args]
#
# Commands:
#   status              Show health status of all installed services
#   list                List installed vs available services
#   add <service>       Install a service that was skipped during setup
#   remove <service>    Stop and remove a service (prompts about data)
#   enable <service>    Start a disabled service
#   disable <service>   Stop a service without removing data
#   update <service>    Pull latest image + restart a specific service
#   update --all        Update all installed services
#   replace <old> <new> Remove one service, install another
#
# Requires: /etc/corex/state.json (created by installer)
################################################################################

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load shared libraries
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/state.sh"

# ── v1 → v2 migration ────────────────────────────────────────────────────────
# Called automatically when state.json is missing but CoreX appears to be installed
_migrate_v1_if_needed() {
    [[ -f "$COREX_STATE_FILE" ]] && return 0  # already migrated

    # Check if this looks like a v1 install (Traefik running)
    if ! command -v docker &>/dev/null; then
        return 1
    fi
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^traefik$"; then
        return 1
    fi

    log_step "No state file found — detected v1 install. Migrating to v2..."

    # Attempt to detect domain from existing Traefik config
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

    # Attempt to detect email from credentials file
    local detected_email=""
    if [[ -f "/root/corex-credentials.txt" ]]; then
        detected_email=$(grep -i "email\|let.s encrypt" /root/corex-credentials.txt \
            | grep -oP '[\w.+-]+@[\w.-]+\.[a-z]+' | head -1) || true
    fi

    local detected_ip
    detected_ip=$(hostname -I 2>/dev/null | awk '{print $1}')

    # Initialise state file
    state_init
    state_set "mode"      "with-domain"
    state_set "domain"    "${detected_domain:-unknown}"
    state_set "server_ip" "${detected_ip:-unknown}"
    state_set "email"     "${detected_email:-}"

    # Map running containers → service names
    local running_containers
    running_containers=$(docker ps --format '{{.Names}}' 2>/dev/null)
    declare -A _C2S=(
        [traefik]=traefik        [adguard]=adguard       [portainer]=portainer
        [nextcloud]=nextcloud    [mariadb]=nextcloud      [nextcloud-db]=nextcloud
        [nextcloud-redis]=nextcloud
        [immich-server]=immich   [immich-postgres]=immich [immich-redis]=immich
        [immich-ml]=immich
        [vaultwarden]=vaultwarden
        [n8n]=n8n
        [stalwart]=stalwart
        [timemachine]=timemachine
        [coolify]=coolify
        [crowdsec]=crowdsec
        [cloudflared]=cloudflared
        [ollama]=ai              [open-webui]=ai          [browserless]=ai
        [uptime-kuma]=monitoring [grafana]=monitoring     [prometheus]=monitoring
        [node-exporter]=monitoring [cadvisor]=monitoring
    )
    local container svc seen_svcs=""
    for container in $running_containers; do
        svc="${_C2S[$container]:-}"
        if [[ -n "$svc" ]] && [[ "$seen_svcs" != *"|${svc}|"* ]]; then
            state_service_installed "$svc" 2>/dev/null || true
            seen_svcs="${seen_svcs}|${svc}|"
        fi
    done

    log_success "v1→v2 migration complete."
    if [[ "${detected_domain:-unknown}" == "unknown" ]]; then
        log_warning "Could not auto-detect domain. Edit $COREX_STATE_FILE manually if needed."
    else
        log_info "Detected domain: ${detected_domain}"
    fi
    log_info "State written to: $COREX_STATE_FILE"
    echo ""
    return 0
}

# Load configuration from state.json
_load_config() {
    # Auto-migrate v1 installs before trying to read state
    if [[ ! -f "$COREX_STATE_FILE" ]]; then
        _migrate_v1_if_needed || log_error "CoreX does not appear to be installed. Run: sudo bash corex.sh install"
    fi
    DOMAIN=$(state_get "domain")
    SERVER_IP=$(state_get "server_ip")
    EMAIL=$(state_get "email")
    TIMEZONE=$(state_get "timezone")
    SSH_PORT=$(state_get "ssh_port")
    CLOUDFLARE_TUNNEL_TOKEN=$(state_get "cloudflare_tunnel_token")
    MOUNT_POOL="${MOUNT_POOL:-/mnt/corex-data}"
    DOCKER_ROOT="${DOCKER_ROOT:-${MOUNT_POOL}/docker-configs}"
    DATA_ROOT="${DATA_ROOT:-${MOUNT_POOL}/service-data}"
    BACKUP_ROOT="${BACKUP_ROOT:-${MOUNT_POOL}/backups}"
    CRED_FILE="/root/corex-credentials.txt"
    export DOMAIN SERVER_IP EMAIL TIMEZONE SSH_PORT CLOUDFLARE_TUNNEL_TOKEN
    export MOUNT_POOL DOCKER_ROOT DATA_ROOT BACKUP_ROOT CRED_FILE

    # Load passwords from credential file
    if [[ -f "$CRED_FILE" ]]; then
        MYSQL_ROOT_PASS=$(grep "MySQL Root:" "$CRED_FILE" | awk '{print $3}')
        NEXTCLOUD_DB_PASS=$(grep "Nextcloud DB:" "$CRED_FILE" | awk '{print $3}')
        N8N_ENCRYPTION_KEY=$(grep "n8n Encryption:" "$CRED_FILE" | awk '{print $3}')
        TM_PASSWORD=$(grep "Time Machine:" "$CRED_FILE" | awk '{print $3}')
        VAULTWARDEN_ADMIN_TOKEN=$(grep "Vaultwarden:" "$CRED_FILE" | awk '{print $2}')
        GRAFANA_ADMIN_PASS=$(grep "Grafana Admin:" "$CRED_FILE" | awk '{print $3}')
        RESTIC_PASSWORD=$(grep "Restic Backup:" "$CRED_FILE" | awk '{print $3}')
        IMMICH_DB_PASS=$(grep "Immich DB:" "$CRED_FILE" | awk '{print $3}')
        WEBUI_SECRET_KEY=$(grep "AI WebUI Secret:" "$CRED_FILE" | awk '{print $4}')
        STALWART_ADMIN_PASS=$(grep "Stalwart Admin:" "$CRED_FILE" | awk '{print $4}')
        export MYSQL_ROOT_PASS NEXTCLOUD_DB_PASS N8N_ENCRYPTION_KEY TM_PASSWORD
        export VAULTWARDEN_ADMIN_TOKEN GRAFANA_ADMIN_PASS RESTIC_PASSWORD
        export IMMICH_DB_PASS WEBUI_SECRET_KEY STALWART_ADMIN_PASS
    fi
}

# Source a service module and run a function on it
_run_service_fn() {
    local svc="$1"
    local fn="$2"
    local module="${SCRIPT_DIR}/lib/services/${svc}.sh"

    if [[ ! -f "$module" ]]; then
        log_error "Unknown service: ${svc}. No module found at ${module}"
    fi
    # shellcheck disable=SC1090
    source "$module"

    local func="${svc}_${fn}"
    if declare -f "$func" &>/dev/null; then
        "$func"
    else
        log_warning "Function ${func} not implemented in ${svc}.sh"
    fi
}

# Get all available service names from lib/services/
_all_services() {
    local f svc
    for f in "${SCRIPT_DIR}/lib/services/"*.sh; do
        [[ -f "$f" ]] || continue
        svc=$(bash -c "source '$f' 2>/dev/null; echo \"\${SERVICE_NAME:-}\"")
        [[ -n "$svc" ]] && echo "$svc"
    done
}

# ── status ────────────────────────────────────────────────────────────────────

cmd_status() {
    echo ""
    echo -e "${CYAN}${BOLD}CoreX Pro — Service Health${NC}"
    echo "──────────────────────────────────────────────────────"
    printf "  %-20s %-12s %s\n" "SERVICE" "STATUS" "ACTION"
    echo "  ──────────────────────────────────────────────────"

    local installed
    installed=$(state_list_installed)

    if [[ -z "$installed" ]]; then
        echo "  No services installed."
        return 0
    fi

    local svc status
    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        local module="${SCRIPT_DIR}/lib/services/${svc}.sh"
        if [[ ! -f "$module" ]]; then
            printf "  %-20s %-12s %s\n" "$svc" "NO MODULE" "module missing"
            continue
        fi
        # shellcheck disable=SC1090
        source "$module"
        local status_fn="${svc}_status"
        if declare -f "$status_fn" &>/dev/null; then
            status=$("$status_fn")
        else
            status="UNKNOWN"
        fi

        local color action
        case "$status" in
            HEALTHY)   color="${GREEN}"; action="" ;;
            UNHEALTHY) color="${RED}";   action="→ corex-manage repair ${svc}" ;;
            MISSING)   color="${YELLOW}"; action="→ corex-manage add ${svc}" ;;
            *)         color="${NC}";    action="" ;;
        esac

        printf "  ${color}%-20s %-12s${NC} %s\n" "$svc" "$status" "$action"
    done <<< "$installed"

    echo ""
}

# ── list ──────────────────────────────────────────────────────────────────────

cmd_list() {
    echo ""
    echo -e "${CYAN}${BOLD}CoreX Pro — Available Services${NC}"
    echo "──────────────────────────────────────────────────────"

    local f svc label cat installed_flag
    for f in "${SCRIPT_DIR}/lib/services/"*.sh; do
        [[ -f "$f" ]] || continue
        eval "$(bash -c "source '$f' 2>/dev/null; \
            echo \"svc=\\\"\$SERVICE_NAME\\\"\"; \
            echo \"label=\\\"\$SERVICE_LABEL\\\"\"; \
            echo \"cat=\\\"\$SERVICE_CATEGORY\\\"\"")"

        if state_service_is_installed "$svc"; then
            installed_flag="${GREEN}[installed]${NC}"
        else
            installed_flag="${YELLOW}[available]${NC}"
        fi

        printf "  %-18s %-12s %b  %s\n" "$svc" "$cat" "$installed_flag" "$label"
    done
    echo ""
}

# ── add ───────────────────────────────────────────────────────────────────────

cmd_add() {
    local svc="${1:-}"
    [[ -z "$svc" ]] && { echo "Usage: corex-manage add <service>"; exit 1; }

    if state_service_is_installed "$svc"; then
        log_warning "${svc} is already installed. To reinstall: corex-manage repair ${svc}"
        return 0
    fi

    log_step "Adding service: ${svc}"
    _run_service_fn "$svc" "dirs"
    _run_service_fn "$svc" "firewall"
    _run_service_fn "$svc" "deploy"
    log_success "${svc} added successfully."
}

# ── remove ────────────────────────────────────────────────────────────────────

cmd_remove() {
    local svc="${1:-}"
    [[ -z "$svc" ]] && { echo "Usage: corex-manage remove <service>"; exit 1; }

    if ! state_service_is_installed "$svc"; then
        log_warning "${svc} is not currently installed."
        return 0
    fi

    echo ""
    echo -e "${YELLOW}Remove ${svc}?${NC}"
    echo "This will stop and remove the containers."
    read -r -p "Also DELETE all data for ${svc}? (y/N): " del_data
    read -r -p "Confirm removal of ${svc}? (y/N): " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { echo "Aborted."; return 0; }

    _run_service_fn "$svc" "destroy"

    if [[ "$del_data" == "y" || "$del_data" == "Y" ]]; then
        log_warning "Deleting data directories for ${svc}..."
        rm -rf "${DATA_ROOT:?}/${svc}"* 2>/dev/null || true
        rm -rf "${DOCKER_ROOT:?}/${svc}" 2>/dev/null || true
        log_success "Data deleted."
    fi

    log_success "${svc} removed."
}

# ── enable / disable ──────────────────────────────────────────────────────────

cmd_enable() {
    local svc="${1:-}"
    [[ -z "$svc" ]] && { echo "Usage: corex-manage enable <service>"; exit 1; }
    local dir="${DOCKER_ROOT}/${svc}"
    [[ -f "${dir}/docker-compose.yml" ]] || { log_error "No compose file for ${svc}"; }
    docker compose -f "${dir}/docker-compose.yml" up -d
    state_service_enable "$svc"
    log_success "${svc} started."
}

cmd_disable() {
    local svc="${1:-}"
    [[ -z "$svc" ]] && { echo "Usage: corex-manage disable <service>"; exit 1; }
    local dir="${DOCKER_ROOT}/${svc}"
    [[ -f "${dir}/docker-compose.yml" ]] || { log_error "No compose file for ${svc}"; }
    docker compose -f "${dir}/docker-compose.yml" stop
    state_service_disable "$svc"
    log_success "${svc} stopped (data preserved)."
}

# ── update ────────────────────────────────────────────────────────────────────

cmd_update() {
    local target="${1:---all}"

    if [[ "$target" == "--all" ]]; then
        log_step "Updating all installed services..."
        local svc
        while IFS= read -r svc; do
            [[ -z "$svc" ]] && continue
            _update_single "$svc"
        done < <(state_list_installed)
    else
        _update_single "$target"
    fi
}

_update_single() {
    local svc="$1"
    local dir="${DOCKER_ROOT}/${svc}"
    if [[ ! -f "${dir}/docker-compose.yml" ]]; then
        log_warning "No compose file for ${svc} — skipping"
        return 0
    fi
    log_info "Updating ${svc}..."
    docker compose -f "${dir}/docker-compose.yml" pull
    docker compose -f "${dir}/docker-compose.yml" up -d
    log_success "${svc} updated."
}

# ── repair (doctor) ───────────────────────────────────────────────────────────

cmd_repair() {
    local svc="${1:-}"
    if [[ -z "$svc" ]]; then
        # Repair all unhealthy installed services
        local repaired=0
        local sv
        while IFS= read -r sv; do
            [[ -z "$sv" ]] && continue
            local module="${SCRIPT_DIR}/lib/services/${sv}.sh"
            [[ -f "$module" ]] || continue
            # shellcheck disable=SC1090
            source "$module"
            local status_fn="${sv}_status"
            declare -f "$status_fn" &>/dev/null || continue
            local status
            status=$("$status_fn")
            if [[ "$status" != "HEALTHY" ]]; then
                log_step "Repairing ${sv} (status: ${status})..."
                _run_service_fn "$sv" "repair"
                ((repaired++))
            fi
        done < <(state_list_installed)
        [[ $repaired -eq 0 ]] && log_success "All services are healthy." \
            || log_success "Repaired ${repaired} service(s)."
    else
        log_step "Repairing ${svc}..."
        _run_service_fn "$svc" "repair"
        log_success "${svc} repaired."
    fi
}

# ── replace ───────────────────────────────────────────────────────────────────

cmd_replace() {
    local old_svc="${1:-}" new_svc="${2:-}"
    [[ -z "$old_svc" || -z "$new_svc" ]] && {
        echo "Usage: corex-manage replace <old-service> <new-service>"
        exit 1
    }
    log_step "Replacing ${old_svc} with ${new_svc}..."
    cmd_remove "$old_svc"
    cmd_add "$new_svc"
}

# ── doctor (health check all) ─────────────────────────────────────────────────

cmd_doctor() {
    cmd_status
    echo -e "${CYAN}Running auto-repair on unhealthy services...${NC}"
    cmd_repair
}

# ── help ──────────────────────────────────────────────────────────────────────

cmd_help() {
    cat << HELPEOF

${BOLD}CoreX Pro v2 — Service Manager${NC}

Usage: sudo bash corex-manage.sh <command> [args]

Commands:
  status              Show health of all installed services
  list                List all available and installed services
  add <service>       Install a service that was skipped during setup
  remove <service>    Stop and remove a service (prompts about data)
  enable <service>    Start a stopped service
  disable <service>   Stop a service (data preserved)
  update <service>    Pull latest image + restart
  update --all        Update all installed services
  repair [service]    Force-recreate unhealthy service(s) (no data loss)
  replace <old> <new> Remove one service, install another
  doctor              Full health check + auto-repair

Examples:
  sudo bash corex-manage.sh status
  sudo bash corex-manage.sh add stalwart
  sudo bash corex-manage.sh update --all
  sudo bash corex-manage.sh remove n8n

HELPEOF
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    check_root
    _load_config

    local cmd="${1:-help}"
    shift || true

    case "$cmd" in
        status)   cmd_status ;;
        list)     cmd_list ;;
        add)      cmd_add "$@" ;;
        remove)   cmd_remove "$@" ;;
        enable)   cmd_enable "$@" ;;
        disable)  cmd_disable "$@" ;;
        update)   cmd_update "$@" ;;
        repair)   cmd_repair "$@" ;;
        replace)  cmd_replace "$@" ;;
        doctor)   cmd_doctor ;;
        help|--help|-h) cmd_help ;;
        *) echo "Unknown command: ${cmd}"; cmd_help; exit 1 ;;
    esac
}

main "$@"
