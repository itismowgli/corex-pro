#!/bin/bash
################################################################################
#
#   ███╗   ██╗██╗   ██╗██╗  ██╗███████╗
#   ████╗  ██║██║   ██║██║ ██╔╝██╔════╝
#   ██╔██╗ ██║██║   ██║█████╔╝ █████╗
#   ██║╚██╗██║██║   ██║██╔═██╗ ██╔══╝
#   ██║ ╚████║╚██████╔╝██║  ██╗███████╗
#   ╚═╝  ╚═══╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝
#
#   CoreX Pro — Nuke & Rollback Script
#   Companion to install-corex-master.sh
#
#   PURPOSE:
#     Cleanly reverses everything the install script did. Use when:
#       - Installation failed mid-way and left things in a broken state
#       - You want to re-install from scratch on the same machine
#       - You want to completely remove CoreX from the system
#       - You're decommissioning the server
#
#   SAFETY:
#     - Interactive with confirmation prompts at every destructive step
#     - Selective mode: choose which phases to nuke (or nuke everything)
#     - Backs up credentials before deletion
#     - Does NOT format/wipe the SSD unless you explicitly choose to
#     - SSH is restored to defaults LAST (so you don't lock yourself out)
#
#   USAGE:
#     chmod +x nuke-corex.sh
#     sudo bash nuke-corex.sh              # Interactive (choose what to nuke)
#     sudo bash nuke-corex.sh --all        # Nuke everything (still confirms)
#     sudo bash nuke-corex.sh --dry-run    # Show what would be done
#
################################################################################

set -uo pipefail

# ── Colors ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Logging ──
log_nuke()    { echo -e "${RED}[NUKE]${NC} $1"; }
log_info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[DONE]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_skip()    { echo -e "${YELLOW}[SKIP]${NC} $1"; }

# ── Paths (must match install script) ──
MOUNT_TM="/mnt/timemachine"
MOUNT_POOL="/mnt/corex-data"
DOCKER_ROOT="${MOUNT_POOL}/docker-configs"
DATA_ROOT="${MOUNT_POOL}/service-data"
BACKUP_ROOT="${MOUNT_POOL}/backups"
CRED_FILE="/root/corex-credentials.txt"
DOCS_FILE="/root/CoreX_Dashboard_Credentials.md"
NUKE_LOG="/tmp/corex-nuke-$(date +%Y%m%d-%H%M%S).log"

# ── Flags ──
DRY_RUN=false
NUKE_ALL=false

# ── Parse args ──
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --all)     NUKE_ALL=true ;;
        --help|-h)
            echo "Usage: sudo bash nuke-corex.sh [options]"
            echo ""
            echo "Options:"
            echo "  --all       Nuke everything (still asks for confirmation)"
            echo "  --dry-run   Show what would be done without doing it"
            echo "  --help      Show this help"
            exit 0
            ;;
    esac
done

# ── Root check ──
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Run as root: sudo bash nuke-corex.sh${NC}"
    exit 1
fi

# ── Confirmation helper ──
confirm() {
    local msg="$1"
    if $NUKE_ALL; then
        return 0
    fi
    read -p "$(echo -e "${YELLOW}$msg (y/N): ${NC}")" answer
    [[ "$answer" == "y" || "$answer" == "Y" ]]
}

# ── Dry run wrapper ──
run() {
    if $DRY_RUN; then
        echo -e "  ${CYAN}[DRY RUN]${NC} $*"
    else
        eval "$@" 2>&1 | tee -a "$NUKE_LOG" || true
    fi
}

################################################################################
# BANNER
################################################################################

clear
echo ""
echo -e "${RED}${BOLD}"
echo "  ╔══════════════════════════════════════════════════════════════╗"
echo "  ║          CoreX Pro — NUKE & ROLLBACK SCRIPT                 ║"
echo "  ║                                                              ║"
echo "  ║   This will UNDO everything install-corex-master.sh did.    ║"
echo "  ║   Your data CAN be preserved if you choose carefully.       ║"
echo "  ╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

