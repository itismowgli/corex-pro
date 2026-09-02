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
                | tr -d '"'"'" | sed 's/admin@//' | head -1) || true
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
    # tr -d '"' strips stray quotes that v1-migration may have embedded
    # (traefik.yml stores email: "admin@domain" — grep captures the quotes)
    DOMAIN=$(state_get "domain" | tr -d '"')
    SERVER_IP=$(state_get "server_ip" | tr -d '"')
    EMAIL=$(state_get "email")
    TIMEZONE=$(state_get "timezone")
    SSH_PORT=$(state_get "ssh_port")
    CLOUDFLARE_TUNNEL_TOKEN=$(state_get "cloudflare_tunnel_token")

    # Resolve SSH_PORT: state.json may be missing it on v1 migrated installs.
    # Fall back to the actual running sshd configuration so repair operations
    # (Fail2ban, UFW) never write "null" as the port value.
    if [[ "$SSH_PORT" == "null" || -z "$SSH_PORT" ]]; then
        SSH_PORT=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')
        SSH_PORT="${SSH_PORT:-22}"
        # Persist the detected value so future calls don't need detection
        state_set "ssh_port" "$SSH_PORT" 2>/dev/null || true
    fi

    # Similarly default TIMEZONE when missing from older state files
    if [[ "$TIMEZONE" == "null" || -z "$TIMEZONE" ]]; then
        TIMEZONE=$(cat /etc/timezone 2>/dev/null || timedatectl show -p Timezone --value 2>/dev/null || echo "UTC")
        state_set "timezone" "$TIMEZONE" 2>/dev/null || true
    fi
    MOUNT_POOL="${MOUNT_POOL:-/mnt/corex-data}"
    DOCKER_ROOT="${DOCKER_ROOT:-${MOUNT_POOL}/docker-configs}"
    DATA_ROOT="${DATA_ROOT:-${MOUNT_POOL}/service-data}"
    BACKUP_ROOT="${BACKUP_ROOT:-${MOUNT_POOL}/backups}"
    CRED_FILE="/root/corex-credentials.txt"
    export DOMAIN SERVER_IP EMAIL TIMEZONE SSH_PORT CLOUDFLARE_TUNNEL_TOKEN
    export MOUNT_POOL DOCKER_ROOT DATA_ROOT BACKUP_ROOT CRED_FILE

    # Load passwords from credential file.
    # Uses sed 's/^[^:]*: //' to capture everything after the first ': ',
    # which handles passwords that contain spaces (awk would truncate them).
    if [[ -f "$CRED_FILE" ]]; then
        MYSQL_ROOT_PASS=$(grep "MySQL Root:" "$CRED_FILE" | sed 's/^[^:]*: //')
        NEXTCLOUD_DB_PASS=$(grep "Nextcloud DB:" "$CRED_FILE" | sed 's/^[^:]*: //')
        N8N_ENCRYPTION_KEY=$(grep "n8n Encryption:" "$CRED_FILE" | sed 's/^[^:]*: //')
        TM_PASSWORD=$(grep "Time Machine:" "$CRED_FILE" | sed 's/^[^:]*: //')
        VAULTWARDEN_ADMIN_TOKEN=$(grep "Vaultwarden:" "$CRED_FILE" | sed 's/^[^:]*: //')
        GRAFANA_ADMIN_PASS=$(grep "Grafana Admin:" "$CRED_FILE" | sed 's/^[^:]*: //')
        RESTIC_PASSWORD=$(grep "Restic Backup:" "$CRED_FILE" | sed 's/^[^:]*: //')
        IMMICH_DB_PASS=$(grep "Immich DB:" "$CRED_FILE" | sed 's/^[^:]*: //')
        WEBUI_SECRET_KEY=$(grep "AI WebUI Secret:" "$CRED_FILE" | sed 's/^[^:]*: //')
        STALWART_ADMIN_PASS=$(grep "Stalwart Admin:" "$CRED_FILE" | sed 's/^[^:]*: //')
        BROWSERLESS_TOKEN=$(grep "Browserless Token:" "$CRED_FILE" | sed 's/^[^:]*: //')
        export MYSQL_ROOT_PASS NEXTCLOUD_DB_PASS N8N_ENCRYPTION_KEY TM_PASSWORD
        export VAULTWARDEN_ADMIN_TOKEN GRAFANA_ADMIN_PASS RESTIC_PASSWORD
        export IMMICH_DB_PASS WEBUI_SECRET_KEY STALWART_ADMIN_PASS BROWSERLESS_TOKEN
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
        # Exact path only — no glob to prevent accidental deletion of related services
        # (e.g. removing 'nextcloud' must NOT delete 'nextcloud-db' or 'nextcloud-redis')
        rm -rf "${DATA_ROOT:?}/${svc}" 2>/dev/null || true
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
    # Digest check: skip pull+restart if image is already at latest
    local image
    image=$(docker compose -f "${dir}/docker-compose.yml" config --images 2>/dev/null | head -1)
    if [[ -n "$image" ]]; then
        local local_digest remote_digest
        local_digest=$(docker inspect --format '{{index .RepoDigests 0}}' "$image" 2>/dev/null || true)
        remote_digest=$(docker manifest inspect "$image" 2>/dev/null | \
            grep -oP '"digest":\s*"\K[^"]+' | head -1 || true)
        if [[ -n "$local_digest" && -n "$remote_digest" && \
              "$local_digest" == *"$remote_digest"* ]]; then
            log_info "${svc}: already at latest — skipping pull"
            return 0
        fi
    fi
    log_info "Updating ${svc}..."
    docker compose -f "${dir}/docker-compose.yml" pull
    docker compose -f "${dir}/docker-compose.yml" up -d
    log_success "${svc} updated."
}

# ── storage ───────────────────────────────────────────────────────────────────

cmd_storage() {
    echo ""
    echo -e "${CYAN}${BOLD}CoreX Storage Report${NC}"
    echo "─────────────────────────────────────────────────────────"
    echo ""

    # OS disk
    local os_total os_used os_pct
    os_total=$(df -BG / | awk 'NR==2{print $2}')
    os_used=$(df -BG / | awk 'NR==2{print $3}')
    os_pct=$(df / | awk 'NR==2{print $5}')
    echo -e "  ${BOLD}OS Disk (/):${NC} ${os_used} used / ${os_total} (${os_pct})"

    if [[ -d /var/lib/docker ]]; then
        local docker_size
        docker_size=$(du -sh /var/lib/docker 2>/dev/null | awk '{print $1}')
        echo "    /var/lib/docker: ${docker_size} (images + build cache + logs)"
    fi
    echo ""

    # External SSD
    if [[ -d "${MOUNT_POOL}" ]]; then
        local ssd_total ssd_used ssd_pct
        ssd_total=$(df -BG "${MOUNT_POOL}" | awk 'NR==2{print $2}')
        ssd_used=$(df -BG "${MOUNT_POOL}" | awk 'NR==2{print $3}')
        ssd_pct=$(df "${MOUNT_POOL}" | awk 'NR==2{print $5}')
        echo -e "  ${BOLD}External SSD (${MOUNT_POOL}):${NC} ${ssd_used} used / ${ssd_total} (${ssd_pct})"
        echo ""
        echo -e "  ${BOLD}Service Data:${NC}"
        if [[ -d "${DATA_ROOT}" ]]; then
            local dir name size
            while IFS= read -r dir; do
                name=$(basename "$dir")
                size=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
                printf "    %-30s %s\n" "$name" "$size"
            done < <(find "${DATA_ROOT}" -mindepth 1 -maxdepth 1 -type d | sort)
        fi
        echo ""
    fi

    # Docker system usage
    echo -e "  ${BOLD}Docker Usage:${NC}"
    docker system df 2>/dev/null || echo "  (docker not available)"
    echo ""
    echo -e "  Run ${CYAN}corex manage cleanup --dry-run${NC} to preview freeable space."
}

