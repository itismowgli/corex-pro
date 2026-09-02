#!/bin/bash
# lib/preflight.sh — CoreX Pro v2
# Phase 0: Pre-flight checks, internet validation, password management.
# Extracted from install-corex-master.sh Phase 0.

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=lib/state.sh
source "$(dirname "${BASH_SOURCE[0]}")/state.sh"

phase0_precheck() {
    log_step "═══ PHASE 0: Pre-Flight Checks ═══"

    # 1. Internet check
    if ping -c 1 -W 3 google.com &>/dev/null; then
        log_success "Internet connection OK."
    else
        log_warning "Internet check failed. Proceeding anyway, but downloads may fail."
    fi

    # 2. RAM check
    local mem_total
    mem_total=$(free -g | awk '/Mem/{print $2}')
    if [[ $mem_total -lt 8 ]]; then
        log_warning "Low RAM: ${mem_total}GB. AI services may be slow. 8GB+ recommended."
    else
        log_success "RAM: ${mem_total}GB — sufficient."
    fi

    # 3. Load or generate passwords
    if [[ -f "$CRED_FILE" ]]; then
        log_info "Loading existing credentials from $CRED_FILE..."
        # cred_get, not awk on a field number. Splitting on whitespace
        # truncates any password containing a space, and the correct field
        # number differs per label because the labels differ in word count,
        # which is why Vaultwarden read $2 while the rest read $3 or $4.
        # corex-manage must resolve a credential to exactly the same string
        # this does, or a repair hands a service the wrong password for its
        # own database.
        MYSQL_ROOT_PASS=$(cred_get "MySQL Root:")
        NEXTCLOUD_DB_PASS=$(cred_get "Nextcloud DB:")
        N8N_ENCRYPTION_KEY=$(cred_get "n8n Encryption:")
        TM_PASSWORD=$(cred_get "Time Machine:")
        VAULTWARDEN_ADMIN_TOKEN=$(cred_get "Vaultwarden:")
        GRAFANA_ADMIN_PASS=$(cred_get "Grafana Admin:")
        RESTIC_PASSWORD=$(cred_get "Restic Backup:")
        IMMICH_DB_PASS=$(cred_get "Immich DB:")
        WEBUI_SECRET_KEY=$(cred_get "AI WebUI Secret:")
        STALWART_ADMIN_PASS=$(cred_get "Stalwart Admin:")
        [[ -z "$STALWART_ADMIN_PASS" ]] && \
            STALWART_ADMIN_PASS="(unknown, check: docker logs stalwart | grep password)"
        log_success "Existing passwords loaded."
    else
        log_info "First run — generating secure passwords..."
        MYSQL_ROOT_PASS=$(generate_pass)
        NEXTCLOUD_DB_PASS=$(generate_pass)
        N8N_ENCRYPTION_KEY=$(generate_pass)
        TM_PASSWORD=$(generate_pass)
        VAULTWARDEN_ADMIN_TOKEN=$(generate_pass)
        GRAFANA_ADMIN_PASS=$(generate_pass)
        RESTIC_PASSWORD=$(generate_pass)
        IMMICH_DB_PASS=$(generate_pass)
        WEBUI_SECRET_KEY=$(generate_pass)
        STALWART_ADMIN_PASS=""
        log_success "Passwords generated (saved at end of install)."
    fi

    # Export all passwords so service modules can use them
    export MYSQL_ROOT_PASS NEXTCLOUD_DB_PASS N8N_ENCRYPTION_KEY TM_PASSWORD
    export VAULTWARDEN_ADMIN_TOKEN GRAFANA_ADMIN_PASS RESTIC_PASSWORD
    export IMMICH_DB_PASS WEBUI_SECRET_KEY STALWART_ADMIN_PASS

    # 4. Set timezone
    timedatectl set-timezone "${TIMEZONE:-UTC}" 2>/dev/null || true
    log_success "Timezone: ${TIMEZONE:-UTC}"
}