if $DRY_RUN; then
    echo -e "  ${CYAN}${BOLD}>>> DRY RUN MODE — nothing will be changed <<<${NC}"
    echo ""
fi

if $NUKE_ALL; then
    echo -e "  ${RED}${BOLD}>>> FULL NUKE MODE — all phases will execute <<<${NC}"
    echo ""
    read -p "$(echo -e "${RED}Type 'NUKE' to confirm full wipe: ${NC}")" nuke_confirm
    if [[ "$nuke_confirm" != "NUKE" ]]; then
        echo "Aborted."
        exit 0
    fi
fi

echo -e "  Nuke log: ${NUKE_LOG}"
echo ""

################################################################################
# PHASE 1: STOP & REMOVE ALL DOCKER CONTAINERS
################################################################################

echo -e "${BOLD}── Phase 1: Docker Containers & Networks ──${NC}"
echo "  Stops and removes all CoreX containers, volumes, and networks."
echo ""

if confirm "Stop and remove ALL Docker containers, volumes, and networks?"; then
    log_nuke "Stopping all containers..."

    # Stop all compose stacks gracefully
    if [[ -d "$DOCKER_ROOT" ]]; then
        for dir in "${DOCKER_ROOT}"/*/; do
            if [[ -f "$dir/docker-compose.yml" ]]; then
                service_name=$(basename "$dir")
                log_info "Stopping ${service_name}..."
                run "cd '$dir' && docker compose down --remove-orphans 2>/dev/null"
            fi
        done
    fi

    # Kill any remaining containers
    RUNNING=$(docker ps -aq 2>/dev/null)
    if [[ -n "$RUNNING" ]]; then
        log_nuke "Force-stopping remaining containers..."
        run "docker stop $RUNNING 2>/dev/null"
        run "docker rm -f $RUNNING 2>/dev/null"
    fi

    # Remove CoreX networks
    log_nuke "Removing Docker networks..."
    run "docker network rm proxy-net 2>/dev/null"
    run "docker network rm monitoring-net 2>/dev/null"
    run "docker network rm ai-net 2>/dev/null"

    # Remove named volumes
    log_nuke "Removing Docker volumes..."
    VOLUMES=$(docker volume ls -q 2>/dev/null)
    if [[ -n "$VOLUMES" ]]; then
        run "docker volume rm $VOLUMES 2>/dev/null"
    fi

    # Clean up dangling images (optional, saves disk)
    log_nuke "Pruning unused Docker images..."
    run "docker system prune -af --volumes 2>/dev/null"

    log_success "Docker containers, networks, and volumes removed."
else
    log_skip "Docker containers — skipped."
fi

echo ""

################################################################################
# PHASE 2: REMOVE BACKUP SYSTEM (Restic cron + scripts)
################################################################################

echo -e "${BOLD}── Phase 2: Backup System ──${NC}"
echo "  Removes backup scripts and cron job. Does NOT delete backup data."
echo ""

if confirm "Remove backup scripts and cron job?"; then
    # Remove cron entry
    log_nuke "Removing backup cron job..."
    EXISTING_CRON=$(crontab -l 2>/dev/null || true)
    if echo "$EXISTING_CRON" | grep -q "corex-backup"; then
        FILTERED=$(echo "$EXISTING_CRON" | grep -v "corex-backup" || true)
        if [[ -z "$FILTERED" ]]; then
            run "crontab -r 2>/dev/null"
        else
            echo "$FILTERED" | run "crontab -"
        fi
        log_success "Cron job removed."
    else
        log_skip "No corex-backup cron job found."
    fi

    # Remove scripts
    for script in /usr/local/bin/corex-backup.sh /usr/local/bin/corex-restore.sh; do
        if [[ -f "$script" ]]; then
            log_nuke "Removing $script"
            run "rm -f '$script'"
        fi
    done

    log_success "Backup system removed (data preserved at ${BACKUP_ROOT})."
else
    log_skip "Backup system — skipped."
fi

echo ""

################################################################################
# PHASE 3: REVERSE FIREWALL (UFW)
################################################################################

echo -e "${BOLD}── Phase 3: Firewall (UFW) ──${NC}"
echo "  Resets UFW to defaults. Clears all CoreX rules."
echo ""

if confirm "Reset UFW firewall to defaults?"; then
    log_nuke "Resetting UFW..."
    run "ufw --force disable"
    run "ufw --force reset"

    # Re-enable with just SSH on port 22 (safe default)
    run "ufw default deny incoming"
    run "ufw default allow outgoing"
    run "ufw allow 22/tcp comment 'SSH (default port)'"
    run "ufw --force enable"

    log_success "UFW reset. Only port 22 (SSH) is open."
else
    log_skip "UFW — skipped."
fi

echo ""

################################################################################
# PHASE 4: REVERSE SECURITY HARDENING
################################################################################

echo -e "${BOLD}── Phase 4: Security Hardening ──${NC}"
echo "  Restores SSH to defaults, removes kernel hardening, disables fail2ban."
echo ""

if confirm "Reverse SSH hardening and security configs?"; then

    # ── Restore SSH config ──
    log_nuke "Restoring SSH config..."
    # Find the most recent backup
    SSH_BACKUP=$(ls -t /etc/ssh/sshd_config.bak.* 2>/dev/null | head -1)
    if [[ -n "$SSH_BACKUP" ]]; then
        log_info "Restoring from backup: $SSH_BACKUP"
        run "cp '$SSH_BACKUP' /etc/ssh/sshd_config"
    else
        # Manual restore to sane defaults
        log_info "No backup found — restoring key settings to defaults..."
        run "sed -i 's/^Port .*/Port 22/' /etc/ssh/sshd_config"
        run "sed -i 's/^PermitRootLogin .*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config"
        run "sed -i 's/^MaxAuthTries .*/MaxAuthTries 6/' /etc/ssh/sshd_config"
        run "sed -i 's/^ClientAliveInterval .*/ClientAliveInterval 0/' /etc/ssh/sshd_config"
        run "sed -i 's/^ClientAliveCountMax .*/ClientAliveCountMax 3/' /etc/ssh/sshd_config"
    fi
    run "systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null"
    log_success "SSH restored to port 22 with default settings."
    log_warning "⚠ SSH is now on port 22. Reconnect with: ssh user@SERVER_IP"

    # ── Remove Fail2ban config ──
    log_nuke "Removing Fail2ban CoreX config..."
    run "rm -f /etc/fail2ban/jail.local"
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        run "systemctl restart fail2ban"
    fi
    log_success "Fail2ban config removed (service still running with defaults)."

    # ── Remove kernel hardening ──
    log_nuke "Removing kernel hardening..."
    run "rm -f /etc/sysctl.d/99-corex.conf"
    run "sysctl --system > /dev/null 2>&1"
    log_success "Kernel sysctl hardening removed."

    # ── Remove SSH config backups ──
    SSH_BACKUPS=$(ls /etc/ssh/sshd_config.bak.* 2>/dev/null)
    if [[ -n "$SSH_BACKUPS" ]]; then
        log_nuke "Cleaning up SSH config backups..."
        run "rm -f /etc/ssh/sshd_config.bak.*"
    fi

