#!/bin/bash
# lib/kuma.sh — CoreX Pro
# Seeds Uptime Kuma's HTTP monitors from the service modules.
#
# WHY THIS EXISTS
#   The six resource monitors have been seeded from code since v3.11.0
#   (lib/watchdog.sh), but the HTTP reachability checks were created by hand in
#   Kuma's own interface. That means they live in exactly one place, kuma.db,
#   and nothing recreates them: a fresh install has none, a restore from
#   backup has whatever the backup happened to hold, and adding a service
#   leaves it unmonitored until somebody remembers. Alerting that depends on
#   someone remembering is not alerting.
#
#   Each module now declares its own check, so a new service is monitored by
#   the same act that installs it.
#
# THE MONITOR NAME IS THE KEY
#   Monitors are matched by name, not by url, so this adopts the ones already
#   in the database rather than creating duplicates beside them. The names in
#   the modules were chosen to match what was there. Changing a module's
#   SERVICE_MONITOR_NAME later creates a second monitor and orphans the first,
#   which is worth knowing before renaming one.
#
# KUMA CACHES ITS MONITOR LIST IN MEMORY
#   A row inserted underneath a running instance is ignored until restart, so
#   this stops Kuma, writes, and starts it again, taking a cold backup first.
#   Same reasoning and same shape as watchdog_seed_monitors.

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

_KUMA_DB="${DATA_ROOT:-/mnt/corex-data/service-data}/uptime-kuma/kuma.db"