# ── cleanup ───────────────────────────────────────────────────────────────────

cmd_cleanup() {
    local dry_run=false
    [[ "${1:-}" == "--dry-run" ]] && dry_run=true

    echo ""
    if [[ "$dry_run" == "true" ]]; then
        echo -e "${CYAN}${BOLD}CoreX Cleanup — DRY RUN (no changes)${NC}"
    else
        echo -e "${CYAN}${BOLD}CoreX Cleanup${NC}"
    fi
    echo "─────────────────────────────────────────────────────────"
    echo ""

    # Stale images unused 7+ days
    local stale_images
    stale_images=$(docker image ls --filter "dangling=false" \
        --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | wc -l)
    echo -e "  ${BOLD}Stale Docker images (unused 7+ days):${NC}"
    docker image ls --filter "until=168h" --format "  {{.Repository}}:{{.Tag}} ({{.Size}})" \
        2>/dev/null || true
    echo ""

    echo -e "  ${BOLD}Build cache (3+ days old):${NC}"
    docker builder prune --filter "until=72h" --keep-storage 0 \
        $([ "$dry_run" == "true" ] && echo "--dry-run" || echo "--force") 2>/dev/null \
        | grep -v "^$" | sed 's/^/  /' || true
    echo ""

    # Journal usage (was never reported or reclaimed)
    echo -e "  ${BOLD}systemd journal:${NC} $(journalctl --disk-usage 2>/dev/null \
        | grep -oE '[0-9.]+[GMK]' | head -1 || echo 'n/a')"
    echo -e "  ${BOLD}apt cache:${NC} $(du -sh /var/cache/apt/archives 2>/dev/null \
        | cut -f1 || echo 'n/a')"
    echo ""

    if [[ "$dry_run" == "false" ]]; then
        local before_root before_data
        before_root=$(df --output=avail / 2>/dev/null | tail -1)
        before_data=$(df --output=avail /mnt/corex-data 2>/dev/null | tail -1)

        echo -e "  ${BOLD}Removing stale images...${NC}"
        docker image prune --filter "until=168h" --force 2>/dev/null || true
        docker image prune --force 2>/dev/null || true

        # Unused networks accumulate as services are added/removed. Volumes are
        # deliberately NOT pruned — that would destroy live service data.
        echo -e "  ${BOLD}Removing unused Docker networks...${NC}"
        docker network prune --force 2>/dev/null || true

        echo -e "  ${BOLD}Vacuuming systemd journal (keep 30d, cap 500M)...${NC}"
        journalctl --vacuum-time=30d &>/dev/null || true
        journalctl --vacuum-size=500M &>/dev/null || true

        echo -e "  ${BOLD}Clearing apt cache...${NC}"
        apt-get clean 2>/dev/null || true

        echo -e "  ${BOLD}Removing rotated logs older than 30 days...${NC}"
        find /var/log -type f -name '*.gz' -mtime +30 -delete 2>/dev/null || true
        find /var/log -type f -regex '.*\.[0-9]+$' -mtime +30 -delete 2>/dev/null || true

        echo -e "  ${BOLD}Cleaning old CoreX temp files...${NC}"
        find /tmp -name "corex-*" -mtime +1 -delete 2>/dev/null || true

        local after_root after_data
        after_root=$(df --output=avail / 2>/dev/null | tail -1)
        after_data=$(df --output=avail /mnt/corex-data 2>/dev/null | tail -1)
        echo ""
        echo -e "  ${BOLD}Reclaimed:${NC}"
        printf '    /              %s MB\n' "$(( ( ${after_root:-0} - ${before_root:-0} ) / 1024 ))"
        printf '    /mnt/corex-data %s MB\n' "$(( ( ${after_data:-0} - ${before_data:-0} ) / 1024 ))"
        echo ""
        log_warning "Old kernels/orphans not removed (dpkg transaction)."
        echo "    Run manually when the system is stable: apt-get autoremove --purge"
        log_success "Cleanup complete."
    else
        echo "  [DRY RUN] Run without --dry-run to apply cleanup."
    fi
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
    cmd_health
    echo -e "${CYAN}Running auto-repair on unhealthy services...${NC}"
    cmd_repair
}

# ── health (hardware) ─────────────────────────────────────────────────────────
# Service health was already covered; this covers the HOST. A mini server dies
# of physical causes — heat, a failing SSD, an unclean shutdown that broke dpkg
# — and none of those show up in "is the container running?".

_health_read_temp() {
    local t=""
    if command -v sensors &>/dev/null; then
        t=$(sensors -u 2>/dev/null \
            | awk '/^(Tctl|Tdie|Package id 0):/{getline; print $2; exit}')
    fi
    if [[ -z "$t" ]]; then
        local best=0 v
        for z in /sys/class/thermal/thermal_zone*/temp; do
            [[ -r "$z" ]] || continue
            v=$(( $(cat "$z" 2>/dev/null || echo 0) / 1000 ))
            (( v > best )) && best=$v
        done
        (( best > 0 )) && t=$best
    fi
    [[ -z "$t" ]] && { echo ""; return 1; }
    printf '%.0f' "$t" 2>/dev/null || echo ""
}

