#!/bin/bash
# lib/services/calcom.sh — CoreX Pro
# Cal.com: self-hosted scheduling and booking links.
#
# UPSTREAM: https://github.com/calcom/cal.diy  (AGPL-3.0, renamed from calcom/cal.com)
#
# WHY THE PREBUILT IMAGE IS USED, AND WHY THAT IS NOT OBVIOUS
#   NEXT_PUBLIC_WEBAPP_URL is a build argument, and every self-hosting guide
#   therefore says the image has to be rebuilt for your own domain. It does
#   not. The Dockerfile records the build-time value a second time as
#   BUILT_NEXT_PUBLIC_WEBAPP_URL, and /calcom/scripts/start.sh compares the
#   two on every boot: when they differ it re-runs replace-placeholder.sh over
#   the compiled assets. So the published image can be pointed at any domain
#   at run time, and CoreX never compiles it.
#
#   That matters more here than it sounds. Compiling a Next.js application is
#   the hottest thing this project can do (gotcha #31): the last time one was
#   built on this class of hardware the box went from 64C to 96.4C and the
#   thermal guardian shed twelve unrelated containers. A service that pulls an
#   image instead costs nothing but disk.
#
# WHAT IT NEEDS, AND WHAT IT ONLY CLAIMS TO NEED
#   PostgreSQL and a domain. That is all. Google and Stripe are genuinely
#   optional (both are empty in upstream's own .env.example, and the Stripe
#   entries exist for cal.com's hosted paid tiers), which is the difference
#   between this and the booking tool CoreX evaluated before it.
#
#   Redis is in upstream's compose file but only the API v2 container reads
#   REDIS_URL, and CoreX does not run API v2, so there is no Redis here.
#
#   Migrations need no separate container either: start.sh waits for the
#   database itself and then runs `prisma migrate deploy`.
#
# THE TWO PIECES CAL.COM ASSUMES SOMEONE ELSE PROVIDES
#   Upstream runs on Vercel, so two things a booking tool needs are supplied
#   by the platform rather than by the app, and a plain `docker compose up`
#   silently has neither:
#
#     1. Cron. apps/web/vercel.json lists the schedules. Without them
#        scheduled webhook triggers never fire, reminder mail for unconfirmed
#        bookings is never sent, and a connected Google calendar's watch
#        subscription is never renewed.
#     2. Anything that turns a booking into a notification you will actually
#        see. Cal.com sends webhooks; it does not send you a message.
#
#   calcom-helper covers both in one small container: it calls the cron
#   endpoints on upstream's own schedule, and it receives Cal.com's booking
#   webhooks and posts them to the same Telegram chat the Uptime Kuma alerts
#   and the control bot already use.

# ── Metadata ──────────────────────────────────────────────────────────────────
SERVICE_NAME="calcom"
SERVICE_LABEL="Cal.com — Scheduling & Booking Links (replaces Calendly)"
SERVICE_CATEGORY="productivity"
SERVICE_REQUIRED=false
SERVICE_NEEDS_DOMAIN=true
SERVICE_NEEDS_EMAIL=false
SERVICE_RAM_MB=3072
SERVICE_DISK_GB=12
# Nothing is published to the host: Traefik reaches it over proxy-net, so
# there is no port to open and nothing for cmd_remove to revoke.
SERVICE_FIREWALL_SPECS=()
SERVICE_DESCRIPTION="Share a booking link and let people pick a slot. Availability rules, calendar sync, confirmation email, and a Telegram message when someone books."

# Pinned, not :latest. Upstream's :latest currently resolves to this same
# build, which is exactly the situation gotcha #26 is about: a tag that has
# stopped moving looks identical to a tag that is current. Bump this
# deliberately, and read the release notes for database changes first.
CALCOM_IMAGE="${CALCOM_IMAGE:-calcom/cal.com:v6.2.0}"
# amd64 only upstream. There is no arm64 manifest for this tag, so this module
# cannot run on a Pi or an Apple-silicon VM.
CALCOM_DB_IMAGE="${CALCOM_DB_IMAGE:-postgres:16}"
# Debian rather than alpine on purpose: the alpine postgres images run as uid
# 70, the Debian ones as uid 999, and calcom_dirs has to chown the data
# directory to whichever it is. One number, stated once, beats a surprise on
# first start.
CALCOM_HELPER_IMAGE="${CALCOM_HELPER_IMAGE:-python:3.12-alpine}"
# Minor-pinned the way traefik:v3.6 and mariadb:10.11 are. The helper is
# stdlib-only Python, so the patch line is safe to track.

# ── Subdomain ─────────────────────────────────────────────────────────────────
# "cal" unless overridden. Resolution order, same as n8n's and for the same
# reason: a hostname can become unusable through no fault of the service, and
# changing it must survive a repair.
#
#   1. $CALCOM_SUBDOMAIN from the environment
#   2. calcom_subdomain in state.json
#   3. "cal"
_calcom_subdomain() {
    local sub="${CALCOM_SUBDOMAIN:-}"
    if [[ -z "$sub" ]] && declare -f state_get >/dev/null 2>&1; then
        sub=$(state_get "calcom_subdomain" 2>/dev/null)
        [[ "$sub" == "null" ]] && sub=""
    fi
    printf '%s' "${sub:-cal}"
}

