#!/bin/bash
################################################################################
#
#   CoreX Pro — CLI
#
#   Single entry point for install, uninstall, and domain migration.
#
#   QUICK INSTALL:
#     curl -fsSL https://raw.githubusercontent.com/itismowgli/corex-pro/main/corex.sh | sudo bash
#
#   USAGE (after cloning):
#     sudo bash corex.sh              # Interactive menu
#     sudo bash corex.sh install      # Install CoreX Pro
#     sudo bash corex.sh nuke         # Uninstall / rollback
#     sudo bash corex.sh migrate      # Change domain
#     sudo bash corex.sh migrate --dry-run old.com new.com
#     sudo bash corex.sh nuke --dry-run
#     sudo bash corex.sh nuke --all
#
################################################################################

set -uo pipefail

# ── Version ──
COREX_VERSION="1.1.0"

# ── Colors ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Root check ──
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Run as root: sudo bash corex.sh${NC}"
    exit 1
fi

# ── Determine repo location ──
# Could be /opt/corex-pro (from curl install) or wherever the user cloned
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR=""

if [[ -f "${SCRIPT_DIR}/install-corex-master.sh" ]]; then
    REPO_DIR="$SCRIPT_DIR"
elif [[ -f "/opt/corex-pro/install-corex-master.sh" ]]; then
    REPO_DIR="/opt/corex-pro"
fi

# ── Download repo if not present ──
download_repo() {
    echo -e "${CYAN}Downloading CoreX Pro...${NC}"

    if ! command -v git &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq git
    fi

    REPO_DIR="/opt/corex-pro"
    if [[ -d "$REPO_DIR/.git" ]]; then
        echo -e "${CYAN}Updating existing repo...${NC}"
        cd "$REPO_DIR" && git pull --ff-only
    else
        rm -rf "$REPO_DIR"
        git clone https://github.com/itismowgli/corex-pro.git "$REPO_DIR"
    fi

    echo -e "${GREEN}Downloaded to: ${REPO_DIR}${NC}"
    echo ""
}

# ── Ensure repo exists ──
ensure_repo() {
    if [[ -z "$REPO_DIR" ]]; then
        download_repo
    fi
}

# ── Banner ──
show_banner() {
    echo ""
    echo -e "${CYAN}${BOLD}"
    echo "   ██████╗ ██████╗ ██████╗ ███████╗██╗  ██╗"
    echo "  ██╔════╝██╔═══██╗██╔══██╗██╔════╝╚██╗██╔╝"
    echo "  ██║     ██║   ██║██████╔╝█████╗   ╚███╔╝ "
    echo "  ██║     ██║   ██║██╔══██╗██╔══╝   ██╔██╗ "
    echo "  ╚██████╗╚██████╔╝██║  ██║███████╗██╔╝ ██╗"
    echo "   ╚═════╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝"
    echo -e "${NC}"
    echo -e "  ${BOLD}CoreX Pro v1.1${NC} — Sovereign Hybrid Homelab"
    echo ""
}

# ── RAM check ──
check_ram() {
    local TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
    if [[ $TOTAL_RAM -lt 4000 ]]; then
        echo -e "${YELLOW}Warning: ${TOTAL_RAM}MB RAM detected. 8GB+ recommended.${NC}"
        read -p "Continue anyway? (y/N): " ram_confirm
        [[ "$ram_confirm" != "y" && "$ram_confirm" != "Y" ]] && exit 0
    fi
}

# ── Install ──
do_install() {
    ensure_repo

    echo -e "${GREEN}${BOLD}── Install CoreX Pro ──${NC}"
    echo ""

    check_ram

    echo -e "${YELLOW}${BOLD}You MUST edit the configuration before installing:${NC}"
    echo ""
    echo "  SERVER_IP, DOMAIN, EMAIL, TIMEZONE, CLOUDFLARE_TUNNEL_TOKEN"
    echo ""

    EDITOR_CMD="${EDITOR:-nano}"
    command -v "$EDITOR_CMD" &>/dev/null || EDITOR_CMD="vi"

    read -p "$(echo -e "${CYAN}Open config in ${EDITOR_CMD}? (Y/n): ${NC}")" edit_choice
    if [[ "$edit_choice" != "n" && "$edit_choice" != "N" ]]; then
        "$EDITOR_CMD" "${REPO_DIR}/install-corex-master.sh"
    fi

    echo ""
    read -p "$(echo -e "${GREEN}Start installation? (y/N): ${NC}")" confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        chmod +x "${REPO_DIR}/install-corex-master.sh"
        bash "${REPO_DIR}/install-corex-master.sh"
    else
        echo ""
        echo "When you're ready:"
        echo "  sudo bash ${REPO_DIR}/install-corex-master.sh"
    fi
}