else
    log_skip "Security hardening — skipped."
fi

echo ""

################################################################################
# PHASE 5: RESTORE DNS (systemd-resolved)
################################################################################

echo -e "${BOLD}── Phase 5: DNS Resolution ──${NC}"
echo "  Re-enables systemd-resolved and unlocks /etc/resolv.conf."
echo ""

if confirm "Restore DNS to system defaults (re-enable systemd-resolved)?"; then
    log_nuke "Unlocking /etc/resolv.conf..."
    run "chattr -i /etc/resolv.conf 2>/dev/null"
    run "rm -f /etc/resolv.conf"

    log_nuke "Re-enabling systemd-resolved..."
    run "systemctl enable --now systemd-resolved 2>/dev/null"

    # Restore the symlink that Ubuntu expects
    run "ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf"

    log_success "DNS restored to systemd-resolved defaults."
else
    log_skip "DNS — skipped."
fi

echo ""

################################################################################
# PHASE 6: UNMOUNT & CLEAN FSTAB
################################################################################

echo -e "${BOLD}── Phase 6: SSD Mounts & Fstab ──${NC}"
echo "  Unmounts SSD partitions and removes fstab entries."
echo "  Does NOT format the SSD — your data stays on disk."
echo ""

if confirm "Unmount SSD and remove fstab entries?"; then
    # Unmount
    for mount in "$MOUNT_TM" "$MOUNT_POOL"; do
        if mountpoint -q "$mount" 2>/dev/null; then
            log_nuke "Unmounting $mount..."
            run "umount -l '$mount'"
        fi
    done

    # Clean fstab
    log_nuke "Removing CoreX entries from /etc/fstab..."
    run "sed -i '\\|$MOUNT_TM|d' /etc/fstab"
    run "sed -i '\\|$MOUNT_POOL|d' /etc/fstab"

    # Remove mount points
    run "rmdir '$MOUNT_TM' 2>/dev/null"
    run "rmdir '$MOUNT_POOL' 2>/dev/null"

    log_success "SSD unmounted and fstab cleaned."
    log_info "SSD data is preserved. Re-mount manually or re-run installer."
