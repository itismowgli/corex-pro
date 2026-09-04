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

    backup_install_restic
    backup_init_repo || return 1
    backup_write_scripts
    backup_schedule_cron
    log_success "Backup system ready (daily at 3AM, manual: sudo corex-backup.sh)"
}

backup_install_restic() {
    if ! command -v restic &>/dev/null; then
        log_info "Installing restic..."
        apt-get install -y -qq restic || log_error "Failed to install restic."
    fi
}

# The repository, created once. The password comes from cred_get, which is the
# only correct way to read it: /root/corex-credentials.txt is column aligned,
# so a label is followed by padding, and a plain `sed 's/^[^:]*: //'` takes one
# space off and leaves the rest inside the password. That produced a repository
# whose key was two spaces plus the password, which then refused every backup
# the generated script attempted, with "wrong password or no key found".
backup_init_repo() {
    mkdir -p "${BACKUP_ROOT}"
    local pw="${RESTIC_PASSWORD:-}"
    [[ -n "$pw" ]] || pw="$(cred_get 'Restic Backup:')"
    if [[ -z "$pw" ]]; then
        log_warning "No Restic password, so no repository was created"
        return 1
    fi
    export RESTIC_REPOSITORY="${BACKUP_ROOT}/restic-repo"
    export RESTIC_PASSWORD="$pw"

    if restic cat config >/dev/null 2>&1; then
        log_success "Restic repo already exists, leaving it alone."
        return 0
    fi
    # An existing directory that is not a repository is either an empty
    # mkdir or a repository keyed on a different password, and restic init
    # refuses a non-empty target. Saying which is what makes the difference
    # diagnosable.
    if [[ -f "${RESTIC_REPOSITORY}/config" ]]; then
        log_warning "There is a repository at ${RESTIC_REPOSITORY} that this password does not open."
        echo "    Either restore the original password, or move that directory aside"
        echo "    and re-run. Moving it aside abandons every snapshot in it."
        return 1
    fi
    log_info "Initializing Restic backup repository..."
    restic init || { log_warning "Failed to initialize Restic repository."; return 1; }
    log_success "Restic repo created at ${RESTIC_REPOSITORY}"
}

