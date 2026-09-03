#!/bin/bash
# lib/wizard.sh — CoreX Pro v2
# Interactive configuration wizard.
# Uses whiptail when available and stdin is a terminal; falls back to plain read.
#
# Exports all required variables for the installer:
#   DOMAIN, SERVER_IP, EMAIL, TIMEZONE, SSH_PORT,
#   CLOUDFLARE_TUNNEL_TOKEN, MODE, SELECTED_SERVICES (array)

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ── Input Validation ───────────────────────────────────────────────────────────

# Validate an IPv4 address. Returns 0 if valid, 1 if not.
validate_ip() {
    local ip="$1"
    [[ -z "$ip" ]] && return 1
    local IFS='.'
    read -r -a octets <<< "$ip"
    [[ "${#octets[@]}" -ne 4 ]] && return 1
    local o
    for o in "${octets[@]}"; do
        [[ "$o" =~ ^[0-9]+$ ]] || return 1
        [[ "$o" -ge 0 && "$o" -le 255 ]] || return 1
    done
    return 0
}

# Validate a domain name. Returns 0 if valid, 1 if not.
# Requires at least one dot and no leading dot or spaces.
validate_domain() {
    local domain="$1"
    [[ -z "$domain" ]] && return 1
    [[ "$domain" == .* ]] && return 1
    [[ "$domain" =~ [[:space:]] ]] && return 1
    [[ "$domain" =~ \. ]] || return 1   # Must contain at least one dot
    [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] || return 1
    return 0
}

# Validate an email address. Returns 0 if valid, 1 if not.
validate_email() {
    local email="$1"
    [[ -z "$email" ]] && return 1
    [[ "$email" =~ ^[^@]+@[^@]+\.[^@]+$ ]] || return 1
    return 0
}

# ── Whiptail/Plain Helper ──────────────────────────────────────────────────────

# Check if we can use whiptail (installed + stdin is terminal)
_has_whiptail() {
    command -v whiptail &>/dev/null && [[ -t 0 ]]
}

# Display a message box
_msgbox() {
    local title="$1" msg="$2"
    if _has_whiptail; then
        whiptail --title "$title" --msgbox "$msg" 10 60 3>&1 1>&2 2>&3
    else
        echo -e "\n${BOLD}${title}${NC}"
        echo "$msg"
        echo ""
    fi
}

# Get text input from user
# Usage: value=$(_inputbox "Title" "Prompt" "default")
_inputbox() {
    local title="$1" prompt="$2" default="${3:-}"
    if _has_whiptail; then
        whiptail --title "$title" --inputbox "$prompt" 10 60 "$default" 3>&1 1>&2 2>&3
    else
        echo -e "${CYAN}${title}${NC}" >&2
        echo -e "${prompt}" >&2
        [[ -n "$default" ]] && echo -e "(default: ${default})" >&2
        local val
        read -r -p "> " val
        echo "${val:-$default}"
    fi
}

