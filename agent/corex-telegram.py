#!/usr/bin/env python3
"""CoreX Telegram control bot.

Long-polls the Telegram Bot API for commands and hands them to the action
agent over its unix socket.

WHY LONG POLLING
    A webhook would need an inbound HTTPS route, which contradicts the whole
    premise of CoreX running behind a residential connection with no router
    configuration. getUpdates opens an outbound connection and needs nothing
    forwarded.

TRUST MODEL, WHICH IS THE IMPORTANT PART
    Anyone who can post in the authorised chat can start and stop services.
    Two things follow, and both are enforced here rather than assumed:

    - Only the configured chat id is accepted. Every other sender is logged
      and ignored, with no reply, so the bot does not confirm its own
      existence to a stranger who finds it.
    - The bot is not root. It runs as corex-bot, whose only privilege is
      membership of the corex-agent group, which lets it write to one socket
      that accepts a fixed list of reversible actions. It cannot remove a
      service, nuke an install, read the credentials file, or touch the Docker
      socket. This process parses untrusted input from the internet, so it
      holds nothing worth stealing.

    Destructive operations are deliberately unreachable from here. If you want
    to remove a service or change the domain, that is an SSH job.
"""

import json
import os
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, "/usr/local/lib/corex")
import corex_common as cc  # noqa: E402

CONF_PATH = os.environ.get("COREX_TELEGRAM_CONF", "/etc/corex/telegram.conf")
CONF = cc.read_conf(CONF_PATH)
AGENT_CONF = cc.read_conf()

BOT_TOKEN = CONF.get("TELEGRAM_BOT_TOKEN", "")
CHAT_ID = str(CONF.get("TELEGRAM_CHAT_ID", ""))
SOCKET_PATH = AGENT_CONF.get("AGENT_SOCKET", cc.DEFAULT_SOCKET)
TOKEN_FILE = AGENT_CONF.get("AGENT_TOKEN_FILE", "/etc/corex/agent.token")
OFFSET_FILE = CONF.get("TELEGRAM_OFFSET_FILE", "/var/lib/corex/telegram.offset")
LOG = CONF.get("TELEGRAM_LOG", "/var/log/corex-telegram.log")
POLL_TIMEOUT = 50

# A command older than this is discarded unexecuted. Telegram holds undelivered
# updates for 24 hours, so without this a bot that was down for a day would
# come back and replay every queued "stop" at once.
MAX_MESSAGE_AGE = 600

ACTION_WORDS = {
    "start": "start", "up": "start", "enable": "start",
    "stop": "stop", "down": "stop", "disable": "stop",
    "restart": "restart", "bounce": "restart",
    "repair": "repair", "fix": "repair",
    "update": "update", "upgrade": "update",
    "logs": "logs", "log": "logs",
}
INFO_WORDS = {"status", "list", "health", "storage", "cleanup"}

HELP = """*CoreX control*

`status` services and health
`health` host: temperature, disks, dpkg
`storage` disk usage by service
`list` every available service

`start <service>`
`stop <service>`
`restart <service>`
`repair <service>` regenerate config and recreate
`update <service>` or `update all`
`logs <service> [lines]`
`cleanup` reclaim Docker space

Long jobs reply straight away and send a second message when they finish.
Removing services, changing the domain and uninstalling are not available
here on purpose."""


def say(msg):
    line = "%s telegram: %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S%z"), msg)
    try:
        with open(LOG, "a", encoding="utf-8") as fh:
            fh.write(line)
    except OSError:
        pass


# ── Agent client ────────────────────────────────────────────────────────────