backup_write_scripts() {
    # ── Backup script ────────────────────────────────────────────────────────
    # Uses single-quoted heredoc ('BKEOF') to prevent variable expansion.
    # Passwords are read at runtime from credentials file (not embedded).
    # This prevents plaintext secrets appearing in world-readable scripts.
    install_script /usr/local/bin/corex-backup.sh 750 << 'BKEOF'
#!/bin/bash
# CoreX Pro — Daily Backup Script
# Runs automatically at 3AM via cron. Can also be run manually.
BACKUP_ROOT="/mnt/corex-data/backups"
DATA_ROOT="/mnt/corex-data/service-data"
DOCKER_ROOT="/mnt/corex-data/docker-configs"
CRED_FILE="/root/corex-credentials.txt"
LOG="/var/log/corex-backup.log"
export RESTIC_REPOSITORY="${BACKUP_ROOT}/restic-repo"
# Read at runtime, never embedded in this file, which is world readable.
#
# The trailing whitespace strip is load bearing. The credentials file is
# column aligned, so the label is followed by padding, and taking one space
# off after the colon leaves the rest of it inside the password. A repository
# was created with the trimmed value and this script then presented the padded
# one, which restic rejects as "wrong password or no key found" without saying
# that the two differ by whitespace.
export RESTIC_PASSWORD
RESTIC_PASSWORD=$(grep -m1 "Restic Backup:" "$CRED_FILE" 2>/dev/null \
    | sed -e 's/^[^:]*:[[:space:]]*//' -e 's/[[:space:]]*$//')
if [[ -z "$RESTIC_PASSWORD" ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') -- ERROR: no Restic password in ${CRED_FILE}" >> "$LOG"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') -- Backup starting..." >> "$LOG"

# Exit statuses are kept. The previous version ran all four restic commands
# and then logged "Backup complete" whatever happened, so a repository this
# script could not even open reported a successful backup every night for
# months.
rc=0
restic backup "${DATA_ROOT}" "${DOCKER_ROOT}" \
    --tag corex \
    --exclude="*.tmp" \
    --exclude="*.log" \
    --exclude="*/cache/*" \
    >> "$LOG" 2>&1 || rc=$?

if (( rc != 0 )); then
    echo "$(date '+%Y-%m-%d %H:%M:%S') -- BACKUP FAILED (exit ${rc}). Nothing below ran." >> "$LOG"
    exit "$rc"
fi

restic forget \
    --keep-daily 7 \
    --keep-weekly 4 \
    --keep-monthly 6 \
    --prune \
    >> "$LOG" 2>&1 || echo "$(date '+%Y-%m-%d %H:%M:%S') -- forget/prune failed, the snapshot is still there." >> "$LOG"

# ── Integrity verification (spot-check 5% of data) ───────────────────────
echo "$(date '+%Y-%m-%d %H:%M:%S') — Running integrity check..." >> "$LOG"
if restic check --read-data-subset=5% >> "$LOG" 2>&1; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') — Integrity check PASSED." >> "$LOG"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') — INTEGRITY CHECK FAILED! Repository may be corrupted." >> "$LOG"
    echo "$(date '+%Y-%m-%d %H:%M:%S') — Run manually: restic check --read-data" >> "$LOG"
fi

restic stats --mode raw-data >> "$LOG" 2>&1

echo "$(date '+%Y-%m-%d %H:%M:%S') -- Backup complete." >> "$LOG"
BKEOF

    # ── Restore script ───────────────────────────────────────────────────────
    install_script /usr/local/bin/corex-restore.sh 750 << 'RSEOF'
#!/bin/bash
# CoreX Pro — Restore Script
# Usage: sudo corex-restore.sh [--list | --dry-run | snapshot-id]
BACKUP_ROOT="/mnt/corex-data/backups"
DOCKER_ROOT="/mnt/corex-data/docker-configs"
CRED_FILE="/root/corex-credentials.txt"
export RESTIC_REPOSITORY="${BACKUP_ROOT}/restic-repo"
export RESTIC_PASSWORD
RESTIC_PASSWORD=$(grep -m1 "Restic Backup:" "$CRED_FILE" 2>/dev/null \
    | sed -e 's/^[^:]*:[[:space:]]*//' -e 's/[[:space:]]*$//')

echo ""
echo "=== CoreX Restore ==="
echo ""

# --list: show snapshots without stopping services
if [[ "${1:-}" == "--list" ]]; then
    echo "Available snapshots:"
    restic snapshots
    exit 0
fi

echo "Available snapshots:"
restic snapshots
echo ""

SNAP="${1:-latest}"
DRY_RUN=false
[[ "$SNAP" == "--dry-run" ]] && { DRY_RUN=true; SNAP="latest"; }

echo "Selected: $SNAP"
if [[ "$DRY_RUN" == "true" ]]; then
    echo ""
    echo "[DRY RUN] Files that would be restored:"
    restic restore "$SNAP" --target / --dry-run 2>/dev/null | head -50
    echo ""
    echo "[DRY RUN] No changes made. Remove --dry-run to restore for real."
    exit 0
fi

read -r -p "Restore? This OVERWRITES current data. (y/N): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Aborted."
    exit 0
fi

echo "Stopping all Docker containers..."
docker stop $(docker ps -aq) 2>/dev/null || true

echo "Restoring files..."
restic restore "$SNAP" --target /

echo "Restarting all services..."
for dir in ${DOCKER_ROOT}/*/; do
    if [[ -f "$dir/docker-compose.yml" ]]; then
        echo "  Starting $(basename "$dir")..."
        (cd "$dir" && docker compose up -d 2>/dev/null) || true
    fi
done

echo ""
echo "Restore complete! Verify with: docker ps"
RSEOF
}

# The daily cron entry, for an install with no maintenance timer.
# `corex manage maintenance setup` removes this line and takes the schedule
# over, because two things running the same backup produces one snapshot and
# two histories that disagree about it.
backup_schedule_cron() {
    if systemctl is-enabled corex-maintenance.timer >/dev/null 2>&1; then
        log_info "The maintenance timer owns the backup schedule, leaving cron alone"
        return 0
    fi
    local EXISTING_CRON FILTERED_CRON
    EXISTING_CRON=$(crontab -l 2>/dev/null || true)
    FILTERED_CRON=$(echo "$EXISTING_CRON" | grep -v "corex-backup" || true)
    printf "%s\n0 3 * * * /usr/local/bin/corex-backup.sh\n" "$FILTERED_CRON" | crontab -
}