# ── Directories ───────────────────────────────────────────────────────────────
calcom_dirs() {
    mkdir -p "${DOCKER_ROOT}/calcom" "${DATA_ROOT}/calcom-db"
    # postgres:16 runs as uid 999.
    chown -R 999:999 "${DATA_ROOT}/calcom-db" 2>/dev/null || true
}

calcom_firewall() {
    :   # Traefik fronts it; nothing to open.
}

# ── Secrets ───────────────────────────────────────────────────────────────────
# One 0600 file beside the service, never state.json, which is 0644 and
# bind-mounted into a web-facing container (gotcha #24). Generated once and
# then reused: regenerating on repair would change the database password out
# from under a running database, and would invalidate every session and every
# stored calendar credential, which is how the Stalwart admin password went
# missing (gotcha #3).
_calcom_secrets() {
    local env_file="${DOCKER_ROOT}/calcom/.secrets.env"

    if [[ -s "$env_file" ]]; then
        # shellcheck source=/dev/null
        set -a; . "$env_file"; set +a
        _calcom_sync_secrets "$env_file"
        return 0
    fi

    log_info "Generating Cal.com secrets (once, then reused)..."
    # Hex throughout, deliberately: these values are interpolated into a
    # PostgreSQL connection URL, and a password containing @ / : or ? would
    # corrupt the URL rather than fail loudly.
    #
    # umask is saved and restored. Setting it and walking away leaks 077 to
    # every file written afterwards.
    local prev_umask; prev_umask=$(umask)
    umask 077
    cat > "$env_file" << SECEOF
# CoreX-generated Cal.com secrets. 0600, never in state.json.
#
# Back this file up. CALCOM_ENCRYPTION_KEY decrypts the stored credentials for
# every connected calendar, so losing it means reconnecting all of them, and
# losing CALCOM_DB_PASS means losing the database.
CALCOM_DB_PASS=$(openssl rand -hex 24)
CALCOM_NEXTAUTH_SECRET=$(openssl rand -hex 32)
# Exactly 32 characters: upstream uses it as an AES-256 key and rejects any
# other length.
CALCOM_ENCRYPTION_KEY=$(openssl rand -hex 16)
# Cal.com's scheduled work is authenticated by two different variables, and
# the endpoints disagree about which. CRON_API_KEY is sent bare, CRON_SECRET
# as a Bearer token; calcom-helper sends whichever each path wants.
CALCOM_CRON_API_KEY=$(openssl rand -hex 16)
CALCOM_CRON_SECRET=$(openssl rand -hex 16)
# Signs the booking webhooks Cal.com posts to calcom-helper, so nothing else
# on proxy-net can make the helper send a Telegram message.
CALCOM_WEBHOOK_SECRET=$(openssl rand -hex 32)
SECEOF
    umask "$prev_umask"
    chmod 600 "$env_file"
    # shellcheck source=/dev/null
    set -a; . "$env_file"; set +a
}

# Backfill keys a later release added.
#
# The compose heredoc runs under `set -u`, so one missing variable aborts it
# halfway and leaves an empty docker-compose.yml. The failure then reads as
# "empty compose file", which points nowhere near the cause. Same reasoning as
# _watchdog_sync_conf.
_calcom_sync_secrets() {
    local env_file="$1" k
    for k in CALCOM_DB_PASS CALCOM_NEXTAUTH_SECRET CALCOM_ENCRYPTION_KEY \
             CALCOM_CRON_API_KEY CALCOM_CRON_SECRET CALCOM_WEBHOOK_SECRET; do
        grep -q "^${k}=" "$env_file" 2>/dev/null && continue
        case "$k" in
            CALCOM_ENCRYPTION_KEY) echo "${k}=$(openssl rand -hex 16)" >> "$env_file" ;;
            *)                     echo "${k}=$(openssl rand -hex 24)" >> "$env_file" ;;
        esac
    done
    # shellcheck source=/dev/null
    set -a; . "$env_file"; set +a
}

# ── Outbound mail ─────────────────────────────────────────────────────────────
# Takes the relay the installer collected. Cal.com starts perfectly well
# without one and then cannot send a single confirmation, which is a booking
# tool that does not book, so this is reported rather than assumed.
#
# Sets CALCOM_SMTP_* for the compose heredoc. Returns 1 when there is no
# relay, leaving the variables empty, which is a valid configuration: the app
# runs, the app just cannot send mail.
_calcom_smtp() {
    CALCOM_SMTP_HOST=""; CALCOM_SMTP_PORT="587"; CALCOM_SMTP_USER=""
    CALCOM_SMTP_PASSWORD=""; CALCOM_SMTP_FROM=""

    declare -f smtp_conf_load >/dev/null 2>&1 || return 1
    smtp_conf_load 2>/dev/null || return 1
    [[ -n "${COREX_SMTP_HOST:-}" && -n "${COREX_SMTP_USER:-}" ]] || return 1

    CALCOM_SMTP_HOST="$COREX_SMTP_HOST"
    CALCOM_SMTP_PORT="${COREX_SMTP_PORT:-587}"
    CALCOM_SMTP_USER="$COREX_SMTP_USER"
    # Gmail prints app passwords in four groups for readability; SMTP AUTH
    # wants the sixteen characters with no spaces, and an unstripped value
    # fails authentication with a message that blames the credentials.
    CALCOM_SMTP_PASSWORD="${COREX_SMTP_PASSWORD//[[:space:]]/}"
    CALCOM_SMTP_FROM="${COREX_SMTP_FROM:-$COREX_SMTP_USER}"
    # There is deliberately no TLS setting to pass. Upstream derives it from
    # the port alone, as `secure: port === 465`, so 587 gets STARTTLS and 465
    # gets implicit TLS with nothing to configure and nothing to get wrong.
    return 0
}