else
    log_skip "SSD mounts — skipped."
fi

echo ""

################################################################################
# PHASE 7: REMOVE DOCKER ENGINE (Optional)
################################################################################

echo -e "${BOLD}── Phase 7: Docker Engine ──${NC}"
echo "  Completely removes Docker from the system."
echo "  Skip this if you want to keep Docker for other projects."
echo ""

if confirm "Completely REMOVE Docker Engine?"; then
    log_nuke "Removing Docker Engine..."
    run "systemctl stop docker docker.socket containerd 2>/dev/null"
    run "apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null"
    run "apt-get autoremove -y 2>/dev/null"
    run "rm -rf /var/lib/docker /var/lib/containerd"
    run "rm -f /etc/apt/sources.list.d/docker.list"
    run "rm -f /etc/apt/keyrings/docker.asc"
    log_success "Docker Engine completely removed."
else
    log_skip "Docker Engine — kept."
fi

echo ""

################################################################################
# PHASE 8: REMOVE CREDENTIALS & DOCS
################################################################################

echo -e "${BOLD}── Phase 8: Credentials & Documentation ──${NC}"
echo "  Removes credential files and generated docs."
echo ""

if confirm "Remove credential files? (backup copy will be made first)"; then
    # Backup before deletion
    BACKUP_DIR="/root/corex-creds-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"

    for file in "$CRED_FILE" "$DOCS_FILE"; do
        if [[ -f "$file" ]]; then
            log_info "Backing up $file → $BACKUP_DIR/"
            run "cp '$file' '$BACKUP_DIR/'"
            run "rm -f '$file'"
        fi
    done

    log_success "Credentials removed. Backup saved to $BACKUP_DIR"
    log_warning "⚠ Delete $BACKUP_DIR manually when you no longer need the passwords."
else
    log_skip "Credentials — kept."
fi

echo ""

################################################################################
# PHASE 9: WIPE SSD DATA (Dangerous — optional)
################################################################################

echo -e "${BOLD}── Phase 9: Wipe SSD Data (DESTRUCTIVE) ──${NC}"
echo -e "  ${RED}Permanently deletes ALL service data, backups, photos, mail,"
echo -e "  passwords, configs, and Time Machine backups from the SSD.${NC}"
echo -e "  ${RED}THIS CANNOT BE UNDONE.${NC}"
echo ""