cmd_health() {
    echo ""
    echo -e "${CYAN}${BOLD}Host Hardware Health${NC}"
    echo "─────────────────────────────────────────────────────────"
    echo ""

    # ── CPU temperature ──────────────────────────────────────────────────────
    local temp
    temp=$(_health_read_temp)
    if [[ -z "$temp" ]]; then
        log_warning "No temperature sensor readable — install lm-sensors and run sensors-detect"
    else
        local verdict="${GREEN}OK${NC}"
        if   (( temp >= 95 )); then verdict="${RED}CRITICAL — thermal trip imminent${NC}"
        elif (( temp >= 90 )); then verdict="${RED}TOO HOT — clean the heatsink${NC}"
        elif (( temp >= 80 )); then verdict="${YELLOW}HOT${NC}"
        fi
        echo -e "  ${BOLD}CPU temperature:${NC} ${temp}°C — ${verdict}"
        if (( temp >= 90 )); then
            echo "    A sustained 90°C+ means cooling cannot keep up. The CPU will"
            echo "    eventually THERMTRIP: an instant power cut with no warning,"
            echo "    which risks database and dpkg corruption."
        fi
    fi

    # ── Thermal guardian ─────────────────────────────────────────────────────
    if systemctl is-active --quiet corex-thermal.timer 2>/dev/null; then
        local shed_n=0
        [[ -r /var/lib/corex/thermal-shed.list ]] && \
            shed_n=$(grep -c . /var/lib/corex/thermal-shed.list 2>/dev/null || echo 0)
        if (( shed_n > 0 )); then
            log_warning "Thermal guardian has shed ${shed_n} container(s) to stay cool"
            sed 's/^/      /' /var/lib/corex/thermal-shed.list 2>/dev/null | head -8
            echo "      They restart automatically once temperature drops."
        else
            echo -e "  ${BOLD}Thermal guardian:${NC} active, nothing shed"
        fi
    else
        log_warning "Thermal guardian NOT running — no protection against overheating"
    fi

    # ── Previous shutdown ────────────────────────────────────────────────────
    echo -en "  ${BOLD}Last shutdown:${NC} "
    local markers
    markers=$(journalctl -b -1 --no-pager 2>/dev/null \
        | grep -cE "systemd-shutdown|Reached target Shutdown|Powering off" || echo 0)
    if [[ "$markers" == "0" ]]; then
        echo -e "${RED}UNCLEAN${NC} (power loss, thermal trip, or hang)"
        echo "      Last health sample before it died:"
        grep -E 'temp=' /mnt/corex-data/blackbox.log 2>/dev/null | tail -1 | sed 's/^/        /'
    else
        echo -e "${GREEN}clean${NC}"
    fi

    # ── dpkg integrity ───────────────────────────────────────────────────────
    local unconf
    unconf=$(awk '/^Status: install ok unpacked/{c++} END{print c+0}' \
        /var/lib/dpkg/status 2>/dev/null)
    if (( unconf > 0 )); then
        log_warning "dpkg: ${unconf} package(s) unpacked but NOT configured"
        echo "      An apt run was interrupted. Repair with: dpkg --configure -a"
    else
        echo -e "  ${BOLD}dpkg integrity:${NC} ${GREEN}clean${NC}"
    fi

    # ── Disk health ──────────────────────────────────────────────────────────
    if command -v smartctl &>/dev/null; then
        local d h
        while read -r d; do
            [[ -b "/dev/$d" ]] || continue
            h=$(smartctl -H "/dev/$d" 2>/dev/null \
                | grep -iE "overall-health|SMART Health Status" | awk -F: '{print $2}' | xargs)
            [[ -z "$h" ]] && h=$(smartctl -H -d sat "/dev/$d" 2>/dev/null \
                | grep -iE "overall-health" | awk -F: '{print $2}' | xargs)
            [[ -z "$h" ]] && h="not reported (USB bridge may not pass SMART through)"
            echo -e "  ${BOLD}/dev/${d}:${NC} ${h}"
        done < <(lsblk -dno NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}')
    else
        log_warning "smartmontools not installed — no disk health visibility"
    fi

    # ── Memory pressure ──────────────────────────────────────────────────────
    local swap_used
    swap_used=$(free -m | awk '/^Swap:/{print $3}')
    if [[ -n "$swap_used" ]] && (( swap_used > 512 )); then
        log_warning "Swap in use: ${swap_used}MB — memory pressure may be throttling I/O"
    fi
    echo ""
}

# ── os-upgrade ────────────────────────────────────────────────────────────────
# A supervised OS package upgrade that REFUSES to start when conditions make an
# interrupted dpkg transaction likely. Kernel/libc/systemd are excluded from
# unattended runs (see lib/security.sh), so this is where they get applied —
# deliberately, with the preconditions actually checked.

cmd_os_upgrade() {
    local force=false
    [[ "${1:-}" == "--force" ]] && force=true

    echo ""
    echo -e "${CYAN}${BOLD}CoreX Supervised OS Upgrade${NC}"
    echo "─────────────────────────────────────────────────────────"
    echo ""

    local blocked=false

    # ── Gate 1: thermal headroom ─────────────────────────────────────────────
    local temp
    temp=$(_health_read_temp)
    if [[ -n "$temp" ]]; then
        echo -e "  CPU temperature: ${temp}°C"
        if (( temp >= 85 )); then
            log_warning "BLOCKED: ${temp}°C is too hot to start a dpkg transaction."
            echo "    An upgrade raises CPU load further. If the box thermal-trips"
            echo "    mid-transaction you can be left with an unbootable system."
            echo "    Cool it first (clean the heatsink, or reduce container load)."
            blocked=true
        fi
    else
        log_warning "No temperature sensor — cannot verify thermal headroom"
    fi

    # ── Gate 2: dpkg must be clean before adding more work ───────────────────
    local unconf
    unconf=$(awk '/^Status: install ok unpacked/{c++} END{print c+0}' \
        /var/lib/dpkg/status 2>/dev/null)
    if (( unconf > 0 )); then
        log_warning "dpkg has ${unconf} unconfigured package(s) — repairing first"
        dpkg --configure -a || log_warning "Repair incomplete"
        unconf=$(awk '/^Status: install ok unpacked/{c++} END{print c+0}' \
            /var/lib/dpkg/status 2>/dev/null)
        (( unconf > 0 )) && { log_warning "BLOCKED: dpkg still broken"; blocked=true; }
    fi

    # ── Gate 3: enough uptime to trust the box ───────────────────────────────
    local up_s
    up_s=$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0)
    if (( up_s < 900 )); then
        log_warning "Uptime is only $(( up_s / 60 ))m. On a box with a history of"
        echo "    crashing, 15+ minutes of stability is a reasonable bar before"
        echo "    starting a kernel or libc upgrade."
        blocked=true
    fi

    if [[ "$blocked" == "true" && "$force" != "true" ]]; then
        echo ""
        log_warning "Upgrade NOT started. Fix the above, or re-run with --force"
        echo "    if you have console access and accept the risk."
        return 1
    fi
    [[ "$blocked" == "true" ]] && log_warning "Proceeding anyway (--force given)"

    echo ""
    log_step "Updating package lists..."
    apt-get update -qq || log_warning "apt-get update reported problems"

    echo "  Pending: $(apt list --upgradable 2>/dev/null | grep -c upgradable) package(s)"
    echo ""
    log_step "Upgrading (MinimalSteps so an interruption leaves less broken)..."
    DEBIAN_FRONTEND=noninteractive apt-get -y \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold \
        upgrade || log_warning "Upgrade reported problems — checking dpkg state"

    # Always reconcile afterwards, whether or not the upgrade claimed success.
    dpkg --configure -a 2>/dev/null || true

    echo ""
    if [[ -f /var/run/reboot-required ]]; then
        log_warning "Reboot required to activate the new kernel."
        echo "    Reboot deliberately, when you can watch it come back up."
    else
        log_success "Upgrade complete, no reboot required."
    fi
}

# ── lan-setup ─────────────────────────────────────────────────────────────────
# Configures AdGuard DNS wildcard rewrite + SVCB/HTTPS record blocking so LAN
# clients bypass Cloudflare and connect directly to the server for faster file
# transfers / uploads.
#
# The full LAN fast-path requires solving 5 layers of browser bypass:
#   1. A-record rewrite (AdGuard wildcard DNS rewrite)
#   2. SVCB/HTTPS DNS records (contain embedded Cloudflare IPs — browsers
#      query these and connect directly, ignoring A-record rewrites)
#   3. HTTP/3 QUIC Alt-Svc caching (browsers cache QUIC connections to CF)
#   4. Browser built-in DNS clients (bypass system DNS resolver)
#   5. IPv6 bypass (browsers connect via IPv6 to Cloudflare, ignoring IPv4 rewrite)
#
# Also prints a /etc/hosts fallback block for users whose VPN apps (Tailscale,
# ClearVPN, etc.) intercept DNS at the kernel level and bypass AdGuard.

