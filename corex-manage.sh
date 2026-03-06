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
        PORT_FROM_YAML=$(grep -A5 "^http:" "$YAML_FILE" \
            | grep "address:" | grep -oP ':\K[0-9]+' | head -1)
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
    echo -e "    Secondary DNS: ${YELLOW}1.1.1.1${NC}  (fallback if server is offline)"
    echo ""
    echo "  Every device that joins your network will resolve"
    echo "  *.${DOMAIN} directly to this server without any extra steps."
    echo ""

    # ── Step 2: Per-device DNS ────────────────────────────────────────────────
    echo -e "${BOLD}── Step 2: Per-Device DNS (if you cannot change router settings) ───────────${NC}"
    echo ""
    echo "  macOS:   System Settings → Network → Wi-Fi → Details → DNS → ${SERVER_IP}"
    echo "  Windows: Control Panel → Network → Adapter → IPv4 → DNS: ${SERVER_IP}"
    echo "  iPhone:  Settings → Wi-Fi → (network) → Configure DNS → Manual → ${SERVER_IP}"
    echo "  Android: Settings → Wi-Fi → (network) → IP Settings → Static → DNS: ${SERVER_IP}"
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

    # ── Verify ────────────────────────────────────────────────────────────────
    echo -e "${BOLD}── Verify It's Working ─────────────────────────────────────────────────────${NC}"
    echo ""
    echo "  After any DNS change, flush your DNS cache first:"
    echo ""
    echo "  macOS:   sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder"
    echo "  Linux:   sudo systemd-resolve --flush-caches"
    echo "  Windows: ipconfig /flushdns"
    echo ""
    echo "  Then verify the IP is local (not a Cloudflare IP):"
    echo -e "    ${CYAN}nslookup nextcloud.${DOMAIN}${NC}"
    echo ""
    echo -e "  Expected: ${GREEN}${SERVER_IP}${NC}   ← your server's LAN IP"
    echo "  If you see 172.67.x.x or 104.21.x.x → use the Hosts File (Step 3)."
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
  network-tune        Diagnose and optimize network for high-speed file transfers

Examples:
  sudo bash corex-manage.sh status
  sudo bash corex-manage.sh add stalwart
  sudo bash corex-manage.sh update --all
  sudo bash corex-manage.sh remove n8n
  sudo bash corex-manage.sh lan-setup
  sudo bash corex-manage.sh network-tune

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
        lan-setup)    cmd_lan_setup ;;
        network-tune) cmd_network_tune ;;
        help|--help|-h) cmd_help ;;
        *) echo "Unknown command: ${cmd}"; cmd_help; exit 1 ;;
    esac
}

main "$@"
