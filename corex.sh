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
COREX_VERSION="2.4.0"

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
# When piped via curl, BASH_SOURCE is empty — fall back to /opt/corex-pro
SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]:-}" != "bash" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
fi
REPO_DIR=""

if [[ -n "$SCRIPT_DIR" && -f "${SCRIPT_DIR}/install-corex-master.sh" ]]; then
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
        cd "$REPO_DIR" && git fetch origin && git reset --hard origin/main
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
    echo -e "  ${BOLD}CoreX Pro v${COREX_VERSION}${NC} — Sovereign Hybrid Homelab"
    echo ""
}

# ── RAM check ──
check_ram() {
    local TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
    if [[ $TOTAL_RAM -lt 4000 ]]; then
        echo -e "${YELLOW}Warning: ${TOTAL_RAM}MB RAM detected. 8GB+ recommended.${NC}"
        if [[ -t 0 ]]; then
            read -p "Continue anyway? (y/N): " ram_confirm
            [[ "$ram_confirm" != "y" && "$ram_confirm" != "Y" ]] && exit 0
        fi
    fi
}

# ── Install ──
do_install() {
    ensure_repo

    echo -e "${GREEN}${BOLD}── Install CoreX Pro ──${NC}"
    echo ""

    check_ram

    # When piped via curl, stdin is not a terminal — wizard will use plain prompts
    if [[ ! -t 0 ]]; then
        echo -e "${GREEN}Downloaded to: ${REPO_DIR}${NC}"
        echo ""
        echo -e "${YELLOW}${BOLD}CoreX Pro v2 — Interactive Setup${NC}"
        echo ""
        echo "  Run the installer interactively:"
        echo "    sudo bash ${REPO_DIR}/corex.sh install"
        echo ""
        echo "  The wizard will guide you through:"
        echo "    • Mode selection (with-domain / local-only)"
        echo "    • Service selection (choose only what you need)"
        echo "    • Automatic secure password generation"
        echo ""
        return
    fi

    chmod +x "${REPO_DIR}/install-corex-master.sh"
    bash "${REPO_DIR}/install-corex-master.sh"
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
    echo "  install          Install CoreX Pro (wizard selects services)"
    echo "  doctor           Health check + auto-repair all installed services"
    echo "  manage <cmd>     Post-install service management (see below)"
    echo "  nuke             Uninstall / rollback (interactive per-phase)"
    echo "  migrate          Change domain across all services"
    echo "  update           Pull latest version from GitHub"
    echo "  version          Show current version"
    echo "  help             Show this help"
    echo ""
    echo "Manage sub-commands:"
    echo "  manage status              Show health of all services"
    echo "  manage list                List installed vs available services"
    echo "  manage add <service>       Install a skipped service"
    echo "  manage remove <service>    Remove a service (prompts about data)"
    echo "  manage update --all        Update all service images"
    echo "  manage update <service>    Update a specific service"
    echo "  manage lan-setup           Configure LAN fast-path (faster file transfers)"
    echo "  manage network-tune        Diagnose and optimize network for Gbps transfers"
    echo ""
    echo "Nuke options:"
    echo "  nuke --all       Nuke everything (still confirms)"
    echo "  nuke --dry-run   Preview what would be removed"
    echo ""
    echo "Quick install (fresh server, one command):"
    echo "  curl -fsSL https://raw.githubusercontent.com/itismowgli/corex-pro/main/corex.sh | sudo bash"
    echo ""
}

# ── Doctor ──
do_doctor() {
    ensure_repo
    echo -e "${CYAN}${BOLD}── CoreX Pro Doctor ──${NC}"
    echo ""
    chmod +x "${REPO_DIR}/corex-manage.sh"
    # corex-manage _load_config will auto-migrate v1→v2 if state.json is missing
    bash "${REPO_DIR}/corex-manage.sh" doctor
}

# ── Manage ──
do_manage() {
    ensure_repo
    chmod +x "${REPO_DIR}/corex-manage.sh"
    bash "${REPO_DIR}/corex-manage.sh" "$@"
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

    if git fetch origin 2>/dev/null && git reset --hard origin/main 2>/dev/null; then
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
    if [[ "$INSTALLED" == "true" ]]; then
        echo -e "  ${GREEN}1)${NC} Doctor (health check + auto-repair)"
        echo -e "  ${CYAN}2)${NC} Manage services (add/remove/update)"
        echo -e "  ${CYAN}3)${NC} LAN fast-path setup (faster local file transfers)"
        echo -e "  ${CYAN}4)${NC} Network tune (optimize for Gbps file transfers)"
        echo -e "  ${YELLOW}5)${NC} Update CoreX Pro"
        echo -e "  ${CYAN}6)${NC} Change Domain"
        echo -e "  ${RED}7)${NC} Nuke / Rollback"
        echo -e "  ${NC}8)${NC} Help"
        echo -e "  ${NC}9)${NC} Exit"
        echo ""
        read -r -p "  Choose [1-9]: " choice
        case "$choice" in
            1) do_doctor ;;
            2) ensure_repo; bash "${REPO_DIR}/corex-manage.sh" ;;
            3) do_manage lan-setup ;;
            4) do_manage network-tune ;;
            5) do_update ;;
            6) do_migrate ;;
            7) do_nuke ;;
            8) show_help ;;
            9) echo "Bye!"; exit 0 ;;
            *) echo "Invalid choice."; exit 1 ;;
        esac
    else
        echo -e "  ${GREEN}1)${NC} Install CoreX Pro"
        echo -e "  ${YELLOW}2)${NC} Update CoreX Pro"
        echo -e "  ${NC}3)${NC} Help"
        echo -e "  ${NC}4)${NC} Exit"
        echo ""
        read -r -p "  Choose [1-4]: " choice
        case "$choice" in
            1) do_install ;;
            2) do_update ;;
            3) show_help ;;
            4) echo "Bye!"; exit 0 ;;
            *) echo "Invalid choice."; exit 1 ;;
        esac
    fi
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
    doctor)
        show_banner
        do_doctor
        ;;
    manage)
        shift
        do_manage "$@"
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