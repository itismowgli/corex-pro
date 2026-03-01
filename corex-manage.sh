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

# ── lan-setup ─────────────────────────────────────────────────────────────────
# Configures AdGuard DNS wildcard rewrite so LAN clients bypass Cloudflare
# and connect directly to the server for faster file transfers / uploads.

cmd_lan_setup() {
    echo ""
    echo -e "${CYAN}${BOLD}CoreX Pro — LAN Fast-Path Setup${NC}"
    echo "──────────────────────────────────────────────────────"
    echo ""
    echo "  When your devices use AdGuard (on this server) as DNS, all"
    echo "  *.${DOMAIN} lookups resolve to ${SERVER_IP} (your local IP)."
    echo "  File uploads, photo syncs, and vault access all stay on LAN."
    echo ""

    # ── Validate prerequisites ────────────────────────────────────────────────
    if [[ "${DOMAIN:-}" == "" || "${DOMAIN:-}" == "unknown" ]]; then
        log_error "No domain configured. LAN fast-path requires a domain. Check: corex manage status"
    fi

    if ! command -v docker &>/dev/null; then
        log_error "Docker not found. CoreX does not appear to be installed."
    fi

    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^adguard$"; then
        log_warning "AdGuard container is not running."
        echo "  Start it with: sudo bash corex-manage.sh add adguard"
        echo ""
        echo "  Once running, re-run: sudo bash corex-manage.sh lan-setup"
        return 1
    fi

    # ── Determine AdGuard admin port ──────────────────────────────────────────
    local AG_PORT="3000"
    local YAML_FILE="${DATA_ROOT}/adguard-conf/AdGuardHome.yaml"
    if [[ -f "$YAML_FILE" ]]; then
        local PORT_FROM_YAML
        PORT_FROM_YAML=$(grep -A5 "^http:" "$YAML_FILE" \
            | grep "address:" | grep -oP ':\K[0-9]+' | head -1)
        [[ -n "$PORT_FROM_YAML" ]] && AG_PORT="$PORT_FROM_YAML"
    fi

    if [[ "$AG_PORT" == "3000" ]]; then
        log_warning "AdGuard setup wizard has not been completed yet."
        echo "  1. Open http://${SERVER_IP}:3000 and run through the wizard"
        echo "  2. Then re-run: sudo bash corex-manage.sh lan-setup"
        return 1
    fi

    local AG_URL="http://localhost:${AG_PORT}"
    log_info "AdGuard admin URL: ${AG_URL}"

    # ── Check if rewrite already exists ──────────────────────────────────────
    local existing
    existing=$(curl -s "${AG_URL}/control/rewrite/list" 2>/dev/null || true)

    if echo "$existing" | grep -q "\"\\*\\.${DOMAIN}\""; then
        log_success "DNS rewrite *.${DOMAIN} → ${SERVER_IP} already configured."
    else
        log_info "Adding DNS rewrite *.${DOMAIN} → ${SERVER_IP}..."
        local http_code
        # Try without auth first (some setups allow unauthenticated local API calls)
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
            -X POST "${AG_URL}/control/rewrite/add" \
            -H "Content-Type: application/json" \
            -d "{\"domain\": \"*.${DOMAIN}\", \"answer\": \"${SERVER_IP}\"}" \
            2>/dev/null || echo "000")

        if [[ "$http_code" == "200" ]]; then
            log_success "DNS rewrite added."
        elif [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
            echo ""
            log_info "AdGuard requires credentials. Enter your AdGuard admin login:"
            read -r -p "  Username: " AG_USER
            read -r -s -p "  Password: " AG_PASS
            echo ""
            http_code=$(curl -s -o /dev/null -w "%{http_code}" \
                -X POST "${AG_URL}/control/rewrite/add" \
                -H "Content-Type: application/json" \
                -u "${AG_USER}:${AG_PASS}" \
                -d "{\"domain\": \"*.${DOMAIN}\", \"answer\": \"${SERVER_IP}\"}" \
                2>/dev/null || echo "000")
            if [[ "$http_code" == "200" ]]; then
                log_success "DNS rewrite added."
            else
                log_warning "API call failed (HTTP ${http_code}). Add the rewrite manually:"
                echo "  → AdGuard UI → Filters → DNS Rewrites → Add rewrite"
                echo "    Domain: *.${DOMAIN}"
                echo "    Answer: ${SERVER_IP}"
            fi
        else
            log_warning "Could not reach AdGuard API (HTTP ${http_code})."
            echo "  Add the rewrite manually:"
            echo "  → AdGuard UI → Filters → DNS Rewrites → Add rewrite"
            echo "    Domain: *.${DOMAIN}"
            echo "    Answer: ${SERVER_IP}"
        fi
    fi

    # ── Print router/device DNS instructions ──────────────────────────────────
    echo ""
    echo -e "${BOLD}── Router Setup (Recommended — all devices get LAN fast-path) ─────────────${NC}"
    echo ""
    echo "  In your router's DHCP / DNS settings, set:"
    echo -e "    Primary DNS:   ${GREEN}${SERVER_IP}${NC}"
    echo -e "    Secondary DNS: ${YELLOW}1.1.1.1${NC}  ← fallback if server is down"
    echo ""
    echo "  Every device that joins your network will automatically use AdGuard"
    echo "  and resolve *.${DOMAIN} directly to this server over LAN."
    echo ""
    echo -e "${BOLD}── Per-Device DNS (if you cannot change router settings) ──────────────────${NC}"
    echo ""
    echo "  macOS / Linux:"
    echo "    System Settings → Network → DNS → Add ${SERVER_IP}"
    echo ""
    echo "  Windows:"
    echo "    Control Panel → Network → Adapter → IPv4 Properties → DNS: ${SERVER_IP}"
    echo ""
    echo "  iPhone / iPad:"
    echo "    Settings → Wi-Fi → (your network) → Configure DNS → Manual → ${SERVER_IP}"
    echo ""
    echo "  Android:"
    echo "    Settings → Wi-Fi → (your network) → IP Settings → Static → DNS 1: ${SERVER_IP}"
    echo ""
    echo -e "${BOLD}── Verify It's Working ─────────────────────────────────────────────────────${NC}"
    echo ""
    echo "  From a device using AdGuard as DNS, run:"
    echo -e "    ${CYAN}nslookup nextcloud.${DOMAIN}${NC}"
    echo ""
    echo "  Expected result: ${SERVER_IP}  (your local IP, not a Cloudflare IP)"
    echo "  Then uploads to Nextcloud / Immich / Vaultwarden all run at LAN speed."
    echo ""
    log_success "LAN fast-path setup complete."
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
  lan-setup           Configure LAN fast-path for direct local network access

Examples:
  sudo bash corex-manage.sh status
  sudo bash corex-manage.sh add stalwart
  sudo bash corex-manage.sh update --all
  sudo bash corex-manage.sh remove n8n
  sudo bash corex-manage.sh lan-setup

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
        repair)    cmd_repair "$@" ;;
        replace)   cmd_replace "$@" ;;
        doctor)    cmd_doctor ;;
        lan-setup) cmd_lan_setup ;;
        help|--help|-h) cmd_help ;;
        *) echo "Unknown command: ${cmd}"; cmd_help; exit 1 ;;
    esac
}

main "$@"