cmd_lan_setup() {
    echo ""
    echo -e "${CYAN}${BOLD}CoreX Pro — LAN Fast-Path Setup${NC}"
    echo "──────────────────────────────────────────────────────"
    echo ""
    echo "  Goal: *.${DOMAIN} resolves to ${SERVER_IP} (your server's LAN IP)"
    echo "  so uploads, photo syncs, and vault access stay on your local network"
    echo "  instead of travelling through Cloudflare at internet speeds."
    echo ""

    # ── Validate prerequisites ────────────────────────────────────────────────
    if [[ "${DOMAIN:-}" == "" || "${DOMAIN:-}" == "unknown" ]]; then
        log_error "No domain configured. Check: corex manage status"
    fi

    if ! command -v docker &>/dev/null; then
        log_error "Docker not found. CoreX does not appear to be installed."
    fi

    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^adguard$"; then
        log_warning "AdGuard container is not running."
        echo "  Start it with: sudo bash corex-manage.sh add adguard"
        echo "  Then re-run:   sudo bash corex-manage.sh lan-setup"
        return 1
    fi

    # ── Detect AdGuard wizard state ───────────────────────────────────────────
    # Internal port switches from 3000 → 80 after the setup wizard completes.
    # HOST-side port is always 3000. We read the YAML only to detect wizard state.
    local AG_INTERNAL_PORT="3000"
    local YAML_FILE="${DATA_ROOT}/adguard-conf/AdGuardHome.yaml"
    if [[ -f "$YAML_FILE" ]]; then
        local PORT_FROM_YAML
        PORT_FROM_YAML=$(grep "address:" "$YAML_FILE" \
            | grep -oP ':\K[0-9]+' | tail -1)
        [[ -n "$PORT_FROM_YAML" ]] && AG_INTERNAL_PORT="$PORT_FROM_YAML"
    fi

    if [[ "$AG_INTERNAL_PORT" == "3000" ]]; then
        log_warning "AdGuard setup wizard has not been completed yet."
        echo "  1. Open http://${SERVER_IP}:3000 in your browser"
        echo "  2. Complete the wizard (set admin password, keep defaults otherwise)"
        echo "  3. Then re-run: sudo bash corex-manage.sh lan-setup"
        return 1
    fi

    # API is always reachable via the Docker host-mapped port 3000
    local AG_URL="http://localhost:3000"
    local AG_USER="" AG_PASS=""

    # ── Authenticate once — reuse credentials for list check AND add ──────────
    # Probe the list endpoint first. If AdGuard needs auth, prompt once and
    # reuse the credentials for every subsequent API call. This prevents the
    # old behaviour of blindly attempting to add a rewrite that already exists
    # (which created duplicate entries in AdGuard).
    local probe_code
    probe_code=$(curl -s -o /dev/null -w "%{http_code}" \
        "${AG_URL}/control/rewrite/list" 2>/dev/null || echo "000")

    if [[ "$probe_code" == "401" || "$probe_code" == "403" ]]; then
        echo ""
        log_info "AdGuard requires credentials (set during the wizard)."
        read -r -p "  Username: " AG_USER
        read -r -s -p "  Password: " AG_PASS
        echo ""
    fi

    # Wrapper so every API call gets the same auth header when needed
    _ag_curl() {
        if [[ -n "$AG_USER" ]]; then
            curl -s -u "${AG_USER}:${AG_PASS}" "$@"
        else
            curl -s "$@"
        fi
    }

    # ── Check / add DNS rewrite ───────────────────────────────────────────────
    local rewrite_list
    rewrite_list=$(_ag_curl "${AG_URL}/control/rewrite/list" 2>/dev/null || echo "[]")

    if echo "$rewrite_list" | grep -q "\"\\*\\.${DOMAIN}\""; then
        log_success "DNS rewrite *.${DOMAIN} → ${SERVER_IP} already configured."
    else
        log_info "Adding DNS rewrite *.${DOMAIN} → ${SERVER_IP}..."
        local add_code
        add_code=$(_ag_curl -o /dev/null -w "%{http_code}" \
            -X POST "${AG_URL}/control/rewrite/add" \
            -H "Content-Type: application/json" \
            -d "{\"domain\": \"*.${DOMAIN}\", \"answer\": \"${SERVER_IP}\"}" \
            2>/dev/null || echo "000")

        if [[ "$add_code" == "200" ]]; then
            log_success "DNS rewrite added."
        else
            log_warning "API call failed (HTTP ${add_code}). Add the rewrite manually:"
            echo "    AdGuard UI → Filters → DNS Rewrites → Add rewrite"
            echo "    Domain: *.${DOMAIN}"
            echo "    Answer: ${SERVER_IP}"
        fi
    fi

    # ── Block SVCB/HTTPS DNS records ──────────────────────────────────────────
    # Cloudflare publishes SVCB/HTTPS (Type 65) DNS records that contain embedded
    # IPv4/IPv6 address hints pointing to Cloudflare edge servers, plus ECH
    # (Encrypted Client Hello) configuration. Modern browsers (Chrome, Edge, Firefox)
    # query these records and connect DIRECTLY to the embedded Cloudflare IPs,
    # completely bypassing the A-record DNS rewrite above.
    #
    # The fix: block SVCB/HTTPS records for the domain via AdGuard user filtering
    # rules. This forces browsers to fall back to standard A-record resolution,
    # which hits the wildcard rewrite and returns the server's LAN IP.
    log_info "Checking SVCB/HTTPS DNS record blocking..."

    # Extract the base domain (strip any subdomain — rules apply to all of *.domain)
    local BASE_DOMAIN="${DOMAIN}"

    local current_rules
    current_rules=$(_ag_curl "${AG_URL}/control/filtering/status" 2>/dev/null || echo "{}")

    local svcb_rule="||${BASE_DOMAIN}^\$dnstype=SVCB"
    local https_rule="||${BASE_DOMAIN}^\$dnstype=HTTPS"

    if echo "$current_rules" | grep -q "dnstype=HTTPS" && \
       echo "$current_rules" | grep -q "dnstype=SVCB"; then
        log_success "SVCB/HTTPS DNS records already blocked for ${BASE_DOMAIN}."
    else
        log_info "Blocking SVCB/HTTPS DNS records for ${BASE_DOMAIN}..."

        # Get existing user rules, append our new rules
        local existing_rules
        existing_rules=$(echo "$current_rules" | \
            python3 -c "import sys,json; d=json.load(sys.stdin); print('\n'.join(d.get('user_rules',[])))" \
            2>/dev/null || echo "")

        # Build the new rules list (preserve existing + add ours if not already present)
        local new_rules="${existing_rules}"
        if ! echo "$existing_rules" | grep -qF "$svcb_rule"; then
            new_rules="${new_rules}"$'\n'"${svcb_rule}"
        fi
        if ! echo "$existing_rules" | grep -qF "$https_rule"; then
            new_rules="${new_rules}"$'\n'"${https_rule}"
        fi

        # Set rules via API (replaces all user rules)
        local rules_json
        rules_json=$(echo "$new_rules" | python3 -c "
import sys, json
lines = [l for l in sys.stdin.read().strip().split('\n') if l.strip()]
print(json.dumps({'rules': lines}))" 2>/dev/null)

        if [[ -n "$rules_json" ]]; then
            local set_code
            set_code=$(_ag_curl -o /dev/null -w "%{http_code}" \
                -X POST "${AG_URL}/control/filtering/set_rules" \
                -H "Content-Type: application/json" \
                -d "$rules_json" \
                2>/dev/null || echo "000")

            if [[ "$set_code" == "200" ]]; then
                log_success "SVCB/HTTPS DNS records blocked."
            else
                log_warning "Could not set filtering rules (HTTP ${set_code}). Add manually:"
                echo "    AdGuard UI → Filters → Custom filtering rules → Add:"
                echo "    ${svcb_rule}"
                echo "    ${https_rule}"
            fi
        else
            log_warning "python3 not available — add SVCB/HTTPS blocking manually:"
            echo "    AdGuard UI → Filters → Custom filtering rules → Add:"
            echo "    ${svcb_rule}"
            echo "    ${https_rule}"
        fi
    fi

    # ── Build /etc/hosts entries from installed services ──────────────────────
    # Maps service module names → subdomains (matches actual Traefik router rules)
    _lan_subdomains() {
        case "$1" in
            nextcloud)   echo "nextcloud" ;;
            immich)      echo "photos" ;;
            portainer)   echo "portainer" ;;
            vaultwarden) echo "vault" ;;
            n8n)         echo "n8n" ;;
            stalwart)    echo "mail" ;;
            coolify)     echo "coolify" ;;
            monitoring)  echo "status grafana" ;;
            ai)          echo "ai ollama" ;;
            adguard)     echo "adguard" ;;
            traefik)     echo "traefik" ;;
            *)           echo "" ;;  # timemachine, crowdsec, cloudflared — no web subdomain
        esac
    }

    local HOSTS_LINES=""
    local svc
    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        local subs
        subs=$(_lan_subdomains "$svc")
        for sub in $subs; do
            HOSTS_LINES+="${SERVER_IP} ${sub}.${DOMAIN}"$'\n'
        done
    done < <(state_list_installed)

    # ── Step 1: Router DNS ────────────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}── Step 1: Router DNS (easiest — covers all devices automatically) ─────────${NC}"
    echo ""
    echo "  In your router's DHCP / DNS settings, set:"
    echo -e "    Primary DNS:   ${GREEN}${SERVER_IP}${NC}"
    echo ""
    echo -e "  ${YELLOW}WARNING:${NC} Do NOT set a secondary/fallback DNS (like 1.1.1.1 or 8.8.8.8)."
    echo "  If you do, some devices will race both DNS servers and may get"
    echo "  Cloudflare's IP from the fallback instead of your LAN IP."
    echo "  If AdGuard goes down, you can temporarily set 1.1.1.1 as DNS."
    echo ""
    echo "  Every device that joins your network will resolve"
    echo "  *.${DOMAIN} directly to this server without any extra steps."
    echo ""

    # ── Step 2: Per-device DNS ────────────────────────────────────────────────
    echo -e "${BOLD}── Step 2: Per-Device DNS (if you cannot change router settings) ───────────${NC}"
    echo ""
    echo -e "  Set ${GREEN}${SERVER_IP}${NC} as the ONLY DNS server (no secondary):"
    echo ""
    echo "  macOS:   System Settings → Network → Wi-Fi → Details → DNS → ${SERVER_IP}"
    echo "  Windows: Control Panel → Network → Adapter → IPv4 → DNS: ${SERVER_IP}"
    echo "  iPhone:  Settings → Wi-Fi → (network) → Configure DNS → Manual → ${SERVER_IP}"
    echo "  Android: Settings → Wi-Fi → (network) → IP Settings → Static → DNS: ${SERVER_IP}"
    echo ""
    echo -e "  ${YELLOW}Important:${NC} Remove any secondary DNS server. A fallback DNS like"
    echo "  1.1.1.1 will return Cloudflare IPs and defeat the LAN fast-path."
    echo ""

    # ── Step 3: Hosts file fallback ───────────────────────────────────────────
    # Required when VPN apps (Tailscale, ClearVPN, etc.) install a kernel-level
    # Network Extension that intercepts DNS before AdGuard or /etc/resolver/ rules
    # can act on it. The /etc/hosts file is checked BEFORE any DNS query is made,
    # so it cannot be intercepted by VPN software. Safe to add, easy to remove.
    if [[ -n "$HOSTS_LINES" ]]; then
        echo -e "${BOLD}── Step 3: Hosts File (required if you use Tailscale or a VPN app) ────────${NC}"
        echo ""
        echo "  VPN apps like Tailscale and ClearVPN install a kernel-level Network"
        echo "  Extension that intercepts DNS before it reaches AdGuard — even after"
        echo "  following Steps 1 and 2. The hosts file bypasses this completely."
        echo ""
        echo "  It is safe to add: it only affects the listed hostnames, changes"
        echo "  nothing else on your system, and can be removed at any time."
        echo ""
        echo -e "  ${BOLD}macOS / Linux${NC} — paste in Terminal:"
        echo ""
        echo -e "${CYAN}sudo tee -a /etc/hosts << 'HOSTSEOF'"
        echo "# CoreX Pro LAN fast-path — ${DOMAIN} (added by lan-setup)"
        printf '%s' "$HOSTS_LINES"
        echo "# End CoreX Pro LAN fast-path"
        echo -e "HOSTSEOF${NC}"
        echo ""
        echo -e "  ${BOLD}Windows${NC} — paste in PowerShell (Run as Administrator):"
        echo ""
        echo -e "${CYAN}  Add-Content \$env:SystemRoot\\System32\\drivers\\etc\\hosts @'"
        echo "# CoreX Pro LAN fast-path — ${DOMAIN}"
        printf '%s' "$HOSTS_LINES"
        echo "  # End CoreX Pro LAN fast-path"
        echo -e "  '@${NC}"
        echo ""
        echo "  To remove later: open /etc/hosts and delete the lines between"
        echo "  '# CoreX Pro LAN fast-path' and '# End CoreX Pro LAN fast-path'."
        echo ""
    fi

    # ── Step 4: Browser Configuration ─────────────────────────────────────────
    # Chrome and Chromium-based browsers have two features that bypass the DNS
    # rewrite and route traffic through Cloudflare anyway:
    #
    # 1. HTTP/3 QUIC Alt-Svc caching: Chrome caches QUIC connections to
    #    Cloudflare via the Alt-Svc HTTP header. Even after DNS changes,
    #    Chrome reuses the cached connection for up to 30 days.
    #
    # 2. Built-in DNS client: Chrome can bypass the system DNS resolver
    #    entirely, querying upstream DNS directly (often Cloudflare or Google).
    echo -e "${BOLD}── Step 4: Browser Configuration (Chrome/Edge — critical for full speed) ──${NC}"
    echo ""
    echo "  Chrome and Chromium-based browsers (Edge, Brave, Arc) cache QUIC"
    echo "  connections to Cloudflare and may bypass your system DNS entirely."
    echo "  These two settings force the browser to use the LAN path:"
    echo ""
    echo -e "  ${BOLD}macOS${NC} — paste in Terminal (then restart browser):"
    echo ""
    echo -e "  ${CYAN}# Disable QUIC/HTTP3 (prevents cached Cloudflare connections)"
    echo "  defaults write com.google.Chrome QuicAllowed -bool false"
    echo ""
    echo "  # Disable Chrome built-in DNS client (use system DNS instead)"
    echo -e "  defaults write com.google.Chrome BuiltInDnsClientEnabled -bool false${NC}"
    echo ""
    echo -e "  ${BOLD}Windows${NC} — paste in PowerShell (then restart browser):"
    echo ""
    echo -e "  ${CYAN}# Chrome policy registry keys"
    echo '  New-Item -Path "HKLM:\SOFTWARE\Policies\Google\Chrome" -Force | Out-Null'
    echo '  Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Google\Chrome" -Name "QuicAllowed" -Value 0 -Type DWord'
    echo -e '  Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Google\Chrome" -Name "BuiltInDnsClientEnabled" -Value 0 -Type DWord'"${NC}"
    echo ""
    echo -e "  ${BOLD}Linux${NC} — create policy file (then restart browser):"
    echo ""
    echo -e "  ${CYAN}sudo mkdir -p /etc/opt/chrome/policies/managed"
    echo "  echo '{\"QuicAllowed\": false, \"BuiltInDnsClientEnabled\": false}' \\"
    echo -e "    | sudo tee /etc/opt/chrome/policies/managed/corex-lan.json${NC}"
    echo ""
    echo -e "  ${BOLD}Edge${NC} — replace 'Google/Chrome' with 'Microsoft/Edge' in the paths above."
    echo -e "  ${BOLD}Firefox${NC} — not affected (does not use QUIC Alt-Svc caching by default)."
    echo ""
    echo "  To undo later: delete the policy keys/files and restart the browser."
    echo ""

    # ── Step 5: Disable IPv6 on LAN Devices ───────────────────────────────────
    # If the domain uses Cloudflare, AAAA records point to Cloudflare IPv6
    # addresses. Browsers prefer IPv6 over IPv4 when available, so even with
    # a perfect A-record rewrite, the browser connects via IPv6 to Cloudflare
    # instead of the LAN server. Disabling IPv6 on the LAN interface forces
    # all connections to use IPv4, which hits the DNS rewrite.
    echo -e "${BOLD}── Step 5: Disable IPv6 on LAN Devices (prevents Cloudflare IPv6 bypass) ──${NC}"
    echo ""
    echo "  If your domain uses Cloudflare, browsers may connect via IPv6 to"
    echo "  Cloudflare edge servers — completely bypassing the IPv4 DNS rewrite."
    echo "  This is the most common reason the fast-path doesn't work after"
    echo "  completing Steps 1-4."
    echo ""
    echo -e "  ${BOLD}macOS${NC} — paste in Terminal:"
    echo ""
    echo -e "  ${CYAN}# List network services to find your active interface"
    echo "  networksetup -listallhardwareports"
    echo ""
    echo "  # Disable IPv6 on your active interface (replace name as needed)"
    echo "  sudo networksetup -setv6off Wi-Fi"
    echo -e "  sudo networksetup -setv6off \"USB 10/100/1000 LAN\"  # if using USB Ethernet${NC}"
    echo ""
    echo -e "  ${BOLD}Windows${NC} — paste in PowerShell (as Administrator):"
    echo ""
    echo -e "  ${CYAN}# Disable IPv6 on all adapters"
    echo -e "  Get-NetAdapterBinding -ComponentId ms_tcpip6 | Disable-NetAdapterBinding -ComponentId ms_tcpip6${NC}"
    echo ""
    echo -e "  ${BOLD}Linux${NC} — add to /etc/sysctl.conf:"
    echo ""
    echo -e "  ${CYAN}net.ipv6.conf.all.disable_ipv6 = 1"
    echo -e "  net.ipv6.conf.default.disable_ipv6 = 1${NC}"
    echo ""
    echo "  To undo: macOS: networksetup -setv6automatic Wi-Fi"
    echo "           Windows: Enable-NetAdapterBinding -ComponentId ms_tcpip6"
    echo "           Linux: remove the sysctl lines and run: sysctl --system"
    echo ""

    # ── Step 6: Trust the LAN CA Certificate ──────────────────────────────────
    # Traefik generates a self-signed CA and wildcard cert for *.DOMAIN.
    # LAN clients need to trust this CA to avoid browser HTTPS warnings.
    local CA_CERT="${DOCKER_ROOT}/traefik/certs/ca.crt"
    if [[ -f "$CA_CERT" ]]; then
        echo -e "${BOLD}── Step 6: Trust the LAN CA Certificate (removes HTTPS warnings) ─────────${NC}"
        echo ""
        echo "  Traefik uses a self-signed wildcard certificate for LAN HTTPS."
        echo "  To avoid browser warnings, trust the CoreX Pro CA on your devices."
        echo ""
        echo "  The CA certificate is at:"
        echo -e "    ${CYAN}${CA_CERT}${NC}"
        echo ""
        echo -e "  ${BOLD}macOS${NC}:"
        echo "    1. Copy ca.crt to your Mac (scp, Nextcloud, USB, etc.)"
        echo "    2. Double-click to open in Keychain Access"
        echo "    3. Find 'CoreX Pro CA' in the login keychain"
        echo "    4. Double-click → Trust → 'Always Trust'"
        echo ""
        echo -e "  ${BOLD}Windows${NC}:"
        echo "    1. Copy ca.crt to your PC"
        echo "    2. Double-click → Install Certificate → Local Machine"
        echo "    3. Place in: Trusted Root Certification Authorities"
        echo ""
        echo -e "  ${BOLD}iPhone/iPad${NC}:"
        echo "    1. Email or AirDrop ca.crt to the device"
        echo "    2. Settings → General → VPN & Device Mgmt → Install profile"
        echo "    3. Settings → General → About → Certificate Trust Settings → Enable"
        echo ""
        echo -e "  ${BOLD}Android${NC}:"
        echo "    1. Copy ca.crt to the device"
        echo "    2. Settings → Security → Install from storage → CA Certificate"
        echo ""
    fi

    # ── Verify ────────────────────────────────────────────────────────────────
    echo -e "${BOLD}── Verify It's Working ─────────────────────────────────────────────────────${NC}"
    echo ""
    echo "  After completing all steps above, flush your DNS cache:"
    echo ""
    echo "  macOS:   sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder"
    echo "  Linux:   sudo systemd-resolve --flush-caches"
    echo "  Windows: ipconfig /flushdns"
    echo ""
    echo "  Restart your browser completely (quit + reopen, not just new tab)."
    echo ""
    echo "  Then verify the IP is local (not a Cloudflare IP):"
    echo -e "    ${CYAN}nslookup nextcloud.${DOMAIN}${NC}"
    echo ""
    echo -e "  Expected: ${GREEN}${SERVER_IP}${NC}   ← your server's LAN IP"
    echo "  If you see 172.67.x.x or 104.21.x.x → check Steps 4 and 5."
    echo ""
    echo "  To confirm the browser is using the LAN path, open DevTools (F12):"
    echo "    Network tab → reload page → click the main request"
    echo "    Look at Response Headers — there should be NO 'cf-ray' header."
    echo "    If you see 'cf-ray', the browser is still going through Cloudflare."
    echo ""
    log_success "LAN fast-path setup complete."
}

