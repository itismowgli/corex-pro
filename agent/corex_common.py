"""Shared helpers for the CoreX agent and Telegram bot.

Installed to /usr/local/lib/corex/ and imported by both. Kept deliberately
small: anything that grows beyond helpers belongs in the service that uses it.
"""

import json
import os
import re
import sqlite3
import urllib.parse
import urllib.request

AGENT_CONF = "/etc/corex/agent.conf"
DEFAULT_SOCKET = "/run/corex/agent.sock"
KUMA_DB = "/mnt/corex-data/service-data/uptime-kuma/kuma.db"

# A service name, optionally naming one component inside it (the syntax
# `corex manage disable` already accepts, e.g. monitoring:grafana).
SERVICE_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,39}(:[a-z0-9][a-z0-9_-]{0,39})?$")


def read_conf(path=AGENT_CONF):
    """Parse a KEY=value file. Ignores comments, strips one layer of quotes."""
    conf = {}
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, val = line.partition("=")
                conf[key.strip()] = val.strip().strip("\"'")
    except OSError:
        pass
    return conf


def discover_services(repo_root):
    """Valid service names, read from the service modules themselves.

    The same auto-discovery the wizard uses, so a new module in lib/services/
    becomes controllable from the dashboard and Telegram with no change here.
    """
    names = set()
    svc_dir = os.path.join(repo_root, "lib", "services")
    try:
        entries = sorted(os.listdir(svc_dir))
    except OSError:
        return names
    for entry in entries:
        # AppleDouble sidecars are named ._foo.sh and are binary, so they both
        # match the glob and fail to decode. One copied onto a server by a
        # macOS tar crashed the agent on startup before this check existed.
        if not entry.endswith(".sh") or entry.startswith("._"):
            continue
        try:
            # errors="replace" on purpose: this only needs to find one ASCII
            # assignment, and a single undecodable byte anywhere in lib/
            # must never stop the agent from starting.
            with open(os.path.join(svc_dir, entry), encoding="utf-8",
                      errors="replace") as fh:
                for line in fh:
                    m = re.match(r'^SERVICE_NAME="?([a-z0-9_-]+)"?', line)
                    if m:
                        names.add(m.group(1))
                        break
        except OSError:
            continue
    return names


def telegram_creds(conf=None):
    """Bot token and chat id, preferring agent.conf, falling back to Kuma.

    Reusing the credentials already configured in the Uptime Kuma notification
    means there is nothing extra to set up, and it guarantees replies land in
    the same chat the alerts do.
    """
    conf = conf if conf is not None else read_conf()
    token = conf.get("TELEGRAM_BOT_TOKEN", "")
    chat = conf.get("TELEGRAM_CHAT_ID", "")
    if token and chat:
        return token, chat

    db_path = conf.get("KUMA_DB", KUMA_DB)
    try:
        db = sqlite3.connect("file:%s?mode=ro" % db_path, uri=True, timeout=10)
        try:
            rows = db.execute("SELECT config FROM notification").fetchall()
        finally:
            db.close()
    except sqlite3.Error:
        return token, chat

    for (cfg,) in rows:
        try:
            data = json.loads(cfg)
        except (ValueError, TypeError):
            continue
        if data.get("type") != "telegram":
            continue
        token = token or data.get("telegramBotToken", "")
        chat = chat or str(data.get("telegramChatID", ""))
        if token and chat:
            break
    return token, chat


# corex-manage.sh colours its output, and those escape codes are meaningless
# anywhere but a terminal: the browser renders them as literal "[0;32m" and
# Telegram shows the same. Stripped once here, at the point output leaves the
# agent, so no client has to know about it.
_ANSI = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]")


def strip_ansi(text):
    return _ANSI.sub("", text or "")


# Telegram's MarkdownV2 reserved set, escaped so a container name containing a
# hyphen or brackets cannot break the parse and drop the message entirely.
_MDV2 = re.compile(r"([_*\[\]()~`>#+\-=|{}.!\\])")


def md_escape(text):
    return _MDV2.sub(r"\\\1", str(text))