# ── Nuke ──
do_nuke() {
    ensure_repo
    shift_args=("${@}")

    echo -e "${RED}${BOLD}── Nuke / Rollback ──${NC}"
    echo ""

    chmod +x "${REPO_DIR}/nuke-corex.sh"
    bash "${REPO_DIR}/nuke-corex.sh" "${shift_args[@]}"
}

# ── Migrate ──
do_migrate() {
    ensure_repo
    shift_args=("${@}")

    echo -e "${CYAN}${BOLD}── Domain Migration ──${NC}"
    echo ""

    chmod +x "${REPO_DIR}/migrate-domain.sh"
    bash "${REPO_DIR}/migrate-domain.sh" "${shift_args[@]}"
}

# ── Help ──
show_help() {
    echo "Usage: sudo bash corex.sh [command] [options]"
    echo ""
    echo "Commands:"
    echo "  install          Install CoreX Pro (interactive config + deploy)"
    echo "  nuke             Uninstall / rollback (interactive per-phase)"
    echo "  migrate          Change domain across all services"
    echo "  update           Pull latest version from GitHub"
    echo "  version          Show current version"
    echo "  help             Show this help"
    echo ""
    echo "Nuke options:"
    echo "  nuke --all       Nuke everything (still confirms)"
    echo "  nuke --dry-run   Preview what would be removed"
    echo ""
    echo "Migrate options:"
    echo "  migrate old.com new.com            Direct migration"
    echo "  migrate --dry-run old.com new.com  Preview changes"
    echo ""
    echo "Quick install (no clone needed):"
    echo "  curl -fsSL https://raw.githubusercontent.com/itismowgli/corex-pro/main/corex.sh | sudo bash"
    echo ""
}

# ── Version ──
show_version() {
    echo "CoreX Pro v${COREX_VERSION}"
    echo "https://github.com/itismowgli/corex-pro"
}

# ── Update ──
do_update() {
    ensure_repo
    echo -e "${CYAN}Checking for updates...${NC}"
    cd "$REPO_DIR"

    LOCAL_VERSION="$COREX_VERSION"

    if git pull --ff-only 2>/dev/null; then
        # Re-read version from updated file
        NEW_VERSION=$(grep -oP 'COREX_VERSION="\K[^"]+' "${REPO_DIR}/corex.sh" 2>/dev/null || echo "$LOCAL_VERSION")
        if [[ "$NEW_VERSION" != "$LOCAL_VERSION" ]]; then
            echo -e "${GREEN}Updated: v${LOCAL_VERSION} → v${NEW_VERSION}${NC}"
            echo ""
            echo "View changes: cat ${REPO_DIR}/CHANGELOG.md"
        else
            echo -e "${GREEN}Already up to date (v${COREX_VERSION}).${NC}"
        fi
    else
        log_warning "Could not update. Check your internet connection or git status."
    fi
}

# ── Interactive menu ──
show_menu() {
    show_banner

    # Detect current state
    INSTALLED=false
    if command -v docker &>/dev/null && docker ps --format '{{.Names}}' 2>/dev/null | grep -q "traefik"; then
        INSTALLED=true
        echo -e "  Status: ${GREEN}CoreX is running${NC}"
        CONTAINER_COUNT=$(docker ps --format '{{.Names}}' 2>/dev/null | wc -l)
        echo -e "  Containers: ${CONTAINER_COUNT}"
    else
        echo -e "  Status: ${YELLOW}Not installed${NC}"
    fi
    echo ""

    echo -e "  ${BOLD}What would you like to do?${NC}"
    echo ""
    echo -e "  ${GREEN}1)${NC} Install CoreX Pro"
    echo -e "  ${RED}2)${NC} Nuke / Rollback"
    echo -e "  ${CYAN}3)${NC} Change Domain"
    echo -e "  ${YELLOW}4)${NC} Update CoreX Pro"
    echo -e "  ${NC}5)${NC} Help"
    echo -e "  ${NC}6)${NC} Exit"
    echo ""

    read -p "  Choose [1-6]: " choice

    case "$choice" in
        1) do_install ;;
        2) do_nuke ;;
        3) do_migrate ;;
        4) do_update ;;
        5) show_help ;;
        6) echo "Bye!"; exit 0 ;;
        *) echo "Invalid choice."; exit 1 ;;
    esac
}

################################################################################
# MAIN — Route based on argument
################################################################################

COMMAND="${1:-}"

case "$COMMAND" in
    install)
        show_banner
        do_install
        ;;
    nuke)
        show_banner
        shift
        do_nuke "$@"
        ;;
    migrate)
        show_banner
        shift
        do_migrate "$@"
        ;;
    update)
        show_banner
        do_update
        ;;
    version|--version|-v)
        show_version
        ;;
    help|--help|-h)
        show_banner
        show_help
        ;;
    "")
        if [[ ! -t 0 ]]; then
            show_banner
            do_install
        else
            show_menu
        fi
        ;;
    *)
        echo -e "${RED}Unknown command: ${COMMAND}${NC}"
        echo ""
        show_help
        exit 1
        ;;
esac