# ── network-tune ─────────────────────────────────────────────────────────────
# Diagnoses current network performance settings and applies high-performance
# kernel parameters. Shows before/after comparison. Safe to re-run.

cmd_network_tune() {
    echo ""
    echo -e "${CYAN}${BOLD}CoreX Pro — Network Performance Tuner${NC}"
    echo "──────────────────────────────────────────────────────"
    echo ""

    # ── Detect interfaces ────────────────────────────────────────────────────
    log_info "Detecting network interfaces..."
    local iface ifname link_speed operstate iface_mtu
    for iface in /sys/class/net/e*; do
        [[ -d "$iface" ]] || continue
        ifname=$(basename "$iface")
        link_speed=$(cat "${iface}/speed" 2>/dev/null || echo "unknown")
        operstate=$(cat "${iface}/operstate" 2>/dev/null || echo "unknown")
        iface_mtu=$(cat "${iface}/mtu" 2>/dev/null || echo "unknown")
        printf "  %-12s speed: %-8s  state: %-6s  MTU: %s\n" \
            "$ifname" "${link_speed}Mbps" "$operstate" "$iface_mtu"
    done
    for iface in /sys/class/net/w*; do
        [[ -d "$iface" ]] || continue
        ifname=$(basename "$iface")
        operstate=$(cat "${iface}/operstate" 2>/dev/null || echo "unknown")
        iface_mtu=$(cat "${iface}/mtu" 2>/dev/null || echo "unknown")
        printf "  %-12s speed: %-8s  state: %-6s  MTU: %s\n" \
            "$ifname" "wireless" "$operstate" "$iface_mtu"
    done
    echo ""

    # ── Current kernel network settings ──────────────────────────────────────
    log_info "Current kernel network parameters:"
    echo ""
    printf "  %-42s %s\n" "PARAMETER" "VALUE"
    echo "  ──────────────────────────────────────────────────"

    local params=(
        "net.ipv4.tcp_congestion_control"
        "net.core.default_qdisc"
        "net.core.rmem_max"
        "net.core.wmem_max"
        "net.core.rmem_default"
        "net.core.wmem_default"
        "net.ipv4.tcp_window_scaling"
        "net.ipv4.tcp_fastopen"
        "net.ipv4.tcp_mtu_probing"
        "net.ipv4.tcp_slow_start_after_idle"
        "net.core.somaxconn"
        "net.core.netdev_max_backlog"
        "vm.swappiness"
        "vm.dirty_ratio"
    )

    local param val
    for param in "${params[@]}"; do
        val=$(sysctl -n "$param" 2>/dev/null || echo "n/a")
        printf "  %-42s %s\n" "$param" "$val"
    done
    echo ""

    # ── Check if tuning is already applied ───────────────────────────────────
    local current_cc current_rmem
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    current_rmem=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "0")

    if [[ "$current_cc" == "bbr" && "$current_rmem" -ge 67108864 ]]; then
        log_success "Network is already tuned for high performance."
        echo ""
        _network_speed_tips
        return 0
    fi

    # ── Apply tuning ─────────────────────────────────────────────────────────
    log_info "Applying high-performance network parameters..."

    # Check if BBR module is available
    if ! modprobe tcp_bbr 2>/dev/null; then
        log_warning "BBR kernel module not available. Using current congestion control."
    fi

    # Apply from corex sysctl config if it exists
    if [[ -f /etc/sysctl.d/99-corex.conf ]]; then
        sysctl --system > /dev/null 2>&1
        log_success "Applied parameters from /etc/sysctl.d/99-corex.conf"
    else
        # Apply key parameters directly (for pre-v2.2 installs)
        sysctl -w net.core.rmem_max=67108864 > /dev/null 2>&1
        sysctl -w net.core.wmem_max=67108864 > /dev/null 2>&1
        sysctl -w net.core.rmem_default=262144 > /dev/null 2>&1
        sysctl -w net.core.wmem_default=262144 > /dev/null 2>&1
        sysctl -w "net.ipv4.tcp_rmem=4096 262144 67108864" > /dev/null 2>&1
        sysctl -w "net.ipv4.tcp_wmem=4096 262144 67108864" > /dev/null 2>&1
        sysctl -w net.ipv4.tcp_window_scaling=1 > /dev/null 2>&1
        sysctl -w net.ipv4.tcp_mtu_probing=1 > /dev/null 2>&1
        sysctl -w net.ipv4.tcp_slow_start_after_idle=0 > /dev/null 2>&1
        sysctl -w net.ipv4.tcp_fastopen=3 > /dev/null 2>&1
        sysctl -w net.core.somaxconn=4096 > /dev/null 2>&1
        sysctl -w net.core.netdev_max_backlog=16384 > /dev/null 2>&1

        if modprobe tcp_bbr 2>/dev/null; then
            sysctl -w net.core.default_qdisc=fq > /dev/null 2>&1
            sysctl -w net.ipv4.tcp_congestion_control=bbr > /dev/null 2>&1
        fi

        log_success "Applied runtime network tuning."
        log_warning "To persist across reboots, re-run the CoreX installer (sudo bash corex.sh install)"
    fi

    echo ""
    _network_speed_tips
}