def agent_call(payload, timeout=120):
    try:
        with open(TOKEN_FILE, encoding="utf-8") as fh:
            payload["token"] = fh.read().strip()
    except OSError:
        return {"ok": False, "error": "cannot read the agent token"}

    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        sock.connect(SOCKET_PATH)
    except OSError as exc:
        return {"ok": False, "error": "agent unreachable (%s)" % exc}

    try:
        sock.sendall((json.dumps(payload) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = sock.recv(65536)
            if not chunk:
                break
            buf += chunk
            if len(buf) > 4 * 1024 * 1024:
                break
    except OSError as exc:
        return {"ok": False, "error": "agent call failed (%s)" % exc}
    finally:
        sock.close()

    try:
        return json.loads(buf.decode("utf-8", "replace") or "{}")
    except ValueError:
        return {"ok": False, "error": "malformed agent reply"}


# ── Telegram client ─────────────────────────────────────────────────────────

def api(method, params=None, timeout=70):
    url = "https://api.telegram.org/bot%s/%s" % (BOT_TOKEN, method)
    data = urllib.parse.urlencode(params or {}).encode()
    try:
        with urllib.request.urlopen(url, data=data, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8", "replace"))
    except (urllib.error.URLError, OSError, ValueError) as exc:
        return {"ok": False, "description": str(exc)}


def reply(text):
    cc.telegram_send(BOT_TOKEN, CHAT_ID, text)


def code_block(text, limit=3200):
    """Wrap command output for Telegram, truncating from the top.

    The tail is what matters in command output: the error and the summary line
    are at the end, so a message that must be cut keeps the end and says so.
    """
    text = (text or "").strip() or "(no output)"
    if len(text) > limit:
        text = "... truncated ...\n" + text[-limit:]
    return "```\n%s\n```" % text.replace("\\", "\\\\").replace("`", "'")


# ── Offset persistence ──────────────────────────────────────────────────────

def read_offset():
    try:
        with open(OFFSET_FILE, encoding="utf-8") as fh:
            return int(fh.read().strip())
    except (OSError, ValueError):
        return None


def write_offset(value):
    try:
        os.makedirs(os.path.dirname(OFFSET_FILE), exist_ok=True)
        tmp = OFFSET_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(str(value))
        os.replace(tmp, OFFSET_FILE)
    except OSError as exc:
        say("cannot persist offset: %s" % exc)


def skip_backlog():
    """Advance past anything already queued, without executing it.

    Without this, a bot that has been down comes back and runs every command
    sent meanwhile, in order, which is how you discover the backlog contained
    a "stop nextcloud" from yesterday.
    """
    res = api("getUpdates", {"offset": -1, "timeout": 0}, timeout=30)
    updates = res.get("result") or []
    if updates:
        last = updates[-1]["update_id"]
        write_offset(last + 1)
        say("discarded backlog up to update %d" % last)
        return last + 1
    write_offset(0)
    return 0


# ── Command handling ────────────────────────────────────────────────────────

def handle_command(text):
    words = text.strip().split()
    if not words:
        return
    verb = words[0].lstrip("/").lower()
    # Telegram appends @botname to commands in groups.
    verb = verb.split("@", 1)[0]
    arg = words[1].lower() if len(words) > 1 else ""

    if verb in ("help", "start_help", "commands"):
        reply(HELP)
        return
    if verb == "start" and not arg:
        # Telegram sends a bare /start when a chat is first opened, which is
        # not a request to start a service.
        reply(HELP)
        return

    if verb in INFO_WORDS:
        res = agent_call({"action": verb})
        if verb == "cleanup":
            reply("\U0001f9f9 *cleanup started*" if res.get("ok")
                  else "\U0001f6a8 " + cc.md_escape(res.get("error", "failed")))
            return
        if res.get("ok"):
            reply("*%s*\n%s" % (cc.md_escape(verb), code_block(res.get("output"))))
        else:
            reply("\U0001f6a8 " + cc.md_escape(res.get("error", "failed")))
        return

    if verb not in ACTION_WORDS:
        reply("Unknown command: " + cc.md_escape(words[0]) +
              "\nSend `help` for the list\\.")
        return

    action = ACTION_WORDS[verb]
    if not arg:
        reply("Which service? For example: `%s nextcloud`" % cc.md_escape(action))
        return

    if action == "logs":
        tail = 40
        if len(words) > 2 and words[2].isdigit():
            tail = int(words[2])
        res = agent_call({"action": "logs", "service": arg, "tail": tail})
        if res.get("ok"):
            reply("*logs %s*\n%s" % (cc.md_escape(arg), code_block(res.get("output"))))
        else:
            reply("\U0001f6a8 " + cc.md_escape(res.get("error", "failed")))
        return

    res = agent_call({"action": action, "service": arg})
    if res.get("ok"):
        reply("⏳ *%s* started\nA second message follows when it finishes\\."
              % cc.md_escape("%s %s" % (action, arg)))
    else:
        reply("\U0001f6a8 " + cc.md_escape(res.get("error", "failed")))


def main():
    if not BOT_TOKEN or not CHAT_ID:
        say("no bot token or chat id in %s; exiting" % CONF_PATH)
        return 1

    offset = read_offset()
    if offset is None:
        offset = skip_backlog()

    say("polling as chat %s, agent at %s" % (CHAT_ID, SOCKET_PATH))
    backoff = 5
    while True:
        res = api("getUpdates", {"offset": offset, "timeout": POLL_TIMEOUT})
        if not res.get("ok"):
            say("getUpdates failed: %s" % res.get("description"))
            time.sleep(backoff)
            backoff = min(backoff * 2, 300)
            continue
        backoff = 5

        for update in res.get("result") or []:
            offset = update["update_id"] + 1
            write_offset(offset)

            msg = update.get("message") or update.get("edited_message") or {}
            chat = str((msg.get("chat") or {}).get("id", ""))
            text = msg.get("text") or ""
            if not text:
                continue

            if chat != CHAT_ID:
                say("ignored message from unauthorised chat %s" % chat)
                continue
            if time.time() - int(msg.get("date", 0)) > MAX_MESSAGE_AGE:
                say("ignored stale command: %r" % text[:80])
                continue

            say("command from %s: %r" % (chat, text[:120]))
            try:
                handle_command(text)
            except Exception as exc:
                say("handler error: %r" % (exc,))
                reply("\U0001f6a8 internal error handling that command")


if __name__ == "__main__":
    sys.exit(main() or 0)