# ── Telegram credentials ──────────────────────────────────────────────────────
# Reuses the bot token and chat id already configured for the Kuma alerts and
# the control bot, so booking notifications need no separate setup and arrive
# in the same chat. Absent is not an error: the helper then does its cron work
# and nothing else.
_calcom_telegram_creds() {
    CALCOM_TG_TOKEN=""; CALCOM_TG_CHAT=""
    local f="/etc/corex/telegram.conf"
    [[ -r "$f" ]] || return 1
    CALCOM_TG_TOKEN=$(grep -m1 '^TELEGRAM_BOT_TOKEN=' "$f" 2>/dev/null | cut -d= -f2- | tr -d "\"' ")
    CALCOM_TG_CHAT=$(grep -m1 '^TELEGRAM_CHAT_ID=' "$f" 2>/dev/null | cut -d= -f2- | tr -d "\"' ")
    [[ -n "$CALCOM_TG_TOKEN" && -n "$CALCOM_TG_CHAT" ]]
}

# ── psql ──────────────────────────────────────────────────────────────────────
# SQL on stdin rather than -c, so nothing has to survive two levels of shell
# quoting on its way to a query that contains double-quoted identifiers.
#
# Quiet by default because most callers are probes that run before the
# database is necessarily up, where "container not running" is an answer and
# not a fault. Pass "loud" for a write, where the error is the whole point.
#
# No password is needed: the official image's pg_hba grants trust to local
# socket connections, which is what docker exec gets.
_calcom_psql() {
    local err=/dev/null
    [[ "${1:-}" == "loud" ]] && err=/dev/stderr
    docker exec -i calcom-db psql -v ON_ERROR_STOP=1 -qtA \
        -U calcom -d calcom 2>"$err"
}

# How many accounts exist, or "noschema" before the first boot has finished
# migrating. Those are different states and the callers treat them differently.
#
# The table is `users`, not `"User"`. The Prisma model is User and most models
# map to their own name, but this one carries @@map(name: "users"), so a query
# against "User" fails with "relation does not exist" on a database that is
# perfectly healthy. Webhook has no @@map, hence the quoted mixed case there.
#
# Guarding it with `CASE WHEN to_regclass(...) IS NULL` does not help:
# PostgreSQL plans both branches of the CASE, so the missing relation is a
# planning error rather than an unevaluated branch. A failed call is the
# signal instead.
_calcom_user_count() {
    local n
    n=$(_calcom_psql << 'SQLEOF'
SELECT count(*)::text FROM users;
SQLEOF
    ) || { printf 'noschema'; return 0; }
    n="${n//[[:space:]]/}"
    printf '%s' "${n:-noschema}"
}

# ── Signup policy ─────────────────────────────────────────────────────────────
# Cal.com's signup form is open by default, and this instance is published on
# a public hostname, so leaving it open lets strangers create accounts on it.
# Closing it before the first account exists locks the owner out instead.
#
# So it follows the account count: open while there are none, closed once
# there is one. Deploy and repair both regenerate the compose file, so signing
# up and then running `corex manage repair calcom` is what closes the door.
# Set calcom_allow_signup=true in state.json to keep it open, which is what
# you want if other people need their own accounts.
#
# Note where the check lives. NEXT_PUBLIC_DISABLE_SIGNUP is inlined into the
# client bundle at build time, so a runtime value does not reach the page and
# the form may still render. It does reach the server: the signup API reads
# process.env and answers 403. The refusal is real even though the form looks
# available.
_calcom_disable_signup() {
    local allow=""
    if declare -f state_get >/dev/null 2>&1; then
        allow=$(state_get "calcom_allow_signup" 2>/dev/null)
        [[ "$allow" == "null" ]] && allow=""
    fi
    [[ "$allow" == "true" ]] && { printf 'false'; return 0; }

    local users; users=$(_calcom_user_count)
    case "$users" in
        ""|noschema|0) printf 'false' ;;
        *)             printf 'true'  ;;
    esac
}

