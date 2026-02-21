#!/bin/bash
# lib/backup.sh — CoreX Pro v2
# Phase 6: Restic encrypted backup system setup.
# Creates backup/restore scripts and schedules daily cron at 3AM.
# NEVER change RESTIC_PASSWORD after init — it locks you out of the repo.

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

phase6_backup() {
    log_step "═══ PHASE 6: Backup System (Restic) ═══"

    # Ensure cron is installed
    if ! command -v crontab &>/dev/null; then
        log_info "Installing cron..."
        apt-get install -y -qq cron
        systemctl enable --now cron
    fi

    # Ensure restic is installed
    if ! command -v restic &>/dev/null; then
        log_info "Installing restic..."
        apt-get install -y -qq restic || log_error "Failed to install restic."
    fi

    mkdir -p "${BACKUP_ROOT}"

    export RESTIC_REPOSITORY="${BACKUP_ROOT}/restic-repo"
    export RESTIC_PASSWORD="${RESTIC_PASSWORD}"

    if ! restic cat config &>/dev/null 2>&1; then
        log_info "Initializing Restic backup repository..."
        restic init || log_error "Failed to initialize Restic repository."
        log_success "Restic repo created at ${BACKUP_ROOT}/restic-repo"
    else
        log_success "Restic repo already exists — skipping init."
    fi

    # ── Backup script ────────────────────────────────────────────────────────
    cat > /usr/local/bin/corex-backup.sh << BKEOF
#!/bin/bash
# CoreX Pro — Daily Backup Script
# Runs automatically at 3AM via cron. Can also be run manually.
export RESTIC_REPOSITORY="${BACKUP_ROOT}/restic-repo"
export RESTIC_PASSWORD="${RESTIC_PASSWORD}"
LOG="/var/log/corex-backup.log"

echo "\$(date '+%Y-%m-%d %H:%M:%S') — Backup starting..." >> "\$LOG"

restic backup "${DATA_ROOT}" "${DOCKER_ROOT}" \
    --tag corex \
    --exclude="*.tmp" \
    --exclude="*.log" \
    --exclude="*/cache/*" \
    >> "\$LOG" 2>&1

restic forget \
    --keep-daily 7 \
    --keep-weekly 4 \
    --keep-monthly 6 \
    --prune \
    >> "\$LOG" 2>&1

echo "\$(date '+%Y-%m-%d %H:%M:%S') — Backup complete." >> "\$LOG"
BKEOF
    chmod +x /usr/local/bin/corex-backup.sh

    # ── Restore script ───────────────────────────────────────────────────────
    cat > /usr/local/bin/corex-restore.sh << RSEOF
#!/bin/bash
# CoreX Pro — Restore Script
# Usage: sudo corex-restore.sh [snapshot-id]
export RESTIC_REPOSITORY="${BACKUP_ROOT}/restic-repo"
export RESTIC_PASSWORD="${RESTIC_PASSWORD}"

echo ""
echo "=== CoreX Restore ==="
echo ""
echo "Available snapshots:"
restic snapshots
echo ""

SNAP="\${1:-latest}"
echo "Selected: \$SNAP"
read -r -p "Restore? This OVERWRITES current data. (y/N): " CONFIRM
if [[ "\$CONFIRM" != "y" && "\$CONFIRM" != "Y" ]]; then
    echo "Aborted."
    exit 0
fi

echo "Stopping all Docker containers..."
docker stop \$(docker ps -aq) 2>/dev/null || true

echo "Restoring files..."
restic restore "\$SNAP" --target /

echo "Restarting all services..."
for dir in ${DOCKER_ROOT}/*/; do
    if [[ -f "\$dir/docker-compose.yml" ]]; then
        echo "  Starting \$(basename "\$dir")..."
        (cd "\$dir" && docker compose up -d 2>/dev/null) || true
    fi
done

echo ""
echo "Restore complete! Verify with: docker ps"
RSEOF
    chmod +x /usr/local/bin/corex-restore.sh

    # ── Schedule daily cron at 3AM ───────────────────────────────────────────
    local EXISTING_CRON
    EXISTING_CRON=$(crontab -l 2>/dev/null || true)
    local FILTERED_CRON
    FILTERED_CRON=$(echo "$EXISTING_CRON" | grep -v "corex-backup" || true)
    printf "%s\n0 3 * * * /usr/local/bin/corex-backup.sh\n" "$FILTERED_CRON" | crontab -

    log_success "Backup system ready (daily at 3AM, manual: sudo corex-backup.sh)"
}
