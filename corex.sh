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
COREX_VERSION="3.1.1"

# ── Colors ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Logging ──
log_info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[  OK]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[FAIL]${NC} $1" >&2; exit 1; }

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
        cd "$REPO_DIR" && git fetch origin && git pull --ff-only origin main
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
    local shift_args=("${@}")

    echo -e "${RED}${BOLD}── Nuke / Rollback ──${NC}"
    echo ""

    chmod +x "${REPO_DIR}/nuke-corex.sh"
    bash "${REPO_DIR}/nuke-corex.sh" "${shift_args[@]}"
}

# ── Migrate ──
do_migrate() {
    ensure_repo
    local shift_args=("${@}")

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
    echo "  manage storage             Show disk usage breakdown (OS, SSD, per-service)"
    echo "  manage cleanup [--dry-run] Remove stale Docker images and build cache"
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

    # Ignore file-mode-only changes (scripts pulled by root often get +x set
    # on the filesystem but the repo tracks them as 644 — not a real diff)
    git config core.fileMode false 2>/dev/null || true

    LOCAL_VERSION="$COREX_VERSION"

    # Check for uncommitted local changes before touching anything
    if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
        log_warning "Local changes detected in ${REPO_DIR}."
        log_warning "Update would overwrite them. Use --force to proceed anyway."
        local force_flag="${1:-}"
        if [[ "$force_flag" != "--force" ]]; then
            echo "Aborted. Run: corex update --force"
            return 1
        fi
    fi

    # Fetch remote without applying changes
    if ! git fetch origin 2>/dev/null; then
        log_warning "Could not reach GitHub. Check your internet connection."
        return 1
    fi

    REMOTE_VERSION=$(git show origin/main:corex.sh 2>/dev/null \
        | grep -oP 'COREX_VERSION="\K[^"]+' | head -1 || echo "$LOCAL_VERSION")

    # Commits behind is the authoritative signal, NOT the version string.
    # Comparing versions alone silently hides every fix pushed without a
    # version bump — the common case for hotfixes — and leaves users running
    # stale code while being told they are up to date.
    local behind
    behind=$(git rev-list --count HEAD..origin/main 2>/dev/null || echo 0)

    if [[ "$behind" == "0" ]]; then
        echo -e "${GREEN}Already up to date (v${COREX_VERSION}, $(git rev-parse --short HEAD)).${NC}"
        return 0
    fi

    # Describe the update honestly: a version bump when there is one, otherwise
    # say plainly that these are unreleased commits on the current version.
    local update_desc
    if [[ "$REMOTE_VERSION" != "$LOCAL_VERSION" ]]; then
        update_desc="v${LOCAL_VERSION} → v${REMOTE_VERSION}"
        echo ""
        echo -e "  Pending update: ${YELLOW}v${LOCAL_VERSION}${NC} → ${GREEN}v${REMOTE_VERSION}${NC} (${behind} commit(s))"
    else
        update_desc="${behind} new commit(s) on v${LOCAL_VERSION}"
        echo ""
        echo -e "  ${GREEN}${behind} new commit(s)${NC} on v${LOCAL_VERSION} ${YELLOW}(unreleased)${NC}"
    fi
    echo ""

    # Always show what is actually arriving. Commit subjects are available even
    # when the CHANGELOG has no section for this version yet.
    echo -e "${BOLD}Incoming commits:${NC}"
    git log --oneline --no-decorate HEAD..origin/main 2>/dev/null | head -10 | sed 's/^/    /'
    echo ""

    # Show abbreviated changelog if available. The heading may or may not carry
    # a leading "v" (CHANGELOG uses "## [v3.0.0]" while COREX_VERSION is
    # "3.0.0"), so accept both rather than silently matching nothing.
    local changelog
    changelog=$(git show origin/main:CHANGELOG.md 2>/dev/null \
        | grep -A5 -E "^## \[v?${REMOTE_VERSION}\]" | head -8 || true)
    if [[ -n "$changelog" ]]; then
        echo -e "${BOLD}Changelog:${NC}"
        echo "$changelog"
        echo ""
    fi

    local confirm
    read -r -p "Update CoreX Pro (${update_desc})? [y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { echo "Aborted."; return 0; }

    # Apply update (fast-forward only — won't destroy diverged history)
    if git pull --ff-only origin main 2>/dev/null; then
        # Validate the downloaded scripts before celebrating
        if bash -n "${REPO_DIR}/install-corex-master.sh" 2>/dev/null \
            && bash -n "${REPO_DIR}/corex.sh" 2>/dev/null; then
            echo -e "${GREEN}Updated to v${REMOTE_VERSION} ($(git rev-parse --short HEAD)). Scripts validated OK.${NC}"
            echo ""
            # Re-exec with the freshly downloaded script so the new version loads
            exec bash "${REPO_DIR}/corex.sh" "$@"
        else
            log_warning "Script syntax validation failed after update. Check manually."
        fi
    else
        log_warning "git pull --ff-only failed. Your branch may have diverged."
        log_warning "To force update: cd ${REPO_DIR} && git reset --hard origin/main"
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
        echo -e "  ${YELLOW}4)${NC} Update CoreX Pro"
        echo -e "  ${CYAN}5)${NC} Network tune (optimize for Gbps file transfers)"
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
            4) do_update ;;
            5) do_manage network-tune ;;
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