_network_speed_tips() {
    echo -e "${BOLD}── Speed Tips ─────────────────────────────────────────────────────────────${NC}"
    echo ""
    echo "  1. Use ETHERNET instead of Wi-Fi for maximum speed"
    echo "     Wi-Fi theoretical max: ~100-300 MB/s (Wi-Fi 6)"
    echo "     Ethernet 1Gbps:        ~110 MB/s"
    echo "     Ethernet 2.5Gbps:      ~280 MB/s"
    echo ""
    echo "  2. Check your cable — use Cat 5e or better for gigabit"
    echo "     Cat 5 caps at 100Mbps. Cat 5e/6/6a supports 1-10 Gbps."
    echo ""
    echo "  3. Bypass your ISP router if it has a 100Mbps switch"
    echo "     Many ISP routers have 10/100 ports, not gigabit."
    echo "     Connect through a gigabit switch instead."
    echo ""
    echo "  4. Test raw network speed between two machines:"
    echo -e "     Server: ${CYAN}iperf3 -s${NC}"
    echo -e "     Client: ${CYAN}iperf3 -c ${SERVER_IP}${NC}"
    echo ""
    echo "  5. Install iperf3 if missing:"
    echo -e "     ${CYAN}sudo apt install -y iperf3${NC}"
    echo ""
    echo "  6. Verify SMB3 multichannel is active (from macOS):"
    echo -e "     ${CYAN}smbutil multichannel -a${NC}"
    echo ""
    echo "  7. LAN fast-path must be configured for full-speed service access:"
    echo -e "     ${CYAN}sudo bash corex-manage.sh lan-setup${NC}"
    echo ""
}