def telegram_send(token, chat, text, markdown=True):
    """Send one message. Returns True on success, never raises."""
    if not token or not chat:
        return False
    payload = {
        "chat_id": chat,
        "text": text,
        "link_preview_options": json.dumps({"is_disabled": True}),
    }
    if markdown:
        payload["parse_mode"] = "MarkdownV2"
    data = urllib.parse.urlencode(payload).encode()
    url = "https://api.telegram.org/bot%s/sendMessage" % token
    try:
        with urllib.request.urlopen(url, data=data, timeout=20) as resp:
            return resp.status == 200
    except Exception as exc:
        # Telegram answers a malformed MarkdownV2 message with a 400 and a
        # description naming the offending offset. Swallowing that made a
        # rejected message indistinguishable from a delivered one, so the
        # reason is surfaced to the caller's log.
        detail = ""
        body = getattr(exc, "read", None)
        if callable(body):
            try:
                detail = body()[:200].decode("utf-8", "replace")
            except Exception:
                detail = ""
        last_send_error[0] = ("%s %s" % (exc, detail)).strip()
        return False


# The reason the most recent send failed, for a caller that wants to log it.
# A single slot rather than a raised exception: a notification that cannot be
# delivered must never take down the thing that was trying to send it.
last_send_error = [""]


# ── Message shape ───────────────────────────────────────────────────────────
#
# Every message the box sends is built here, so the bot, the job notices and
# the Uptime Kuma alerts read as one voice rather than three.
#
# The shape is always the same, because a phone notification shows two lines
# and then stops: a headline that says what happened in plain words, then the
# detail, then what to do about it if there is anything. An operator glancing
# at a lock screen gets the whole point from line one.
#
# Plain words on purpose. "temp DOWN: 83C, over the 80C limit" is a log line,
# and it was being sent to a human. "Running hot: 83C, above the 80C limit" is
# the same fact and needs no decoding.

# One glyph per kind of news. Not decoration: on a phone the icon is what is
# legible before the text is.
ICON = {
    "ok": "\u2705",         # done, and it worked
    "fail": "\U0001f6a8",   # something failed or is down
    "warn": "\u26a0\ufe0f",  # worth knowing, not urgent
    "info": "\u2139\ufe0f",  # a plain answer
    "busy": "\u23f3",       # started, still running
    "up": "\U0001f7e2",     # recovered
}


def message(kind, headline, body="", detail="", footer=""):
    """Build one message in the house style.

    kind      one of ICON
    headline  what happened, in words, no jargon and no log prefixes
    body      a sentence or two of context
    detail    verbatim output, rendered as a code block and trimmed
    footer    the single next step, if there is an obvious one
    """
    parts = ["%s *%s*" % (ICON.get(kind, ICON["info"]), md_escape(headline))]
    if body:
        parts.append("")
        parts.append(md_escape(body))
    if detail:
        parts.append("")
        parts.append(code_block(detail))
    if footer:
        parts.append("")
        parts.append("_%s_" % md_escape(footer))
    return "\n".join(parts)


def code_block(text, limit=1200, keep="both"):
    """Verbatim output, fenced for Telegram and trimmed if it is long.

    keep="tail" for a command someone asked to run: the error and the summary
    are both at the bottom, so the end is what they wanted.

    keep="both" for a notice they did not ask for: the head says what was
    being attempted and the tail says how it went, and a notification arriving
    unprompted needs both to make sense on its own.

    A backtick inside a fenced block terminates it, so it is replaced rather
    than escaped. Escaping the way md_escape does would fill the block with
    visible backslashes, since MarkdownV2 treats almost nothing as special in
    here.
    """
    text = strip_ansi(text or "").strip()
    if not text:
        return ""
    if len(text) > limit:
        if keep == "tail":
            text = "... trimmed ...\n" + text[-limit:].lstrip()
        else:
            head = text[: limit // 2].rstrip()
            tail = text[-(limit // 2):].lstrip()
            text = "%s\n... trimmed ...\n%s" % (head, tail)
    text = text.replace("\\", "\\\\").replace("`", "'")
    return "```\n%s\n```" % text


def human_duration(seconds):
    """A duration as someone would say it out loud."""
    try:
        seconds = int(seconds)
    except (TypeError, ValueError):
        return ""
    if seconds < 60:
        return "%d second%s" % (seconds, "" if seconds == 1 else "s")
    if seconds < 3600:
        m, s = divmod(seconds, 60)
        return "%d minute%s" % (m, "" if m == 1 else "s") + (" %ds" % s if s else "")
    h, rem = divmod(seconds, 3600)
    return "%d hour%s %d minutes" % (h, "" if h == 1 else "s", rem // 60)