# ── Discovery ─────────────────────────────────────────────────────────────────
# Emits one tab-separated line per monitor an installed module declares:
#   <name>\t<url>\t<accepted status codes json>
#
# Read from the modules in a subshell with printf, never eval, so a module
# cannot inject anything into this shell. DOMAIN and SERVER_IP are exported so
# a module's URL can interpolate them.
_kuma_declared_monitors() {
    local dir="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/lib/services"
    local f svc line
    for f in "${dir}"/*.sh; do
        [[ -f "$f" ]] || continue
        # ._* are AppleDouble sidecars from a macOS tar; they match the glob,
        # are binary, and once killed service discovery outright (gotcha #30).
        [[ "$(basename "$f")" == ._* ]] && continue
        svc=$(bash -c "source '$f' 2>/dev/null; printf '%s' \"\${SERVICE_NAME:-}\"" 2>/dev/null)
        [[ -n "$svc" ]] || continue
        if declare -f state_service_is_installed >/dev/null 2>&1; then
            state_service_is_installed "$svc" 2>/dev/null || continue
        fi
        # Installed is not enough: a service switched off on purpose would get
        # a monitor that is permanently DOWN, which means a Telegram alert
        # about a state the operator chose. Coolify is disabled on this box
        # precisely so it stops using resources; alerting about that would
        # train everyone to ignore the alerts.
        if declare -f state_service_is_enabled >/dev/null 2>&1; then
            state_service_is_enabled "$svc" 2>/dev/null || continue
        fi
        # A module may declare several checks, one per line, because a module
        # can publish more than one hostname: monitoring answers on both
        # grafana and status.
        line=$(DOMAIN="${DOMAIN:-}" SERVER_IP="${SERVER_IP:-}" \
            bash -c "source '$f' 2>/dev/null; printf '%s' \"\${SERVICE_MONITORS:-}\"" 2>/dev/null)
        [[ -n "$line" ]] || continue
        printf '%s\n' "$line"
    done
}

# ── Seed ──────────────────────────────────────────────────────────────────────
kuma_seed_http_monitors() {
    local monitors
    monitors=$(_kuma_declared_monitors)
    if [[ -z "$monitors" ]]; then
        log_info "No service declares an uptime check, nothing to seed"
        return 0
    fi
    if [[ ! -f "$_KUMA_DB" ]]; then
        log_warning "Uptime Kuma database not found at ${_KUMA_DB}, skipping monitor setup"
        return 1
    fi
    command -v python3 &>/dev/null || { log_warning "python3 missing, cannot seed monitors"; return 1; }

    local was_running=false
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qxF uptime-kuma; then
        was_running=true
        log_info "Stopping Uptime Kuma to seed monitors..."
        docker stop uptime-kuma >/dev/null 2>&1 || true
    fi

    # Cold backup before touching the file that holds every monitor,
    # notification and heartbeat.
    cp -a "$_KUMA_DB" "${_KUMA_DB}.pre-seed" 2>/dev/null || true

    local rc=0
    printf '%s\n' "$monitors" | python3 - "$_KUMA_DB" << 'PYEOF' || rc=$?
"""Create or update one HTTP monitor per declared check, and link it to every
active notification so it actually reaches somebody.

Matched by name: this adopts monitors created by hand rather than duplicating
them. Operational settings (interval, retries, resend, timeout) are cloned
from an existing monitor where one exists, so a deliberate change in Kuma's
interface is not overwritten on the next run.
"""
import json
import sqlite3
import ssl
import sys
import urllib.error
import urllib.request

DEFAULTS = dict(interval=60, retry_interval=60, resend_interval=0,
                maxretries=1, weight=2000, method="GET", maxredirects=10,
                ignore_tls=0, upside_down=0, expiry_notification=0, timeout=48)


def _acceptable(status, codes):
    """Does this status match Kuma's accepted-codes list, such as ["200-299"]."""
    try:
        ranges = json.loads(codes)
    except ValueError:
        ranges = ["200-299"]
    for spec in ranges:
        spec = str(spec)
        if "-" in spec:
            lo, hi = spec.split("-", 1)
            if lo.isdigit() and hi.isdigit() and int(lo) <= status <= int(hi):
                return True
        elif spec.isdigit() and int(spec) == status:
            return True
    return False


def _answers(url, codes):
    """One request, no redirects followed, certificate not verified.

    Not following redirects is deliberate: Kuma does not either, and a 302 is
    a pass only when the module says so. The certificate is not verified
    because these are LAN hostnames served by the CoreX certificate authority,
    which the host does not necessarily trust.
    """
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *a, **kw):
            return None

    opener = urllib.request.build_opener(NoRedirect,
                                         urllib.request.HTTPSHandler(context=ctx))
    try:
        with opener.open(url, timeout=8) as r:
            return _acceptable(r.status, codes)
    except urllib.error.HTTPError as e:
        return _acceptable(e.code, codes)
    except Exception:
        return False


def main(db_path):
    checks = []
    for line in sys.stdin:
        parts = line.rstrip("\n").split("\t")
        if len(parts) >= 2 and parts[0].strip() and parts[1].strip():
            checks.append((parts[0].strip(), parts[1].strip(),
                           parts[2].strip() if len(parts) > 2 and parts[2].strip()
                           else '["200-299"]'))
    if not checks:
        return 0

    db = sqlite3.connect(db_path, timeout=30)
    db.execute("PRAGMA busy_timeout = 30000")
    cur = db.cursor()

    user = cur.execute("SELECT id FROM user ORDER BY id LIMIT 1").fetchone()
    user_id = user[0] if user else 1
    notif = [r[0] for r in cur.execute("SELECT id FROM notification WHERE active = 1")]
    if not notif:
        print("# warning: no active notification in Kuma, monitors will be "
              "silent until one is configured", file=sys.stderr)

    # Clone the operational settings of an existing HTTP monitor, so a box
    # where the operator tuned the interval keeps that tuning.
    tpl = cur.execute(
        "SELECT interval, retry_interval, resend_interval, maxretries, weight, "
        "method, maxredirects, ignore_tls, upside_down, expiry_notification, timeout "
        "FROM monitor WHERE type = 'http' ORDER BY id LIMIT 1").fetchone()
    keys = ["interval", "retry_interval", "resend_interval", "maxretries", "weight",
            "method", "maxredirects", "ignore_tls", "upside_down",
            "expiry_notification", "timeout"]
    settings = dict(zip(keys, tpl)) if tpl else dict(DEFAULTS)

    created = updated = skipped = 0
    for name, url, codes in checks:
        # A monitor is only created for a hostname that answers now.
        #
        # A module can be installed and enabled while one of its containers is
        # deliberately stopped: the monitoring module ships Grafana,
        # Prometheus and Uptime Kuma, and this box runs only the last of them.
        # Creating a monitor for a component that was switched off produces a
        # permanently DOWN check, which means a Telegram alert about a state
        # the operator chose, and that is how alerts get ignored. Existing
        # monitors are never removed on this basis: switching something off
        # for an hour should not delete its history.
        if not cur.execute("SELECT 1 FROM monitor WHERE name = ?", (name,)).fetchone():
            if not _answers(url, codes):
                skipped += 1
                print("skipped %s: %s does not answer acceptably yet" % (name, url),
                      file=sys.stderr)
                continue
        row = cur.execute("SELECT id, url FROM monitor WHERE name = ?", (name,)).fetchone()
        if row:
            mid = row[0]
            # Only the address and the accepted codes are ours to correct: a
            # renamed hostname has to reach the monitor, but an interval the
            # operator changed in the interface is theirs.
            if row[1] != url:
                cur.execute("UPDATE monitor SET url = ?, accepted_statuscodes_json = ?, "
                            "active = 1 WHERE id = ?", (url, codes, mid))
                updated += 1
                print("updated %s -> %s" % (name, url), file=sys.stderr)
        else:
            cur.execute(
                "INSERT INTO monitor (name, url, type, active, user_id, "
                "accepted_statuscodes_json, created_date, interval, retry_interval, "
                "resend_interval, maxretries, weight, method, maxredirects, "
                "ignore_tls, upside_down, expiry_notification, timeout) "
                "VALUES (?, ?, 'http', 1, ?, ?, datetime('now'), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (name, url, user_id, codes, settings["interval"],
                 settings["retry_interval"], settings["resend_interval"],
                 settings["maxretries"], settings["weight"], settings["method"],
                 settings["maxredirects"], settings["ignore_tls"],
                 settings["upside_down"], settings["expiry_notification"],
                 settings["timeout"]))
            mid = cur.lastrowid
            created += 1
            print("created %s -> %s" % (name, url), file=sys.stderr)

        for nid in notif:
            cur.execute(
                "INSERT INTO monitor_notification (monitor_id, notification_id) "
                "SELECT ?, ? WHERE NOT EXISTS (SELECT 1 FROM monitor_notification "
                "WHERE monitor_id = ? AND notification_id = ?)", (mid, nid, mid, nid))

    db.commit()
    total = cur.execute("SELECT count(*) FROM monitor WHERE type = 'http'").fetchone()[0]
    db.close()
    print("SEEDED %d created, %d updated, %d skipped, %d http monitors total"
          % (created, updated, skipped, total), file=sys.stderr)
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: seed <kuma.db>", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
PYEOF

    [[ "$was_running" == "true" ]] && docker start uptime-kuma >/dev/null 2>&1 || true

    if (( rc != 0 )); then
        log_warning "Seeding monitors failed; the database backup is at ${_KUMA_DB}.pre-seed"
        return 1
    fi
    log_success "Uptime Kuma HTTP monitors seeded from the service modules"
}