# ── network-check ─────────────────────────────────────────────────────────────
# Tests HTTPS reachability, SSL cert validity, and DNS resolution for every
# installed service. Read-only diagnostic — safe to run at any time.

cmd_network_check() {
    local domain server_ip
    domain=$(state_get "domain" 2>/dev/null || echo "")
    server_ip=$(state_get "server_ip" 2>/dev/null || echo "")

    echo ""
    echo -e "${CYAN}${BOLD}CoreX Pro — Network Check${NC}"
    echo "──────────────────────────────────────────────────────"

    if [[ -z "$domain" || "$domain" == "null" ]]; then
        log_warning "No domain configured (local-only mode). Skipping URL checks."
        echo ""
        _check_docker_networks
        return 0
    fi

    echo -e "  Domain:    ${BOLD}${domain}${NC}"
    echo -e "  Server IP: ${BOLD}${server_ip:-unknown}${NC}"
    echo ""

    # Subdomain map matching lib/services/*.sh Traefik labels
    declare -A SUBDOMAINS=(
        ["traefik"]="traefik"
        ["adguard"]="adguard"
        ["portainer"]="portainer"
        ["nextcloud"]="nextcloud"
        ["immich"]="photos"
        ["vaultwarden"]="vault"
        ["n8n"]="n8n"
        ["stalwart"]="mail"
        ["ai"]="ai"
        ["uptime-kuma"]="status"
        ["monitoring"]="grafana"
        ["dashboard"]="dashboard"
        ["coolify"]="coolify"
    )

    # ── Service URL checks ─────────────────────────────────────────────────────
    log_step "Checking service endpoints..."
    echo ""
    printf "  %-20s %-38s %-8s %-8s %s\n" "SERVICE" "URL" "HTTP" "CERT" "DNS"
    echo "  ──────────────────────────────────────────────────────────────────────────────────"

    local ok_count=0 warn_count=0 err_count=0

    for svc_file in "${SCRIPT_DIR}/lib/services/"*.sh; do
        [[ -f "$svc_file" ]] || continue
        local svc_name
        svc_name=$(bash -c "source '${svc_file}' 2>/dev/null; echo \"\${SERVICE_NAME:-}\"" 2>/dev/null)
        [[ -z "$svc_name" ]] && continue
        state_service_is_installed "$svc_name" 2>/dev/null || continue
        [[ -z "${SUBDOMAINS[$svc_name]:-}" ]] && continue

        local sub="${SUBDOMAINS[$svc_name]}"
        local url="https://${sub}.${domain}"

        # HTTP status code
        local http_code
        http_code=$(curl -sk --connect-timeout 5 --max-time 10 \
            -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "ERR")

        local http_label http_color
        case "$http_code" in
            2*|3*) http_label="$http_code"; http_color="$GREEN" ;;
            000|ERR) http_label="DOWN"; http_color="$RED"; (( err_count++ )) ;;
            *) http_label="$http_code"; http_color="$YELLOW"; (( warn_count++ )) ;;
        esac
        [[ "$http_code" =~ ^[23] ]] && (( ok_count++ )) || true

        # SSL certificate expiry
        local cert_label cert_color
        local expiry_str
        expiry_str=$(echo | openssl s_client -connect "${sub}.${domain}:443" \
            -servername "${sub}.${domain}" 2>/dev/null \
            | openssl x509 -noout -enddate 2>/dev/null \
            | cut -d= -f2 || true)
        if [[ -z "$expiry_str" ]]; then
            cert_label="N/A"; cert_color="$YELLOW"
        else
            local expiry_epoch today_epoch days_left
            expiry_epoch=$(date -d "$expiry_str" +%s 2>/dev/null \
                || date -j -f "%b %d %T %Y %Z" "$expiry_str" +%s 2>/dev/null \
                || echo 0)
            today_epoch=$(date +%s)
            days_left=$(( (expiry_epoch - today_epoch) / 86400 ))
            if (( days_left < 0 )); then
                cert_label="EXPIRED"; cert_color="$RED"
            elif (( days_left < 14 )); then
                cert_label="${days_left}d!"; cert_color="$YELLOW"
            else
                cert_label="${days_left}d"; cert_color="$GREEN"
            fi
        fi

        # DNS resolution — LAN vs WAN
        local resolved_ip dns_label dns_color
        resolved_ip=$(getent hosts "${sub}.${domain}" 2>/dev/null | awk '{print $1; exit}' || true)
        if [[ -z "$resolved_ip" ]]; then
            dns_label="NXDOMAIN"; dns_color="$RED"
        elif [[ -n "${server_ip:-}" && "$resolved_ip" == "$server_ip" ]]; then
            dns_label="LAN ✓"; dns_color="$GREEN"
        else
            dns_label="WAN (${resolved_ip})"; dns_color="$YELLOW"
        fi

        printf "  %-20s %-38s " "$svc_name" "$url"
        printf "${http_color}%-8s${NC} " "$http_label"
        printf "${cert_color}%-8s${NC} " "$cert_label"
        printf "${dns_color}%s${NC}\n" "$dns_label"
    done

    echo "  ──────────────────────────────────────────────────────────────────────────────────"
    printf "  Results: ${GREEN}%d OK${NC}  ${YELLOW}%d WARN${NC}  ${RED}%d DOWN${NC}\n" \
        "$ok_count" "$warn_count" "$err_count"
    echo ""

    # ── Traefik API ────────────────────────────────────────────────────────────
    log_step "Checking Traefik API..."
    local traefik_version
    traefik_version=$(curl -sk --connect-timeout 3 http://127.0.0.1:8080/api/version 2>/dev/null \
        | grep -o '"Version":"[^"]*"' | cut -d'"' -f4 || true)
    if [[ -n "$traefik_version" ]]; then
        log_success "Traefik API reachable — version ${traefik_version}"
    else
        log_warning "Traefik API not reachable on 127.0.0.1:8080"
    fi
    echo ""

    _check_docker_networks
    echo ""
}