# ── The helper ────────────────────────────────────────────────────────────────
# Regenerated on every deploy, because it is generated config and not user
# state (gotcha #22). Stdlib only, the same rule the action agent follows.
_calcom_write_helper() {
    cat > "${DOCKER_ROOT}/calcom/helper.py" << 'PYEOF'
#!/usr/bin/env python3
"""Cal.com's two missing halves: scheduled work, and a notification you see.

Written by CoreX. Edits are overwritten on the next deploy or repair.

Two jobs, one process:

  cron    Cal.com's scheduled endpoints exist in the image but nothing calls
          them outside Vercel. The schedules below are upstream's own, from
          apps/web/vercel.json, with the two that are not listed there set to
          intervals that match what they do. Every one of them is idempotent
          and returns immediately when there is nothing due.

  hook    Receives Cal.com's booking webhooks and posts a plain-text summary
          to Telegram. The payload is signed with a shared secret and the
          signature is checked before anything is sent, so being reachable on
          proxy-net is not the same as being able to make this send messages.

Times are rendered in the organiser's own timezone using the utcOffset that
Cal.com puts in the payload, which is why this needs no tzdata.
"""

import hashlib
import hmac
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

APP_URL = os.environ.get("CALCOM_INTERNAL_URL", "http://calcom:3000")
CRON_API_KEY = os.environ.get("CALCOM_CRON_API_KEY", "")
CRON_SECRET = os.environ.get("CALCOM_CRON_SECRET", "")
WEBHOOK_SECRET = os.environ.get("CALCOM_WEBHOOK_SECRET", "")
TG_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
TG_CHAT = os.environ.get("TELEGRAM_CHAT_ID", "")
PUBLIC_URL = os.environ.get("CALCOM_PUBLIC_URL", "")
LISTEN_PORT = int(os.environ.get("CALCOM_HELPER_PORT", "8080"))

# (path, interval seconds, auth style). "key" sends CRON_API_KEY bare, which
# is what most of the cron routes compare against; "bearer" sends
# "Bearer <CRON_SECRET>", which is what the tasker routes want. Getting this
# backwards produces a 401 per tick and no other symptom.
JOBS = [
    # Dispatches the triggers Cal.com scheduled earlier: meeting started and
    # ended, no-show checks. Without this those webhooks never fire, so the
    # "starting now" message never arrives.
    ("/api/cron/webhookTriggers", 60, "key"),
    # Drains anything the app queued as a background task.
    ("/api/tasks/cron", 60, "bearer"),
    # Renews the watch subscriptions on connected Google and Microsoft
    # calendars. They expire, and an expired one stops incoming changes
    # silently.
    ("/api/cron/calendar-subscriptions", 300, "key"),
    ("/api/cron/selected-calendars", 300, "key"),
    # Sends workflow reminder mail whose scheduled time has arrived.
    ("/api/cron/workflows/scheduleEmailReminders", 300, "key"),
    # Reminds the organiser about bookings still awaiting confirmation, at
    # upstream's 48h, 24h and 3h marks. Hourly is enough to hit all three.
    ("/api/cron/bookingReminder", 3600, "key"),
    ("/api/cron/queuedFormResponseCleanup", 43200, "key"),
    ("/api/cron/calendar-subscriptions-cleanup", 86400, "key"),
    ("/api/tasks/cleanup", 86400, "bearer"),
]

EVENTS = {
    "BOOKING_CREATED":     "New booking",
    "BOOKING_REQUESTED":   "Booking request, awaiting your confirmation",
    "BOOKING_RESCHEDULED": "Booking rescheduled",
    "BOOKING_CANCELLED":   "Booking cancelled",
    "BOOKING_REJECTED":    "Booking rejected",
    "MEETING_STARTED":     "Meeting starting now",
    "MEETING_ENDED":       "Meeting ended",
}


def log(msg):
    print("%s %s" % (datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), msg),
          file=sys.stderr, flush=True)