# Present a menu and return the chosen value
# Usage: choice=$(_menu "Title" "Prompt" "opt1" "desc1" "opt2" "desc2" ...)
_menu() {
    local title="$1" prompt="$2"
    shift 2
    if _has_whiptail; then
        whiptail --title "$title" --menu "$prompt" 20 70 10 "$@" 3>&1 1>&2 2>&3
    else
        echo -e "\n${CYAN}${title}${NC}" >&2
        echo -e "${prompt}" >&2
        local i=1
        local items=("$@")
        while [[ $i -le ${#items[@]} ]]; do
            local key="${items[$((i-1))]}"
            local desc="${items[$i]}"
            echo "  $((i/2+1)). $key — $desc" >&2
            ((i+=2))
        done
        local choice
        read -r -p "> " choice
        # Return the key at that position
        echo "${items[$(((choice-1)*2))]}"
    fi
}

# Present a checklist and return space-separated selected items
# Usage: selected=$(_checklist "Title" "Prompt" "item1" "desc1" "ON|OFF" ...)
_checklist() {
    local title="$1" prompt="$2"
    shift 2
    if _has_whiptail; then
        whiptail --title "$title" \
            --checklist "$prompt" 25 78 15 "$@" 3>&1 1>&2 2>&3
    else
        echo -e "\n${CYAN}${title}${NC}" >&2
        echo -e "${prompt}" >&2
        echo "(Enter comma-separated numbers, e.g. 1,3,5)" >&2
        echo "" >&2
        local items=("$@")
        local i=1 idx=1
        while [[ $i -le ${#items[@]} ]]; do
            local key="${items[$((i-1))]}"
            local desc="${items[$i]}"
            local state="${items[$((i+1))]}"
            local mark=" "; [[ "$state" == "ON" ]] && mark="*"
            echo "  [$mark] $idx. $key — $desc" >&2
            ((i+=3)); ((idx++))
        done
        local input selected=()
        read -r -p "> " input
        IFS=',' read -r -a nums <<< "$input"
        local num
        for num in "${nums[@]}"; do
            local pos=$(( (num-1)*3 ))
            [[ -n "${items[$pos]:-}" ]] && selected+=("\"${items[$pos]}\"")
        done
        echo "${selected[*]}"
    fi
}

# ── Service Discovery ──────────────────────────────────────────────────────────

# Returns service names from lib/services/ in the given category
get_services_in_category() {
    local category="$1"
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local services_dir="${script_dir}/services"

    [[ -d "$services_dir" ]] || return 0

    local f
    for f in "${services_dir}"/*.sh; do
        [[ -f "$f" ]] || continue
        # Source temporarily in a subshell to read metadata
        local cat
        cat=$(bash -c "source '$f' 2>/dev/null; echo \"\${SERVICE_CATEGORY:-}\"")
        if [[ "$cat" == "$category" ]]; then
            bash -c "source '$f' 2>/dev/null; echo \"\${SERVICE_NAME:-}\""
        fi
    done
}

# ── Profile Presets ────────────────────────────────────────────────────────────

# SELECTED_SERVICES must be declared as an array in the calling scope
apply_profile() {
    local profile="$1"
    SELECTED_SERVICES=()
    case "$profile" in
        minimal)
            SELECTED_SERVICES=(traefik adguard portainer vaultwarden monitoring)
            ;;
        full)
            SELECTED_SERVICES=(traefik adguard portainer nextcloud immich vaultwarden stalwart n8n calcom coolify timemachine monitoring crowdsec cloudflared ai)
            ;;
        privacy)
            SELECTED_SERVICES=(traefik adguard portainer nextcloud immich vaultwarden stalwart crowdsec cloudflared monitoring)
            ;;
        dev)
            SELECTED_SERVICES=(traefik adguard portainer n8n coolify monitoring ai cloudflared)
            ;;
        nodomain)
            SELECTED_SERVICES=(adguard portainer timemachine monitoring)
            ;;
        *)
            SELECTED_SERVICES=()
            ;;
    esac
}

# ── Main Wizard ────────────────────────────────────────────────────────────────

# ── Outbound mail relay ───────────────────────────────────────────────────────
# Asked once, at install, and shared by every service that sends mail.
#
# This exists because "optional" email is a trap. Nextcloud silently cannot
# send a password reset without it, and some applications refuse to start at
# all rather than run with no way to send mail. Collecting it here means a
# service that needs a relay finds one already configured, instead of failing
# after install when it is least convenient.
#
# A relay is not a mail server. CoreX does not try to run one, because a
# residential connection cannot: ISPs block port 25 in both directions and
# domestic address ranges are on blocklists by default. Sending through an
# account that is already trusted is the working answer.
_wizard_smtp() {
    SMTP_HOST=""; SMTP_PORT="587"; SMTP_TLS_MODE="starttls"
    SMTP_USER=""; SMTP_PASSWORD=""; SMTP_FROM=""

    local want
    want=$(_menu "Outbound Email" \
"Some services need to send mail: password resets, alerts, booking
confirmations. CoreX can use any SMTP relay you already have.

A Gmail account with an app password is the usual choice and takes
two minutes: myaccount.google.com -> Security -> 2-Step Verification
-> App passwords.

Skipping is fine. Services that need mail will say so, and you can
add it later with: corex manage mail-setup" \
        "configure" "Set up a mail relay now (recommended)" \
        "skip"      "Skip, configure later")

    [[ "$want" != "configure" ]] && { export SMTP_HOST SMTP_PORT SMTP_TLS_MODE SMTP_USER SMTP_PASSWORD SMTP_FROM; return 0; }

    SMTP_HOST=$(_inputbox "SMTP Server" \
        "Your relay's hostname\nGmail: smtp.gmail.com" "smtp.gmail.com")
    SMTP_PORT=$(_inputbox "SMTP Port" \
        "587 for STARTTLS (usual), 465 for implicit TLS" "587")
    [[ "$SMTP_PORT" == "465" ]] && SMTP_TLS_MODE="implicit" || SMTP_TLS_MODE="starttls"
    SMTP_USER=$(_inputbox "SMTP Username" \
        "Usually the full email address" "")
    SMTP_PASSWORD=$(_inputbox "SMTP Password" \
"For Gmail this is a 16-character app password, NOT your account
password. Spaces are ignored, so paste it either way." "")
    # Google shows app passwords in four groups for readability; SMTP AUTH
    # wants the sixteen characters with no spaces, and an unstripped value
    # fails authentication with a message that blames the credentials.
    SMTP_PASSWORD="${SMTP_PASSWORD//[[:space:]]/}"
    SMTP_FROM=$(_inputbox "Sender Address" \
"The From address on outgoing mail.

It usually has to match the account above: Gmail rewrites or rejects
anything else. To send as you@${DOMAIN:-your-domain} you need a
transactional relay with your domain verified, not Gmail." \
        "${SMTP_USER}")

    export SMTP_HOST SMTP_PORT SMTP_TLS_MODE SMTP_USER SMTP_PASSWORD SMTP_FROM
}

# Persist the relay where services can find it. 0600 and outside state.json,
# which is 0644 and bind-mounted into a web-facing container (gotcha #24).
smtp_conf_write() {
    [[ -n "${SMTP_HOST:-}" && -n "${SMTP_USER:-}" ]] || return 0
    mkdir -p /etc/corex
    local prev_umask; prev_umask=$(umask); umask 077
    cat > /etc/corex/smtp.conf << SMTPEOF
# CoreX shared outbound mail relay. Sourced by services that send mail.
# Values are quoted: an unquoted password containing a space is parsed as a
# command prefix and silently never set.
COREX_SMTP_HOST='${SMTP_HOST}'
COREX_SMTP_PORT='${SMTP_PORT:-587}'
COREX_SMTP_TLS_MODE='${SMTP_TLS_MODE:-starttls}'
COREX_SMTP_USER='${SMTP_USER}'
COREX_SMTP_PASSWORD='${SMTP_PASSWORD}'
COREX_SMTP_FROM='${SMTP_FROM:-$SMTP_USER}'
SMTPEOF
    umask "$prev_umask"
    chmod 600 /etc/corex/smtp.conf
}

# Load it, if it exists. Safe to call when absent.
smtp_conf_load() {
    [[ -r /etc/corex/smtp.conf ]] || return 1
    # shellcheck source=/dev/null
    set -a; . /etc/corex/smtp.conf; set +a
    [[ -n "${COREX_SMTP_HOST:-}" ]]
}

run_wizard() {
    # ── Welcome ──────────────────────────────────────────────────────────────
    _msgbox "CoreX Pro v2 — Setup Wizard" \
"Welcome to CoreX Pro!

This wizard will configure your sovereign homelab.
You choose exactly which services to install.

Requirements:
  • Ubuntu 24.04 LTS
  • 8GB+ RAM recommended
  • External SSD (or large local disk)
  • (Optional) A domain name managed on Cloudflare"

    # ── Mode selection ───────────────────────────────────────────────────────
    MODE=$(_menu "Installation Mode" "How do you want to access your services?" \
        "with-domain"    "Full setup with domain + Cloudflare Tunnel + HTTPS" \
        "local-only"     "LAN-only access (no domain required)" \
        "configure-later" "Install now, configure domain later")

    export MODE

    # ── Domain & email (skip if local-only) ──────────────────────────────────
    DOMAIN=""
    EMAIL=""
    if [[ "$MODE" == "with-domain" ]]; then
        while true; do
            DOMAIN=$(_inputbox "Domain Configuration" \
                "Enter your domain name\nExample: myhomelab.com" "")
            validate_domain "$DOMAIN" && break
            _msgbox "Invalid Domain" "Please enter a valid domain (e.g., example.com)"
        done

        while true; do
            EMAIL=$(_inputbox "Email Address" \
                "Email for Let's Encrypt SSL certificates\nExample: admin@${DOMAIN}" \
                "admin@${DOMAIN}")
            validate_email "$EMAIL" && break
            _msgbox "Invalid Email" "Please enter a valid email address"
        done
    fi
    export DOMAIN EMAIL

    # ── Server IP ────────────────────────────────────────────────────────────
    local detected_ip
    detected_ip=$(hostname -I 2>/dev/null | awk '{print $1}')

    while true; do
        SERVER_IP=$(_inputbox "Server IP Address" \
            "Your server's static local IP address\nDetected: ${detected_ip}" \
            "${detected_ip}")
        validate_ip "$SERVER_IP" && break
        _msgbox "Invalid IP" "Please enter a valid IPv4 address (e.g., 192.168.1.100)"
    done
    export SERVER_IP

    # ── Cloudflare Tunnel token ───────────────────────────────────────────────
    CLOUDFLARE_TUNNEL_TOKEN="PASTE_YOUR_TUNNEL_TOKEN_HERE"
    if [[ "$MODE" == "with-domain" ]]; then
        CLOUDFLARE_TUNNEL_TOKEN=$(_inputbox "Cloudflare Tunnel" \
"Enter your Cloudflare Tunnel token (optional — press Enter to skip)

Get it at: one.dash.cloudflare.com → Networks → Tunnels → Create Tunnel
You can add it later with: corex-manage add cloudflared" \
            "PASTE_YOUR_TUNNEL_TOKEN_HERE")
    fi
    export CLOUDFLARE_TUNNEL_TOKEN

    # ── Outbound mail relay ──────────────────────────────────────────────────
    _wizard_smtp

    # ── Timezone ─────────────────────────────────────────────────────────────
    local detected_tz
    detected_tz=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "UTC")
    TIMEZONE=$(_inputbox "Timezone" \
        "Server timezone (e.g. America/New_York, Asia/Kolkata, Europe/London)" \
        "$detected_tz")
    export TIMEZONE

    # ── SSH port ─────────────────────────────────────────────────────────────
    SSH_PORT=$(_inputbox "SSH Port" \
        "Non-standard SSH port (security by obscurity)\nDefault: 2222" \
        "2222")
    export SSH_PORT

    # ── Docker storage location ───────────────────────────────────────────────
    # By default Docker stores image layers on the OS disk (/var/lib/docker).
    # Moving them to the external SSD keeps the OS disk for OS-only use.
    DOCKER_ON_SSD="false"
    if _has_whiptail; then
        if whiptail --title "Docker Storage" \
            --yesno "Move Docker image layers to external SSD?
(/mnt/corex-data/docker-engine)

YES — OS disk stays lean; Docker images + containers live on SSD (recommended)
NO  — Docker stays on OS disk (simpler, fine if OS disk is large enough)" \
            14 70; then
            DOCKER_ON_SSD="true"
        fi
    else
        echo -e "\n${CYAN}Docker Storage Location${NC}" >&2
        echo "Move Docker image layers to external SSD? (/mnt/corex-data/docker-engine)" >&2
        echo "YES = OS disk stays lean (recommended) | NO = Docker stays on OS disk" >&2
        local docker_ssd_choice
        read -r -p "Move to SSD? (y/N): " docker_ssd_choice
        [[ "$docker_ssd_choice" == "y" || "$docker_ssd_choice" == "Y" ]] && DOCKER_ON_SSD="true"
    fi
    export DOCKER_ON_SSD

    # ── Profile or custom selection ───────────────────────────────────────────
    local profile_choice
    profile_choice=$(_menu "Service Selection" "Choose a preset or customize:" \
        "minimal"  "Core only + Vaultwarden (~8GB RAM)" \
        "full"     "All services (~32GB RAM)" \
        "privacy"  "Privacy-focused: Nextcloud + Immich + Vault + Mail" \
        "dev"      "Dev stack: n8n + Coolify + Monitoring + AI" \
        "nodomain" "LAN-only: no domain required" \
        "custom"   "Choose services manually")

    declare -a SELECTED_SERVICES=()

    if [[ "$profile_choice" == "custom" ]]; then
        # Build checklist from all service modules
        local script_dir
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        local services_dir="${script_dir}/services"

        local checklist_items=()
        local f svc_info svc label required ram default_state
        for f in "${services_dir}"/*.sh; do
            [[ -f "$f" ]] || continue
            # Read metadata safely — no eval; use printf+IFS to avoid injection
            svc_info=$(bash -c "
                source '$f' 2>/dev/null
                printf '%s\t%s\t%s\t%s\n' \
                    \"\${SERVICE_NAME:-}\" \"\${SERVICE_LABEL:-}\" \
                    \"\${SERVICE_REQUIRED:-false}\" \"\${SERVICE_RAM_MB:-0}\"
            " 2>/dev/null)
            IFS=$'\t' read -r svc label required ram <<< "$svc_info"
            [[ -z "$svc" ]] && continue
            [[ "$required" == "true" ]] && default_state="ON" || default_state="OFF"
            checklist_items+=("$svc" "$label (RAM: ${ram}MB)" "$default_state")
        done

        local selected_raw
        selected_raw=$(_checklist "Service Selection" \
            "Select services to install (Space to toggle, Enter to confirm):" \
            "${checklist_items[@]}")

        # Parse selected services (remove quotes)
        local s
        for s in $selected_raw; do
            SELECTED_SERVICES+=("${s//\"/}")
        done
    else
        apply_profile "$profile_choice"
    fi

    # Always ensure core services are included
    local core_svc
    for core_svc in traefik adguard portainer; do
        local found=false
        local s
        for s in "${SELECTED_SERVICES[@]}"; do
            [[ "$s" == "$core_svc" ]] && found=true && break
        done
        [[ "$found" == "false" ]] && SELECTED_SERVICES+=("$core_svc")
    done

    export SELECTED_SERVICES

    # ── Confirmation summary ──────────────────────────────────────────────────
    local summary
    summary="Mode:     ${MODE}
Domain:   ${DOMAIN:-none}
Email:    ${EMAIL:-none}
Server IP: ${SERVER_IP}
SSH Port: ${SSH_PORT}
Timezone: ${TIMEZONE}
Tunnel:   $([ "$CLOUDFLARE_TUNNEL_TOKEN" != "PASTE_YOUR_TUNNEL_TOKEN_HERE" ] && echo "configured" || echo "skip")

Services to install:
$(printf '  • %s\n' "${SELECTED_SERVICES[@]}")"

    if _has_whiptail; then
        whiptail --title "Confirm Installation" \
            --yesno "${summary}\n\nProceed with installation?" 30 70
    else
        echo -e "\n${BOLD}Installation Summary${NC}"
        echo "─────────────────────"
        echo "$summary"
        echo ""
        local confirm
        read -r -p "Proceed with installation? (y/N): " confirm
        [[ "$confirm" == "y" || "$confirm" == "Y" ]] || { echo "Aborted."; exit 0; }
    fi

    log_success "Configuration complete. Starting installation..."
}
