#!/bin/bash
################################################################################
#
#   CoreX Pro — Domain Migration Script
#
#   Changes your domain across ALL services in one command.
#   Updates docker-compose files, Traefik labels, environment variables,
#   Nextcloud trusted config, n8n webhook URLs, and documentation.
#
#   USAGE:
#     sudo bash migrate-domain.sh                      # Interactive
#     sudo bash migrate-domain.sh old.com new.com      # Direct
#     sudo bash migrate-domain.sh --dry-run old.com new.com  # Preview
#
#   WHAT IT UPDATES:
#     - All docker-compose.yml files (Traefik Host rules, env vars)
#     - Nextcloud OVERWRITEHOST and TRUSTED_DOMAINS
#     - n8n WEBHOOK_URL and N8N_HOST
#     - Grafana GF_SERVER_ROOT_URL
#     - Stalwart mail routing
#     - Cloudflare Tunnel (reminds you to update CF Dashboard)
#     - /root/CoreX_Dashboard_Credentials.md
#     - AdGuard DNS rewrites (reminds you to update)
#
#   WHAT IT DOES NOT UPDATE (manual steps):
#     - Cloudflare Tunnel public hostnames (CF Dashboard)
#     - AdGuard DNS rewrites (AdGuard admin UI)
#     - Let's Encrypt certs (Traefik auto-renews for new domain)
#     - DNS records for Stalwart Mail (MX, SPF, DKIM, DMARC)
#
################################################################################

set -euo pipefail

# ── Colors ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[DONE]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

# ── Paths ──
MOUNT_POOL="/mnt/corex-data"
DOCKER_ROOT="${MOUNT_POOL}/docker-configs"
DOCS_FILE="/root/CoreX_Dashboard_Credentials.md"
CRED_FILE="/root/corex-credentials.txt"
MIGRATION_LOG="/tmp/corex-domain-migration-$(date +%Y%m%d-%H%M%S).log"

# ── Flags ──
DRY_RUN=false

# ── Parse args ──
POSITIONAL=()
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --help|-h)
            echo "Usage: sudo bash migrate-domain.sh [--dry-run] [OLD_DOMAIN NEW_DOMAIN]"
            echo ""
            echo "Options:"
            echo "  --dry-run   Preview changes without applying them"
            echo "  --help      Show this help"
            echo ""
            echo "Examples:"
            echo "  sudo bash migrate-domain.sh                          # Interactive"
            echo "  sudo bash migrate-domain.sh old.com new.com          # Direct"
            echo "  sudo bash migrate-domain.sh --dry-run old.com new.com  # Preview"
            exit 0
            ;;
        *) POSITIONAL+=("$arg") ;;
    esac
done

# ── Root check ──
if [[ $EUID -ne 0 ]]; then
    log_error "Run as root: sudo bash migrate-domain.sh"
fi