# Internal: check all three CoreX Docker networks
_check_docker_networks() {
    log_step "Checking Docker networks..."
    for net in proxy-net monitoring-net ai-net; do
        if docker network inspect "$net" &>/dev/null; then
            local containers
            containers=$(docker network inspect "$net" \
                --format '{{range $k,$v := .Containers}}{{$v.Name}} {{end}}' 2>/dev/null \
                | tr ' ' '\n' | grep -c '[^[:space:]]' || echo 0)
            log_success "${net}: ${containers} container(s) connected"
        else
            log_warning "${net}: network not found"
        fi
    done
}

# ── help ──────────────────────────────────────────────────────────────────────

cmd_help() {
    echo ""
    echo -e "${BOLD}CoreX Pro v2 — Service Manager${NC}"
    cat << HELPEOF

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
  health              Host hardware health (temp, SMART, dpkg, last shutdown)
  os-upgrade          Supervised OS package upgrade (refuses if too hot/unstable)
  storage             Show disk usage breakdown (OS disk, SSD, per-service)
  cleanup [--dry-run] Remove stale Docker images and build cache safely
  lan-setup           Configure LAN fast-path for direct local network access
  network-tune        Diagnose and optimize network for high-speed file transfers
  network-check       Test HTTPS reachability, SSL expiry, and DNS for all services

Examples:
  sudo bash corex-manage.sh status
  sudo bash corex-manage.sh add stalwart
  sudo bash corex-manage.sh update --all
  sudo bash corex-manage.sh remove n8n
  sudo bash corex-manage.sh lan-setup
  sudo bash corex-manage.sh network-tune
  sudo bash corex-manage.sh network-check
  sudo bash corex-manage.sh health
  sudo bash corex-manage.sh os-upgrade

HELPEOF
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    check_root
    _load_config

    local cmd="${1:-help}"
    shift || true

    case "$cmd" in
        status)       cmd_status ;;
        list)         cmd_list ;;
        add)          cmd_add "$@" ;;
        remove)       cmd_remove "$@" ;;
        enable)       cmd_enable "$@" ;;
        disable)      cmd_disable "$@" ;;
        update)       cmd_update "$@" ;;
        repair)       cmd_repair "$@" ;;
        replace)      cmd_replace "$@" ;;
        doctor)       cmd_doctor ;;
        health)       cmd_health ;;
        os-upgrade)   cmd_os_upgrade "$@" ;;
        storage)      cmd_storage ;;
        cleanup)      cmd_cleanup "$@" ;;
        lan-setup)    cmd_lan_setup ;;
        network-tune)  cmd_network_tune ;;
        network-check) cmd_network_check ;;
        help|--help|-h) cmd_help ;;
        *) echo "Unknown command: ${cmd}"; cmd_help; exit 1 ;;
    esac
}

main "$@"
