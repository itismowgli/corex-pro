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
    except Exception:
        return False