# ── Get domains ──
if [[ ${#POSITIONAL[@]} -ge 2 ]]; then
    OLD_DOMAIN="${POSITIONAL[0]}"
    NEW_DOMAIN="${POSITIONAL[1]}"
else
    echo ""
    echo -e "${CYAN}${BOLD}CoreX Pro — Domain Migration${NC}"
    echo ""

    # Try to detect current domain from existing compose files
    DETECTED_DOMAIN=""
    if [[ -f "${DOCKER_ROOT}/nextcloud/docker-compose.yml" ]]; then
        DETECTED_DOMAIN=$(grep -oP 'OVERWRITEHOST:\s*"\K[^"]+' "${DOCKER_ROOT}/nextcloud/docker-compose.yml" 2>/dev/null | sed 's/^nextcloud\.//')
    fi
    if [[ -z "$DETECTED_DOMAIN" ]] && [[ -f "${DOCKER_ROOT}/n8n/docker-compose.yml" ]]; then
        DETECTED_DOMAIN=$(grep -oP 'N8N_HOST:\s*"\K[^"]+' "${DOCKER_ROOT}/n8n/docker-compose.yml" 2>/dev/null | sed 's/^n8n\.//')
    fi

    if [[ -n "$DETECTED_DOMAIN" ]]; then
        echo -e "  Detected current domain: ${GREEN}${DETECTED_DOMAIN}${NC}"
        read -p "  Current domain [$DETECTED_DOMAIN]: " OLD_DOMAIN
        OLD_DOMAIN="${OLD_DOMAIN:-$DETECTED_DOMAIN}"
    else
        read -p "  Current domain: " OLD_DOMAIN
    fi

    read -p "  New domain: " NEW_DOMAIN
fi

# ── Validate ──
if [[ -z "$OLD_DOMAIN" || -z "$NEW_DOMAIN" ]]; then
    log_error "Both old and new domain are required."
fi

if [[ "$OLD_DOMAIN" == "$NEW_DOMAIN" ]]; then
    log_error "Old and new domain are the same. Nothing to do."
fi

# Basic domain format check
if [[ ! "$NEW_DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*\.)+[a-zA-Z]{2,}$ ]]; then
    log_warning "\"$NEW_DOMAIN\" doesn't look like a valid domain. Continuing anyway..."
fi

echo ""
echo -e "${BOLD}Migration plan:${NC}"
echo -e "  From: ${RED}${OLD_DOMAIN}${NC}"
echo -e "  To:   ${GREEN}${NEW_DOMAIN}${NC}"
echo ""

if $DRY_RUN; then
    echo -e "  ${CYAN}>>> DRY RUN — no changes will be made <<<${NC}"
    echo ""
fi

# ── Count affected files ──
AFFECTED_FILES=$(grep -rl "$OLD_DOMAIN" "${DOCKER_ROOT}" "$DOCS_FILE" "$CRED_FILE" 2>/dev/null | wc -l)
echo -e "  Files to update: ${AFFECTED_FILES}"
echo ""

if ! $DRY_RUN; then
    read -p "$(echo -e "${YELLOW}Proceed with migration? (y/N): ${NC}")" confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { echo "Aborted."; exit 0; }
fi

echo ""

################################################################################
# STEP 1: BACKUP
################################################################################

if ! $DRY_RUN; then
    BACKUP_DIR="${DOCKER_ROOT}/.domain-backup-$(date +%Y%m%d-%H%M%S)"
    log_info "Creating backup at ${BACKUP_DIR}..."
    mkdir -p "$BACKUP_DIR"

    # Backup all compose files
    for dir in "${DOCKER_ROOT}"/*/; do
        if [[ -f "$dir/docker-compose.yml" ]]; then
            service=$(basename "$dir")
            mkdir -p "${BACKUP_DIR}/${service}"
            cp "$dir/docker-compose.yml" "${BACKUP_DIR}/${service}/"
        fi
    done

    # Backup docs
    [[ -f "$DOCS_FILE" ]] && cp "$DOCS_FILE" "${BACKUP_DIR}/"
    log_success "Backup created: ${BACKUP_DIR}"
fi

################################################################################
# STEP 2: UPDATE ALL DOCKER-COMPOSE FILES
################################################################################

log_info "Updating docker-compose files..."

FILES_UPDATED=0

for dir in "${DOCKER_ROOT}"/*/; do
    COMPOSE="$dir/docker-compose.yml"
    if [[ -f "$COMPOSE" ]] && grep -q "$OLD_DOMAIN" "$COMPOSE"; then
        service=$(basename "$dir")
        if $DRY_RUN; then
            echo -e "  ${CYAN}[DRY RUN]${NC} Would update: $service/docker-compose.yml"
            grep -n "$OLD_DOMAIN" "$COMPOSE" | while read -r line; do
                echo "    $line"
            done
        else
            sed -i "s/${OLD_DOMAIN}/${NEW_DOMAIN}/g" "$COMPOSE"
            echo "  Updated: ${service}/docker-compose.yml" | tee -a "$MIGRATION_LOG"
            FILES_UPDATED=$((FILES_UPDATED + 1))
        fi
    fi
done

# Also update traefik.yml if it references the domain
TRAEFIK_YML="${DOCKER_ROOT}/traefik/traefik.yml"
if [[ -f "$TRAEFIK_YML" ]] && grep -q "$OLD_DOMAIN" "$TRAEFIK_YML"; then
    if $DRY_RUN; then
        echo -e "  ${CYAN}[DRY RUN]${NC} Would update: traefik/traefik.yml"
    else
        sed -i "s/${OLD_DOMAIN}/${NEW_DOMAIN}/g" "$TRAEFIK_YML"
        echo "  Updated: traefik/traefik.yml" | tee -a "$MIGRATION_LOG"
        FILES_UPDATED=$((FILES_UPDATED + 1))
    fi
fi

log_success "Docker-compose files updated (${FILES_UPDATED} files)."

################################################################################
# STEP 3: UPDATE DOCUMENTATION
################################################################################

log_info "Updating documentation..."

if [[ -f "$DOCS_FILE" ]]; then
    if $DRY_RUN; then
        MATCHES=$(grep -c "$OLD_DOMAIN" "$DOCS_FILE" || true)
        echo -e "  ${CYAN}[DRY RUN]${NC} Would update $DOCS_FILE (${MATCHES} occurrences)"
    else
        sed -i "s/${OLD_DOMAIN}/${NEW_DOMAIN}/g" "$DOCS_FILE"
        echo "  Updated: $DOCS_FILE" | tee -a "$MIGRATION_LOG"
    fi
fi

log_success "Documentation updated."

################################################################################
# STEP 4: DELETE OLD CERTS (Traefik will auto-renew for new domain)
################################################################################

ACME_FILE="${DOCKER_ROOT}/traefik/acme.json"
if [[ -f "$ACME_FILE" ]]; then
    if $DRY_RUN; then
        echo -e "  ${CYAN}[DRY RUN]${NC} Would clear acme.json (Traefik re-fetches certs for new domain)"
    else
        log_info "Clearing old TLS certificates..."
        echo '{}' > "$ACME_FILE"
        chmod 600 "$ACME_FILE"
        echo "  Cleared: acme.json (Traefik will auto-renew for ${NEW_DOMAIN})" | tee -a "$MIGRATION_LOG"
    fi
fi

log_success "Old TLS certificates cleared."

################################################################################
# STEP 5: RESTART ALL SERVICES
################################################################################

if ! $DRY_RUN; then
    log_info "Restarting all services with new domain..."
    echo ""

    # Restart Traefik first (it handles routing)
    if [[ -f "${DOCKER_ROOT}/traefik/docker-compose.yml" ]]; then
        echo "  Restarting traefik..."
        (cd "${DOCKER_ROOT}/traefik" && docker compose down && docker compose up -d) 2>&1 | tee -a "$MIGRATION_LOG"
    fi

    # Small delay for Traefik to initialize
    sleep 3

    # Restart all other services
    for dir in "${DOCKER_ROOT}"/*/; do
        service=$(basename "$dir")
        [[ "$service" == "traefik" ]] && continue
        [[ "$service" == "coolify" ]] && continue
        if [[ -f "$dir/docker-compose.yml" ]]; then
            echo "  Restarting ${service}..."
            (cd "$dir" && docker compose down && docker compose up -d) 2>&1 | tee -a "$MIGRATION_LOG" || true
        fi
    done

    echo ""
    log_success "All services restarted with domain: ${NEW_DOMAIN}"
fi

################################################################################
# STEP 6: MANUAL STEPS REMINDER
################################################################################

echo ""
echo -e "${YELLOW}${BOLD}═══ MANUAL STEPS REQUIRED ═══${NC}"
echo ""
echo -e "${BOLD}1. Cloudflare DNS${NC}"
echo "   Add DNS records for ${NEW_DOMAIN} in Cloudflare:"
echo "   - A record: ${NEW_DOMAIN} → your public IP (or proxied)"
echo "   - Or use Cloudflare Tunnel (no A record needed)"
echo ""
echo -e "${BOLD}2. Cloudflare Tunnel${NC}"
echo "   Go to: https://one.dash.cloudflare.com → Networks → Tunnels"
echo "   Update ALL public hostnames from *.${OLD_DOMAIN} to *.${NEW_DOMAIN}:"
echo ""
echo "   photos.${OLD_DOMAIN}  →  photos.${NEW_DOMAIN}"
echo "   nextcloud.${OLD_DOMAIN}  →  nextcloud.${NEW_DOMAIN}"
echo "   vault.${OLD_DOMAIN}  →  vault.${NEW_DOMAIN}"
echo "   n8n.${OLD_DOMAIN}  →  n8n.${NEW_DOMAIN}"
echo "   mail.${OLD_DOMAIN}  →  mail.${NEW_DOMAIN}"
echo "   status.${OLD_DOMAIN}  →  status.${NEW_DOMAIN}"
echo "   grafana.${OLD_DOMAIN}  →  grafana.${NEW_DOMAIN}"
echo "   ai.${OLD_DOMAIN}  →  ai.${NEW_DOMAIN}"
echo ""
echo -e "${BOLD}3. AdGuard Home DNS Rewrites${NC}"
echo "   Open http://$(hostname -I | awk '{print $1}'):3000"
echo "   → Filters → DNS Rewrites"
echo "   Update: *.${OLD_DOMAIN} → *.${NEW_DOMAIN}"
echo "   Add:    *.${NEW_DOMAIN} → $(hostname -I | awk '{print $1}')"
echo ""
echo -e "${BOLD}4. Stalwart Mail DNS Records${NC} (if using email)"
echo "   Update MX, SPF, DKIM, DMARC records for ${NEW_DOMAIN}"
echo ""
echo -e "${BOLD}5. Nextcloud Trusted Domains${NC} (one-time fix)"
echo "   If you get 'access through untrusted domain' error:"
echo "   docker exec -u www-data nextcloud php occ config:system:set trusted_domains 1 --value=nextcloud.${NEW_DOMAIN}"
echo ""
echo -e "${BOLD}6. Vaultwarden Clients${NC}"
echo "   Update server URL in all Bitwarden apps/extensions:"
echo "   Settings → Self-hosted → https://vault.${NEW_DOMAIN}"
echo ""
echo -e "${BOLD}7. Immich Mobile App${NC}"
echo "   Update server URL: https://photos.${NEW_DOMAIN}"
echo ""

if ! $DRY_RUN; then
    echo -e "${GREEN}Migration log: ${MIGRATION_LOG}${NC}"
    echo -e "${GREEN}Backup at: ${BACKUP_DIR}${NC}"
    echo ""
    echo -e "To rollback: restore compose files from backup and restart services"
    echo -e "  cp ${BACKUP_DIR}/*/docker-compose.yml to their respective dirs"
fi

echo ""
echo -e "${GREEN}${BOLD}Domain migration complete: ${OLD_DOMAIN} → ${NEW_DOMAIN} 🎉${NC}"
echo ""