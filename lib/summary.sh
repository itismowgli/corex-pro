#!/bin/bash
# lib/summary.sh — CoreX Pro v2
# Phase 7: Save credentials and generate comprehensive dashboard docs.
# Writes /root/corex-credentials.txt (first run only) and
# /root/CoreX_Dashboard_Credentials.md (every run).

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

phase7_summary() {
    log_step "═══ PHASE 7: Save Credentials & Generate Docs ═══"

    # ── Save raw credentials (first run only) ────────────────────────────────
    if [[ ! -f "$CRED_FILE" ]]; then
        cat > "$CRED_FILE" << CREDEOF
MySQL Root:      $MYSQL_ROOT_PASS
Nextcloud DB:    $NEXTCLOUD_DB_PASS
n8n Encryption:  $N8N_ENCRYPTION_KEY
Time Machine:    $TM_PASSWORD
Vaultwarden:     $VAULTWARDEN_ADMIN_TOKEN
Grafana Admin:   $GRAFANA_ADMIN_PASS
Restic Backup:   $RESTIC_PASSWORD
Immich DB:       $IMMICH_DB_PASS
AI WebUI Secret: $WEBUI_SECRET_KEY
Stalwart Admin:  admin / $STALWART_ADMIN_PASS
CREDEOF
        chmod 600 "$CRED_FILE"
        log_success "Raw credentials saved to $CRED_FILE"
    fi

    # ── Installed services list (from state.json) ────────────────────────────
    local installed_list
    installed_list=$(state_list_installed 2>/dev/null | tr '\n' ' ')

    # ── Generate Markdown docs ───────────────────────────────────────────────
    cat > "$DOCS_FILE" << DOCSEOF
# CoreX Pro v2 — Dashboard & Credentials

> **Generated:** $(date '+%A, %B %d, %Y at %I:%M %p %Z')
> **Server IP:** \`${SERVER_IP}\`
> **Domain:** \`${DOMAIN:-local-only}\`
> **SSH Port:** \`${SSH_PORT}\`
> **Installed Services:** ${installed_list}

---

## Service Credentials

| Service | Admin URL | Username | Password / Token |
|---------|-----------|----------|-----------------|
| **Nextcloud** | \`https://nextcloud.${DOMAIN}\` | *(create on first visit)* | *(you choose)* |
| **Nextcloud DB** | *(internal)* | \`nextcloud\` | \`${NEXTCLOUD_DB_PASS}\` |
| **MySQL Root** | *(internal)* | \`root\` | \`${MYSQL_ROOT_PASS}\` |
| **Immich** | \`https://photos.${DOMAIN}\` | *(create on first visit)* | *(you choose)* |
| **Immich DB** | *(internal)* | \`postgres\` | \`${IMMICH_DB_PASS}\` |
| **Vaultwarden** | \`https://vault.${DOMAIN}\` | *(create on first visit)* | *(you choose)* |
| **Vaultwarden Admin** | \`https://vault.${DOMAIN}/admin\` | *(token-based)* | \`${VAULTWARDEN_ADMIN_TOKEN}\` |
| **n8n** | \`https://n8n.${DOMAIN}\` | *(create on first visit)* | *(you choose)* |
| **n8n Encryption Key** | *(internal)* | — | \`${N8N_ENCRYPTION_KEY}\` |
| **Grafana** | \`https://grafana.${DOMAIN}\` | \`admin\` | \`${GRAFANA_ADMIN_PASS}\` |
| **Portainer** | \`https://${SERVER_IP}:9443\` | *(create on first visit)* | *(you choose)* |
| **Stalwart Mail** | \`https://mail.${DOMAIN}\` | \`admin\` | \`${STALWART_ADMIN_PASS}\` |
| **Uptime Kuma** | \`https://status.${DOMAIN}\` | *(create on first visit)* | *(you choose)* |
| **Open WebUI** | \`https://ai.${DOMAIN}\` | *(create on first visit)* | *(you choose)* |
| **Time Machine** | \`smb://${SERVER_IP}/CoreX_Backup\` | \`timemachine\` | \`${TM_PASSWORD}\` |
| **Restic Backup** | *(CLI only)* | — | \`${RESTIC_PASSWORD}\` |
| **AdGuard Home** | \`http://${SERVER_IP}:3000\` | *(create during setup)* | *(you choose)* |
| **Traefik Dashboard** | \`http://${SERVER_IP}:8080\` | *(no auth)* | *(no auth)* |

> ⚠️ **"Create on first visit"** means the first person to open the URL becomes admin.
> Complete setup for Portainer, Nextcloud, Immich, n8n, and Uptime Kuma **immediately** after install.

---

## Quick Access URLs

| Service | URL |
|---------|-----|
| Traefik Dashboard | \`http://${SERVER_IP}:8080\` |
| AdGuard Home | \`http://${SERVER_IP}:3000\` |
| Portainer | \`https://${SERVER_IP}:9443\` |
| Nextcloud | \`https://nextcloud.${DOMAIN}\` |
| Photos (Immich) | \`https://photos.${DOMAIN}\` |
| Passwords (Vault) | \`https://vault.${DOMAIN}\` |
| n8n Automation | \`https://n8n.${DOMAIN}\` |
| Mail Server | \`https://mail.${DOMAIN}\` |
| Status Page | \`https://status.${DOMAIN}\` |
| Grafana | \`https://grafana.${DOMAIN}\` |
| AI Chat | \`https://ai.${DOMAIN}\` |
| Time Machine | \`smb://${SERVER_IP}/CoreX_Backup\` |
| Coolify | \`http://${SERVER_IP}:8000\` |

---

## Cloudflare Tunnel Public Hostnames

In CF Dashboard → Networks → Tunnels → your tunnel → Public Hostnames:

| Hostname | Service Type | URL |
|----------|-------------|-----|
| \`n8n.${DOMAIN}\` | HTTP | \`n8n:5678\` |
| \`photos.${DOMAIN}\` | HTTP | \`immich-server:2283\` |
| \`nextcloud.${DOMAIN}\` | HTTP | \`nextcloud:80\` |
| \`vault.${DOMAIN}\` | HTTP | \`vaultwarden:80\` |
| \`mail.${DOMAIN}\` | HTTP | \`stalwart:8080\` |
| \`status.${DOMAIN}\` | HTTP | \`uptime-kuma:3001\` |
| \`grafana.${DOMAIN}\` | HTTP | \`grafana:3000\` |
| \`ai.${DOMAIN}\` | HTTP | \`open-webui:8080\` |

> Use CONTAINER NAMES (not localhost). Enable "No TLS Verify" for each hostname.

---

## File Locations

| What | Path |
|------|------|
| This document | \`${DOCS_FILE}\` |
| Raw credentials | \`${CRED_FILE}\` |
| State file | \`/etc/corex/state.json\` |
| Service compose files | \`${DOCKER_ROOT}/<service>/docker-compose.yml\` |
| Service data | \`${DATA_ROOT}/<service>/\` |
| Backup repository | \`${BACKUP_ROOT}/restic-repo/\` |
| Backup script | \`/usr/local/bin/corex-backup.sh\` |
| Restore script | \`/usr/local/bin/corex-restore.sh\` |

---

## Management Commands

\`\`\`bash
# Health check all services
sudo bash /opt/corex-pro/corex.sh doctor

# Add a service that was skipped during install
sudo bash /opt/corex-pro/corex-manage.sh add <service>

# Remove a service
sudo bash /opt/corex-pro/corex-manage.sh remove <service>

# Update all container images
sudo bash /opt/corex-pro/corex-manage.sh update --all

# Manual backup
sudo corex-backup.sh

# Restore from backup
sudo corex-restore.sh [snapshot-id]
\`\`\`

---

*CoreX Pro v2 — Own your data. Own your stack.*
DOCSEOF

    chmod 600 "$DOCS_FILE"
    log_success "Dashboard docs saved to $DOCS_FILE"

    # ── Terminal summary ─────────────────────────────────────────────────────
    clear
    echo ""
    echo -e "${GREEN}${BOLD}"
    echo "  ╔══════════════════════════════════════════════════════════════╗"
    echo "  ║        CoreX Pro v2 — Installation Complete!               ║"
    echo "  ╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    echo -e "  ${CYAN}INSTALLED SERVICES${NC}"
    echo "  ──────────────────────────────────────────────────────────────"
    for svc in $installed_list; do
        printf "  ✓ %-20s\n" "$svc"
    done
    echo ""
    echo -e "  ${YELLOW}${BOLD}READ THE FULL GUIDE:${NC}  cat $DOCS_FILE"
    echo -e "  ${YELLOW}${BOLD}VIEW PASSWORDS:${NC}       cat $CRED_FILE"
    echo ""
    echo -e "  ${YELLOW}${BOLD}FIRST THINGS TO DO:${NC}"
    echo "    1. AdGuard: http://${SERVER_IP}:3000 → setup → DNS Rewrites *.${DOMAIN} → ${SERVER_IP}"
    echo "    2. Cloudflare Tunnel: set public hostnames (see docs above)"
    echo "    3. Create admin accounts: Portainer, Nextcloud, Immich, Vaultwarden"
    echo ""
    echo -e "  ${GREEN}Your data. Your stack. Sovereign homelab. 🏴${NC}"
    echo ""
}
