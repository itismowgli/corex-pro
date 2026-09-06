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
    backup_write_conf
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

# Where the repository lives, as a file rather than as a constant repeated in
# three generated scripts. Every script that touches the repository sources
# this, so moving the repository is one edit.
#
# It is written unconditionally, for the reason in gotcha #22: anything CoreX
# generates is not user state. A BACKUP_ROOT already in the file wins, because
# an operator who moved the repository must not have it moved back by a
# repair, and that is the whole point of the file existing.
backup_write_conf() {
    local conf=/etc/corex/backup.conf
    local root="${BACKUP_ROOT:-/mnt/corex-data/backups}"

    # An existing setting is the operator's, not ours.
    if [[ -r "$conf" ]]; then
        local existing
        existing="$(. "$conf" >/dev/null 2>&1; echo "${BACKUP_ROOT:-}")"
        [[ -n "$existing" ]] && root="$existing"
    fi

    mkdir -p /etc/corex
    install_script "$conf" 644 << CONFEOF
# CoreX Pro backup location.
#
# Read by corex-backup.sh, corex-restore.sh and the maintenance runner. The
# repository is BACKUP_ROOT/restic-repo.
#
# Moving it: stop the maintenance timer, move the directory, change the line
# below, then confirm with
#   sudo corex manage credentials verify <your bundle>
# which opens the repository at whatever this file now points at.
#
# Do NOT change the Restic password. It cannot be changed after the repository
# is created without abandoning every snapshot in it.
BACKUP_ROOT="${root}"
CONFEOF
    log_success "Backup location recorded in ${conf} (${root})"
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
# Where the repository lives. Read from /etc/corex/backup.conf when it exists,
# so moving the repository is one edit rather than three scripts that must be
# kept in step. Every generated script reads the same file.
BACKUP_ROOT="/mnt/corex-data/backups"
[[ -r /etc/corex/backup.conf ]] && . /etc/corex/backup.conf
DATA_ROOT="/mnt/corex-data/service-data"
DOCKER_ROOT="/mnt/corex-data/docker-configs"
DUMP_DIR="${DATA_ROOT}/.db-dumps"
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

# ── Database dumps ───────────────────────────────────────────────────────
#
# Copying a running database's files is not a backup of that database. Restic
# walks the data directory over seconds or minutes while Postgres and MariaDB
# are still writing, so the snapshot catches a torn mixture of pages and WAL
# from different instants. It usually restores. When it does not, you find out
# during the restore, which is the worst possible moment.
#
# A dump is taken through the engine instead, which is consistent by
# definition, and is what the restore should prefer. The file copy stays,
# because it carries everything a dump does not.
#
# Never fatal: a database that cannot be dumped must not stop the rest of the
# backup, it must be reported and the file copy taken anyway.
dump_rc=0
mkdir -p "$DUMP_DIR"
chmod 700 "$DUMP_DIR"

_dump_pg() {   # container, then the file to write
    # The superuser is whatever POSTGRES_USER says, read from inside the
    # container rather than assumed. Immich uses postgres and Cal.com uses
    # calcom, so a hardcoded -U postgres dumped one and failed the other.
    docker exec "$1" sh -c \
        'exec pg_dumpall -U "${POSTGRES_USER:-postgres}"' 2>>"$LOG" | gzip > "${DUMP_DIR}/$2.sql.gz"
    # PIPESTATUS, not $?: $? here is gzip's, which succeeds happily on an
    # empty stream, so a failed dump would be recorded as a good one.
    local st=${PIPESTATUS[0]}
    if (( st != 0 )); then
        echo "$(date '+%Y-%m-%d %H:%M:%S') -- WARNING: pg_dumpall failed for $1 (exit ${st})" >> "$LOG"
        rm -f "${DUMP_DIR}/$2.sql.gz"
        dump_rc=1
    fi
}

_dump_mysql() {
    # The image sets one of these two depending on its age and its lineage.
    # Naming only the MariaDB one meant an empty password on an image that
    # sets the MySQL one, which mysqldump rejects with exit 2.
    docker exec "$1" sh -c \
        'exec mysqldump --all-databases --single-transaction --quick \
             -uroot -p"${MARIADB_ROOT_PASSWORD:-$MYSQL_ROOT_PASSWORD}"' \
        2>>"$LOG" | gzip > "${DUMP_DIR}/$2.sql.gz"
    local st=${PIPESTATUS[0]}
    if (( st != 0 )); then
        echo "$(date '+%Y-%m-%d %H:%M:%S') -- WARNING: mysqldump failed for $1 (exit ${st})" >> "$LOG"
        rm -f "${DUMP_DIR}/$2.sql.gz"
        dump_rc=1
    fi
}

# Discovered, not listed. The raw *-db directories are excluded from the file
# backup below because the dump supersedes them, so a database this loop does
# not find is backed up nowhere at all. A hardcoded list made that a silent
# consequence of adding a service: keeper arrived with a keeper-db Postgres
# directory and would have had no backup of any kind.
#
# The engine is decided by which client is actually in the image rather than by
# the container's name or its tag, because neither is reliable.
for c in $(docker ps --format '{{.Names}}' | grep -E -- '-db$|^db$' || true); do
    if docker exec "$c" sh -c 'command -v pg_dumpall >/dev/null 2>&1'; then
        _dump_pg "$c" "$c"
    elif docker exec "$c" sh -c 'command -v mysqldump >/dev/null 2>&1'; then
        _dump_mysql "$c" "$c"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') -- WARNING: ${c} looks like a database but has no dump tool; its files are excluded from this backup" >> "$LOG"
        dump_rc=1
    fi
done

# Keeper bundles PostgreSQL inside the app container. Back up through its
# engine as well as retaining the volume and the credential env files.
if docker ps --format '{{.Names}}' | grep -qx keeper; then
    docker exec keeper sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" exec pg_dump -h 127.0.0.1 -U keeper -d keeper' \
        2>>"$LOG" | gzip > "${DUMP_DIR}/keeper.sql.gz"
    keeper_dump_status=("${PIPESTATUS[@]}")
    if (( keeper_dump_status[0] != 0 || keeper_dump_status[1] != 0 )); then
        echo "$(date '+%Y-%m-%d %H:%M:%S'): WARNING: Keeper database dump failed" >> "$LOG"
        rm -f "${DUMP_DIR}/keeper.sql.gz"
        dump_rc=1
    fi
fi

# SQLite is a single file and its own tool takes a consistent copy of it while
# the application is still writing. cp does not: restic walks the directory
# over seconds, so it can read db.sqlite3 at one instant and its -wal at
# another and store a pair that do not belong together.
#
# The tool has to be found rather than assumed, and found in two places. The
# previous version only probed inside the container and moved on in silence
# when the probe failed, which is what happened to Vaultwarden: its image
# carries no sqlite3, so the password vault was the one database on the box
# with no consistent dump, and nothing in any log said so. Uptime Kuma's
# image does carry one, so a single probe looked like it worked.
#
# Order is container first, then the host against the same file through its
# bind mount, which is why sqlite3 is installed by lib/security.sh. Failing
# to dump is reported and is a failed run, never a silence.
#
# Each entry is container, path inside the container, path under DATA_ROOT.
for triple in \
    "vaultwarden:/data/db.sqlite3:vaultwarden/db.sqlite3" \
    "uptime-kuma:/app/data/kuma.db:uptime-kuma/kuma.db"
do
    c="${triple%%:*}"; rest="${triple#*:}"
    f="${rest%%:*}"; hostrel="${rest#*:}"
    docker ps --format '{{.Names}}' | grep -qx "$c" || continue
    out="${DUMP_DIR}/${c}.db"

    if docker exec "$c" sh -c 'command -v sqlite3 >/dev/null 2>&1'; then
        if docker exec "$c" sqlite3 "$f" ".backup /tmp/corex-dump.db" 2>>"$LOG" \
           && docker cp "$c:/tmp/corex-dump.db" "$out" 2>>"$LOG"; then
            docker exec "$c" rm -f /tmp/corex-dump.db 2>/dev/null
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') -- WARNING: sqlite3 .backup failed inside ${c}" >> "$LOG"
            rm -f "$out"
            dump_rc=1
        fi
    elif command -v sqlite3 >/dev/null 2>&1 && [[ -f "${DATA_ROOT}/${hostrel}" ]]; then
        # .backup against a live WAL database is the supported path: sqlite
        # takes its own lock and produces a consistent file.
        if sqlite3 "${DATA_ROOT}/${hostrel}" ".backup ${out}" 2>>"$LOG"; then
            :
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') -- WARNING: sqlite3 .backup failed on ${DATA_ROOT}/${hostrel}" >> "$LOG"
            rm -f "$out"
            dump_rc=1
        fi
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') -- WARNING: no sqlite3 in ${c} and none on the host, so ${c} has only a file copy of its database, which restic may capture mid-write. Install sqlite3." >> "$LOG"
        dump_rc=1
    fi

    # A dump that exists but is unreadable is worse than none, because it is
    # the copy a restore will reach for first.
    if [[ -f "$out" ]]; then
        if command -v sqlite3 >/dev/null 2>&1; then
            sqlite3 "$out" "PRAGMA integrity_check;" 2>>"$LOG" | grep -qx ok \
                || { echo "$(date '+%Y-%m-%d %H:%M:%S') -- WARNING: ${c} dump fails integrity_check" >> "$LOG"
                     rm -f "$out"; dump_rc=1; }
        fi
        chmod 600 "$out" 2>/dev/null
    fi
done
(( dump_rc != 0 )) && echo "$(date '+%Y-%m-%d %H:%M:%S') -- one or more dumps failed, see above" >> "$LOG"

# Exit statuses are kept. The previous version ran all four restic commands
# and then logged "Backup complete" whatever happened, so a repository this
# script could not even open reported a successful backup every night for
# months.
rc=0
# Both a dump and the raw files are kept for every database, deliberately.
# The dump is consistent and is what a restore should reach for first; the
# files carry everything a dump does not. Excluding the files wherever a dump
# succeeded was tried and removed: the variable holding the list of dumped
# names was never appended to, so the exclusion never once happened, and the
# behaviour it described is the wrong one anyway. A blanket "*-db" pattern is
# worse still, because it drops the files of a database that was stopped at
# backup time, which is exactly what a disabled service has.

# /etc/corex is the difference between a backup and a restorable box. It holds
# state.json, the thermal, maintenance and power settings, the SSO and SMTP
# configuration, the agent token and the dashboard accounts. Without it a
# restore gives you the data back and nothing that knows what to do with it.
# /var/lib/corex carries the maintenance history and the update cache.
# fstab carries the shared data mount and NVMe database bind mounts. Without
# it, a bare-system restore has the data but starts services against empty
# directories on the OS disk.
restic backup "${DATA_ROOT}" "${DOCKER_ROOT}" /etc/corex /etc/fstab /var/lib/corex \
    --tag corex \
    --exclude="*.tmp" \
    --exclude="*.log" \
    --exclude="*/cache/*" \
    --exclude="${DATA_ROOT}/prometheus" \
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
check_rc=0
if restic check --read-data-subset=5% >> "$LOG" 2>&1; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') -- Integrity check PASSED." >> "$LOG"
else
    check_rc=1
    echo "$(date '+%Y-%m-%d %H:%M:%S') -- INTEGRITY CHECK FAILED. Repository may be corrupted." >> "$LOG"
    echo "$(date '+%Y-%m-%d %H:%M:%S') -- Run manually: restic check --read-data" >> "$LOG"
fi

# The snapshot this run made, not merely the newest one in the repository.
# Asking whether any snapshot exists answers yes for a repository that has not
# been written to in a month, which is the reassuring answer to the wrong
# question.
if ! restic snapshots --tag corex --latest 1 --json 2>/dev/null \
     | grep -q "$(date '+%Y-%m-%d')"; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') -- WARNING: no snapshot from today in the repository." >> "$LOG"
    check_rc=1
fi

# Each stage reported separately, and a failure in any of them is the script's
# exit status. Logging a problem and then exiting 0 is how the scheduled task
# recorded months of successful backups it had never taken.
echo "$(date '+%Y-%m-%d %H:%M:%S') -- backup=ok dumps=$( ((dump_rc==0)) && echo ok || echo FAILED ) integrity=$( ((check_rc==0)) && echo ok || echo FAILED )" >> "$LOG"
if (( dump_rc != 0 || check_rc != 0 )); then
    exit 1
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
[[ -r /etc/corex/backup.conf ]] && . /etc/corex/backup.conf
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