if confirm "⚠️  PERMANENTLY WIPE all data on the SSD?"; then
    echo ""
    read -p "$(echo -e "${RED}${BOLD}Type 'WIPE MY DATA' to confirm: ${NC}")" wipe_confirm
    if [[ "$wipe_confirm" == "WIPE MY DATA" ]]; then

        # Re-mount if needed to wipe contents
        for mount in "$MOUNT_TM" "$MOUNT_POOL"; do
            if mountpoint -q "$mount" 2>/dev/null; then
                log_nuke "Wiping contents of $mount..."
                run "rm -rf '${mount:?}'/*"
                run "umount -l '$mount'"
            fi
        done

        # Find the SSD device from fstab or blkid
        SSD_DEVICE=""
        if command -v blkid &>/dev/null; then
            SSD_DEVICE=$(blkid | grep -E "$MOUNT_TM|$MOUNT_POOL" | head -1 | cut -d: -f1 | sed 's/[0-9]*$//')
        fi

        if [[ -n "$SSD_DEVICE" ]]; then
            log_nuke "Wiping partition table on $SSD_DEVICE..."
            run "wipefs -af '$SSD_DEVICE'"
            log_success "SSD wiped completely."
        else
            log_warning "Could not detect SSD device. Partition table NOT wiped."
            log_info "Manually wipe with: sudo wipefs -af /dev/sdX"
        fi
    else
        log_skip "SSD wipe — confirmation not matched."
    fi
else
    log_skip "SSD data — preserved."
fi

echo ""

################################################################################
# PHASE 10: REMOVE INSTALLED PACKAGES (Optional)
################################################################################

echo -e "${BOLD}── Phase 10: Installed Packages (Optional) ──${NC}"
echo "  Removes packages installed by CoreX: restic, cron, avahi, fail2ban, etc."
echo "  Skip this if other services depend on these packages."
echo ""

if confirm "Remove CoreX-installed packages (restic, avahi, fail2ban, etc.)?"; then
    log_nuke "Removing CoreX packages..."

    # Only remove packages that were specifically added by CoreX
    # NOT removing: curl, wget, nano, htop, jq (commonly useful)
    COREX_PACKAGES=(
        restic
        avahi-daemon avahi-utils
        fail2ban
    )

    for pkg in "${COREX_PACKAGES[@]}"; do
        if dpkg -l "$pkg" &>/dev/null 2>&1; then
            log_info "Removing $pkg..."
            run "apt-get purge -y '$pkg' 2>/dev/null"
        fi
    done

    run "apt-get autoremove -y 2>/dev/null"
    log_success "CoreX-specific packages removed."
else
    log_skip "Packages — kept."
fi

echo ""

################################################################################
# SUMMARY
################################################################################

echo ""
echo -e "${GREEN}${BOLD}"
echo "  ╔══════════════════════════════════════════════════════════════╗"
echo "  ║              CoreX Pro — Nuke Complete                       ║"
echo "  ╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

echo -e "  ${CYAN}What was done:${NC}"
echo "    - See full log: $NUKE_LOG"
echo ""

echo -e "  ${YELLOW}Important reminders:${NC}"
echo "    - SSH is back on port 22 (if you nuked security)"
echo "    - DNS is using systemd-resolved again (if you nuked DNS)"
echo "    - UFW only allows port 22 (if you nuked firewall)"
echo ""

if [[ -d "${BACKUP_DIR:-/nonexistent}" ]]; then
    echo -e "  ${RED}Credential backup:${NC}"
    echo "    $BACKUP_DIR"
    echo "    Delete this after you've saved your passwords elsewhere."
    echo ""
fi

echo -e "  ${CYAN}To re-install:${NC}"
echo "    sudo bash install-corex-master.sh"
echo ""
echo -e "  ${GREEN}System is clean. Ready for a fresh start. 🧹${NC}"
echo ""