# ── Telegram ──────────────────────────────────────────────────────────────────
# Plain text, no parse_mode. MarkdownV2 reserves . ! - ( ) [ ] among others
# and Telegram rejects the whole message with HTTP 400 if one is unescaped,
# which is how a previous CoreX message silently sent nothing. Booking titles
# and attendee names are arbitrary text, so they would break it constantly.
def telegram_send(text):
    if not (TG_TOKEN and TG_CHAT):
        log("telegram not configured, message dropped")
        return False
    body = json.dumps({
        "chat_id": TG_CHAT,
        "text": text[:4000],
        "disable_web_page_preview": True,
    }).encode()
    req = urllib.request.Request(
        "https://api.telegram.org/bot%s/sendMessage" % TG_TOKEN,
        data=body, headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            r.read()
        return True
    except urllib.error.HTTPError as e:
        log("telegram rejected the message: HTTP %s %s" % (e.code, e.read()[:200]))
    except Exception as e:                                  # noqa: BLE001
        log("telegram unreachable: %s" % e)
    return False


# ── Formatting ────────────────────────────────────────────────────────────────
def local_time(iso, offset_minutes):
    """ISO 8601 to a readable local time, using the payload's own offset."""
    if not iso:
        return "time unknown"
    try:
        dt = datetime.fromisoformat(str(iso).replace("Z", "+00:00"))
    except ValueError:
        return str(iso)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    if isinstance(offset_minutes, (int, float)):
        dt = dt.astimezone(timezone(timedelta(minutes=int(offset_minutes))))
        sign = "+" if dt.utcoffset() >= timedelta(0) else "-"
        total = abs(int(dt.utcoffset().total_seconds())) // 60
        zone = " (UTC%s%02d:%02d)" % (sign, total // 60, total % 60)
    else:
        dt = dt.astimezone(timezone.utc)
        zone = " (UTC)"
    return dt.strftime("%a %d %b %Y, %H:%M") + zone


def describe(body):
    trigger = body.get("triggerEvent", "")
    p = body.get("payload") or {}
    if not isinstance(p, dict):
        p = {}
    organizer = p.get("organizer") or {}
    lines = ["Cal.com: %s" % EVENTS.get(trigger, trigger or "event")]

    title = p.get("title") or p.get("eventTitle")
    if title:
        lines.append(title)

    start = local_time(p.get("startTime"), organizer.get("utcOffset"))
    lines.append("When:  %s" % start)

    people = []
    for a in (p.get("attendees") or []):
        if not isinstance(a, dict):
            continue
        who = a.get("name") or a.get("email") or ""
        mail = a.get("email") or ""
        people.append("%s (%s)" % (who, mail) if who and mail and who != mail else (who or mail))
    if people:
        lines.append("Who:   %s" % ", ".join(people))

    where = p.get("location")
    if where and not str(where).startswith("integrations:"):
        lines.append("Where: %s" % where)

    meeting = (p.get("metadata") or {}).get("videoCallUrl") if isinstance(p.get("metadata"), dict) else None
    if meeting:
        lines.append("Link:  %s" % meeting)

    reason = p.get("cancellationReason")
    if reason:
        lines.append("Reason: %s" % reason)

    if PUBLIC_URL and p.get("uid"):
        lines.append("%s/booking/%s" % (PUBLIC_URL.rstrip("/"), p["uid"]))
    return "\n".join(lines)


# ── Webhook receiver ──────────────────────────────────────────────────────────
class Handler(BaseHTTPRequestHandler):
    server_version = "corex-calcom-helper"

    def log_message(self, fmt, *args):        # quiet; we log what matters
        pass

    def _reply(self, code, text="ok"):
        payload = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path in ("/healthz", "/"):
            self._reply(200)
        else:
            self._reply(404, "not found")

    def do_POST(self):
        if self.path.rstrip("/") != "/telegram":
            self._reply(404, "not found")
            return
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        if length <= 0 or length > 1024 * 1024:
            self._reply(400, "bad length")
            return
        raw = self.rfile.read(length)

        # The signature is over the exact bytes Cal.com sent, so it is checked
        # before the JSON is parsed rather than after.
        if WEBHOOK_SECRET:
            want = hmac.new(WEBHOOK_SECRET.encode(), raw, hashlib.sha256).hexdigest()
            got = self.headers.get("X-Cal-Signature-256") or ""
            if not hmac.compare_digest(want, got):
                log("rejected a webhook with a bad signature from %s" % self.client_address[0])
                self._reply(401, "bad signature")
                return

        try:
            body = json.loads(raw.decode("utf-8", errors="replace"))
        except ValueError:
            self._reply(400, "bad json")
            return
        if not isinstance(body, dict):
            self._reply(400, "bad json")
            return

        trigger = body.get("triggerEvent", "?")
        # Answered before the send, so a slow or unreachable Telegram cannot
        # make Cal.com's webhook delivery time out and retry.
        self._reply(200)
        text = describe(body)
        if telegram_send(text):
            log("notified: %s" % trigger)


# ── Cron loop ─────────────────────────────────────────────────────────────────
def call(path, style):
    url = APP_URL.rstrip("/") + path
    headers = {"Content-Length": "0"}
    if style == "bearer":
        headers["Authorization"] = "Bearer %s" % CRON_SECRET
    else:
        headers["Authorization"] = CRON_API_KEY

    # POST first, GET on 405. The routes disagree about which verb they
    # export, and the disagreement is not documented anywhere.
    for method in ("POST", "GET"):
        req = urllib.request.Request(url, data=b"" if method == "POST" else None,
                                     headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                r.read(2048)
                return r.status
        except urllib.error.HTTPError as e:
            if e.code == 405 and method == "POST":
                continue
            return e.code
        except Exception as e:                              # noqa: BLE001
            return str(e)
    return "no method accepted"


def cron_loop():
    # Nothing is due at t=0. Waiting one interval first means a restart loop
    # cannot turn into a burst of calls, and gives the app time to finish its
    # migrations before the first request arrives.
    due = {path: time.time() + every for path, every, _ in JOBS}
    last = {}
    while True:
        now = time.time()
        for path, every, style in JOBS:
            if now < due[path]:
                continue
            due[path] = now + every
            result = call(path, style)
            ok = result in (200, 201, 204)
            # Only state changes are logged. A failing minute-by-minute job
            # would otherwise fill the log with the same line 1440 times a
            # day, which is what the watchdog's logrotate config exists to
            # clean up after.
            if last.get(path) != (ok, str(result)):
                last[path] = (ok, str(result))
                if ok:
                    log("cron %s: ok" % path)
                else:
                    log("cron %s: %s" % (path, result))
        time.sleep(5)


def main():
    log("helper starting: app=%s telegram=%s"
        % (APP_URL, "on" if (TG_TOKEN and TG_CHAT) else "off"))
    threading.Thread(target=cron_loop, name="cron", daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
PYEOF
    chmod 644 "${DOCKER_ROOT}/calcom/helper.py"
}

# ── Compose ───────────────────────────────────────────────────────────────────
_calcom_write_compose() {
    local dir="${DOCKER_ROOT}/calcom"
    local sub; sub=$(_calcom_subdomain)
    local url="https://${sub}.${DOMAIN}"
    local disable_signup; disable_signup=$(_calcom_disable_signup)
    local db_url="postgresql://calcom:${CALCOM_DB_PASS}@calcom-db:5432/calcom"

    _calcom_smtp || true
    _calcom_telegram_creds || true

    cat > "${dir}/docker-compose.yml" << DCEOF
# Generated by CoreX. Regenerated on every deploy and repair, so edits here
# are lost; change lib/services/calcom.sh instead.
#
# Mode 0600: this file carries the database password, the session secret, the
# credential encryption key, the mail relay password and the Telegram bot
# token.
services:
  calcom-db:
    image: ${CALCOM_DB_IMAGE}
    container_name: calcom-db
    restart: unless-stopped
    environment:
      POSTGRES_USER: calcom
      POSTGRES_PASSWORD: "${CALCOM_DB_PASS}"
      POSTGRES_DB: calcom
      POSTGRES_INITDB_ARGS: "--data-checksums"
    volumes:
      - ${DATA_ROOT}/calcom-db:/var/lib/postgresql/data
    networks: [proxy-net]
    security_opt: ["no-new-privileges:true"]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U calcom -d calcom"]
      start_period: 30s
      interval: 10s
      timeout: 5s
      retries: 5
    deploy:
      resources:
        limits:
          memory: 768m
          cpus: "1.0"
        reservations:
          memory: 128m

  calcom:
    image: ${CALCOM_IMAGE}
    container_name: calcom
    restart: unless-stopped
    depends_on:
      calcom-db:
        condition: service_healthy
    environment:
      # start.sh passes this to wait-for-it.sh, so it is host:port and not a
      # hostname. Empty means the wait is skipped and the first migration
      # races the database.
      DATABASE_HOST: "calcom-db:5432"
      DATABASE_URL: "${db_url}"
      # Same value: DATABASE_DIRECT_URL exists to bypass a connection pooler,
      # and there is no pooler here.
      DATABASE_DIRECT_URL: "${db_url}"
      # The image was built with http://localhost:3000 baked in as both
      # NEXT_PUBLIC_WEBAPP_URL and BUILT_NEXT_PUBLIC_WEBAPP_URL. start.sh
      # notices this value differs and rewrites the compiled assets on boot,
      # which is why no rebuild is needed for a custom domain.
      NEXT_PUBLIC_WEBAPP_URL: "${url}"
      NEXT_PUBLIC_WEBSITE_URL: "${url}"
      NEXTAUTH_URL: "${url}"
      NEXTAUTH_SECRET: "${CALCOM_NEXTAUTH_SECRET}"
      CALENDSO_ENCRYPTION_KEY: "${CALCOM_ENCRYPTION_KEY}"
      CRON_API_KEY: "${CALCOM_CRON_API_KEY}"
      CRON_SECRET: "${CALCOM_CRON_SECRET}"
      CALCOM_TELEMETRY_DISABLED: "1"
      NEXT_PUBLIC_DISABLE_SIGNUP: "${disable_signup}"
      # ALLOWED_HOSTNAMES is deliberately NOT set. Leaving it empty makes
      # the app log "Match of WEBAPP_URL with ALLOWED_HOSTNAMES failed" at
      # WARN on every page render, and that warning is load-bearing: it is
      # the branch of getOrgSlug that returns null, which is what makes this
      # a plain instance rather than an organization.
      #
      # Setting it to the bare domain silences the warning and breaks every
      # booking page. getOrgSlug looks for an entry the hostname is a
      # subdomain of, so cal.DOMAIN matching DOMAIN leaves the slug "cal",
      # and Cal.com then resolves every profile inside an organization named
      # cal that does not exist. /username answers 404 saying the username
      # is still available, while the account is right there in the
      # database. See CLAUDE.md gotcha #34.
      # Node's process timezone stays UTC, which is what upstream sets and
      # what the schema assumes. Every user picks their own timezone in the
      # app, and the booking pages convert for the visitor, so setting this to
      # the server's zone shifts stored times rather than displayed ones.
      TZ: UTC
      # An empty EMAIL_SERVER_HOST is falsy in JavaScript, so upstream treats
      # it as unset and falls back to /usr/sbin/sendmail, which is not in the
      # image. That is the right shape of failure: mail that cannot be sent
      # errors in the log rather than being silently accepted.
      EMAIL_FROM: "${CALCOM_SMTP_FROM}"
      EMAIL_FROM_NAME: "CoreX Scheduling"
      EMAIL_SERVER_HOST: "${CALCOM_SMTP_HOST}"
      EMAIL_SERVER_PORT: "${CALCOM_SMTP_PORT}"
      EMAIL_SERVER_USER: "${CALCOM_SMTP_USER}"
      EMAIL_SERVER_PASSWORD: "${CALCOM_SMTP_PASSWORD}"
      # Node sizes its heap from the cgroup limit differently across versions,
      # so it is set explicitly and kept under the container limit. n8n
      # crash-looped 33 times on "JavaScript heap out of memory" with
      # OOMKilled false throughout, because Node killed itself rather than the
      # kernel killing the container, so nothing pointed at memory.
      NODE_OPTIONS: "--max-old-space-size=2048"
    networks: [proxy-net]
    security_opt: ["no-new-privileges:true"]
    healthcheck:
      # /api/version is unauthenticated and does no database work, so it
      # answers as soon as the app is actually serving. The image's own
      # healthcheck probes / instead, which redirects and is slower to settle.
      # start_period is long on purpose: the first boot applies several
      # hundred Prisma migrations and seeds the app store before it listens.
      test: ["CMD-SHELL", "wget -q -O /dev/null http://localhost:3000/api/version || exit 1"]
      start_period: 600s
      interval: 30s
      timeout: 15s
      retries: 5
    deploy:
      resources:
        limits:
          memory: 3g
          cpus: "2.0"
        reservations:
          memory: 512m
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.calcom.rule=Host(\`${sub}.${DOMAIN}\`)"
      - "traefik.http.routers.calcom.entrypoints=websecure"
      - "traefik.http.routers.calcom.tls.certresolver=myresolver"
      - "traefik.http.services.calcom.loadbalancer.server.port=3000"

  calcom-helper:
    image: ${CALCOM_HELPER_IMAGE}
    container_name: calcom-helper
    restart: unless-stopped
    depends_on: [calcom]
    command: ["python3", "-u", "/app/helper.py"]
    volumes:
      - ${dir}/helper.py:/app/helper.py:ro
    environment:
      CALCOM_INTERNAL_URL: "http://calcom:3000"
      CALCOM_PUBLIC_URL: "${url}"
      CALCOM_CRON_API_KEY: "${CALCOM_CRON_API_KEY}"
      CALCOM_CRON_SECRET: "${CALCOM_CRON_SECRET}"
      CALCOM_WEBHOOK_SECRET: "${CALCOM_WEBHOOK_SECRET}"
      TELEGRAM_BOT_TOKEN: "${CALCOM_TG_TOKEN}"
      TELEGRAM_CHAT_ID: "${CALCOM_TG_CHAT}"
    networks: [proxy-net]
    # No Traefik labels and no published port. It is reachable only from
    # inside proxy-net, which is where Cal.com posts from; a booking webhook
    # has no reason to be exposed to the internet.
    security_opt: ["no-new-privileges:true"]
    read_only: true
    healthcheck:
      test: ["CMD-SHELL", "python3 -c \"import urllib.request;urllib.request.urlopen('http://127.0.0.1:8080/healthz',timeout=5)\" || exit 1"]
      start_period: 20s
      interval: 60s
      timeout: 10s
      retries: 3
    deploy:
      resources:
        limits:
          memory: 128m
          cpus: "0.25"
        reservations:
          memory: 32m

networks:
  proxy-net: { external: true }
DCEOF

    chmod 600 "${dir}/docker-compose.yml"
}

# ── Telegram webhook registration ─────────────────────────────────────────────
# Cal.com's webhooks are per account and are created through its UI, so a
# fresh instance has none and the helper would never hear about a booking.
# This writes one row per account, pointing at the helper, with a deterministic
# id so it can be re-run as often as you like.
#
# It runs on deploy and on repair, which is what makes the sequence work: sign
# up, then repair, then bookings arrive in Telegram. Before an account exists
# there is nothing to attach a webhook to.
#
# The row is visible and editable in the app under Settings, Developer,
# Webhooks. Deleting it there stops the notifications; a later repair puts it
# back, so set calcom_telegram_hook=off in state.json if you want it gone for
# good.
_calcom_register_hook() {
    local users; users=$(_calcom_user_count)
    case "$users" in
        ""|noschema)
            log_info "Cal.com schema is not ready yet, skipping the Telegram hook"
            return 0 ;;
        0)
            log_info "No Cal.com account yet. Create one, then: corex manage repair calcom"
            return 0 ;;
    esac

    local want=""
    if declare -f state_get >/dev/null 2>&1; then
        want=$(state_get "calcom_telegram_hook" 2>/dev/null)
        [[ "$want" == "null" ]] && want=""
    fi
    if [[ "$want" == "off" ]]; then
        log_info "Cal.com Telegram hook disabled by state.json, leaving it alone"
        return 0
    fi

    _calcom_telegram_creds || {
        log_info "No Telegram credentials yet, so Cal.com booking alerts are not wired up"
        return 0
    }

    # Written as delete-then-insert inside one transaction rather than as an
    # upsert. The row is entirely CoreX's, so there is nothing in it worth
    # preserving, and this needs no conflict target: an upsert has to pick
    # between the primary key and the (userId, subscriberUrl) unique index,
    # and whichever it picks, the other one can still raise.
    # The || clause stays on this line: anything after the << marker is
    # heredoc body, not shell.
    _calcom_psql loud << SQLEOF || { log_warning "Could not write the Cal.com Telegram webhook. Retry with: corex manage repair calcom"; return 0; }
BEGIN;
DELETE FROM "Webhook" WHERE "id" LIKE 'corex-telegram-%';
INSERT INTO "Webhook"
  ("id", "userId", "subscriberUrl", "eventTriggers", "active", "secret", "version")
SELECT 'corex-telegram-' || u.id::text,
       u.id,
       'http://calcom-helper:8080/telegram',
       ARRAY['BOOKING_CREATED','BOOKING_REQUESTED','BOOKING_RESCHEDULED',
             'BOOKING_CANCELLED','BOOKING_REJECTED','MEETING_STARTED']::"WebhookTriggerEvents"[],
       true,
       '${CALCOM_WEBHOOK_SECRET}',
       '2021-10-20'
FROM users u;
COMMIT;
SQLEOF

    local n
    n=$(_calcom_psql << 'SQLEOF'
SELECT count(*) FROM "Webhook" WHERE "id" LIKE 'corex-telegram-%' AND "active";
SQLEOF
    )
    n="${n//[[:space:]]/}"
    [[ -n "$n" && "$n" != "0" ]] \
        && log_success "Telegram booking alerts wired up for ${n} Cal.com account(s)" \
        || log_warning "The Cal.com Telegram hook was not created"
}

# ── Deploy ────────────────────────────────────────────────────────────────────
calcom_deploy() {
    calcom_dirs
    local dir="${DOCKER_ROOT}/calcom"
    local compose="${dir}/docker-compose.yml"
    local sub; sub=$(_calcom_subdomain)

    # Persist a non-default hostname, so a later repair regenerates the same
    # one rather than silently reverting to cal.DOMAIN and breaking every
    # booking link that has been shared.
    if [[ "$sub" != "cal" ]] && declare -f state_set >/dev/null 2>&1; then
        state_set "calcom_subdomain" "$sub" 2>/dev/null || true
    fi

    _calcom_secrets
    _calcom_write_helper
    _calcom_write_compose

    docker network create proxy-net 2>/dev/null || true

    # Pulled, never built. See the note at the top of this file: compiling a
    # Next.js application is what trips this hardware, and the published image
    # can be pointed at any domain at run time.
    #
    # The exit code is checked, unlike the update path used to be: a rate
    # limit, a withdrawn tag and a dropped connection otherwise look exactly
    # like a successful pull (gotcha #26).
    log_step "Pulling Cal.com images (about 1.6GB compressed on first install)..."
    docker compose -f "$compose" pull \
        || log_error "Could not pull the Cal.com images. Check connectivity and: docker compose -f ${compose} pull"

    log_step "Starting the Cal.com database..."
    docker compose -f "$compose" up -d calcom-db \
        || log_error "The Cal.com database would not start"

    local waited=0
    until [[ "$(docker inspect -f '{{.State.Health.Status}}' calcom-db 2>/dev/null)" == "healthy" ]]; do
        sleep 3; waited=$((waited + 3))
        (( waited > 120 )) && log_error "The Cal.com database never became healthy. See: docker logs calcom-db"
    done

    log_step "Starting Cal.com..."
    compose_up_enabled calcom "$compose" \
        || log_warning "Cal.com may not have fully started, check: docker ps"
    state_service_installed "calcom"

    # First boot applies several hundred Prisma migrations and seeds the app
    # store before it listens, which takes minutes on a spinning-rust-speed
    # SSD and looks like a hang. Waiting here means the message below is true
    # when it is printed, and lets the webhook registration run against a
    # schema that exists.
    log_info "Waiting for Cal.com to finish its database migrations (first run takes a few minutes)..."
    waited=0
    local down=0
    until [[ "$(docker inspect -f '{{.State.Health.Status}}' calcom 2>/dev/null)" == "healthy" ]]; do
        # A container that is repeatedly not running is restarting, and no
        # amount of further waiting fixes that. Three samples rather than one,
        # because the gap between a restart and the next start reads as "not
        # running" on a service that is otherwise fine.
        if container_running "calcom"; then
            down=0
        else
            down=$((down + 1))
            if (( down >= 3 )); then
                log_warning "The calcom container is not staying up. See: docker logs calcom"
                break
            fi
        fi
        sleep 10; waited=$((waited + 10))
        if (( waited > 900 )); then
            log_warning "Cal.com is still not answering after 15 minutes. It may still be migrating."
            log_warning "Watch it with: docker logs -f calcom"
            break
        fi
    done

    _calcom_register_hook

    local users; users=$(_calcom_user_count)
    log_success "Cal.com deployed (https://${sub}.${DOMAIN})"
    if [[ "$users" == "0" || "$users" == "noschema" || -z "$users" ]]; then
        echo ""
        echo "  Next, in this order:"
        echo "    1. Open https://${sub}.${DOMAIN} and create your account."
        echo "    2. Run: corex manage repair calcom"
        echo "       That closes public signup and turns on Telegram booking alerts."
        echo ""
    fi
    if [[ -z "${CALCOM_SMTP_HOST:-}" ]]; then
        log_warning "No mail relay is configured, so Cal.com cannot send booking confirmations."
        log_warning "Fix it with: corex manage mail-setup, then: corex manage repair calcom"
    fi
}

calcom_destroy() {
    local compose="${DOCKER_ROOT}/calcom/docker-compose.yml"
    [[ -f "$compose" ]] && docker compose -f "$compose" down
    state_service_removed "calcom"
}

# HEALTHY needs more than a running container here. The app answers HTTP 503
# while it migrates and the helper is what makes bookings visible, so a
# container-only check would call a half-started instance healthy.
calcom_status() {
    local c
    for c in calcom-db calcom calcom-helper; do
        if ! container_running "$c"; then
            container_exists "$c" && { echo "UNHEALTHY"; return 0; }
            echo "MISSING"; return 0
        fi
    done
    # Read the health verdict only on a running container. Docker keeps the
    # last verdict on a stopped one forever, which is what reported ten
    # deliberately-stopped containers as unhealthy (gotcha #29).
    local h
    h=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' calcom 2>/dev/null)
    [[ "$h" == "unhealthy" ]] && { echo "UNHEALTHY"; return 0; }
    echo "HEALTHY"
}

calcom_repair() {
    # Regenerates the compose file, the helper and the Telegram hook before
    # recreating, so a CoreX fix to an environment variable, a limit or a
    # label reaches an install set up months ago (gotcha #22). Data and
    # secrets are untouched.
    calcom_deploy
    local compose="${DOCKER_ROOT}/calcom/docker-compose.yml"
    [[ -f "$compose" ]] && compose_up_enabled calcom "$compose" --force-recreate
}

calcom_credentials() {
    local sub; sub=$(_calcom_subdomain)
    echo "Cal.com: https://${sub}.${DOMAIN}"
    echo "  Create the first account on that page; there is no seeded login."
    echo "  Signup closes by itself once one account exists, on the next repair."
    echo "  Secrets: ${DOCKER_ROOT}/calcom/.secrets.env (0600, back this up)"
    echo "  Pinned image: ${CALCOM_IMAGE}"
    echo ""
    echo "  Booking alerts go to the same Telegram chat as the Kuma alerts."
    echo "  They are wired up by a webhook row per account, which you can see"
    echo "  in the app under Settings, Developer, Webhooks."
}
