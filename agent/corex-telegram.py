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
import re
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

# MarkdownV2 reserves . ! - ( ) [ ] and more, and Telegram rejects the entire
# message with HTTP 400 if one is unescaped, so `help` silently sent nothing.
# Escapes here are deliberate. Inside a `code span` the reserved characters are
# literal, which is why <service> and [lines] need none.
HELP = (
    "\U0001f6e0 *CoreX control*\n"
    "\n"
    "*Look*\n"
    "`status` every service and its state\n"
    "`health` temperature, disks, dpkg, last shutdown\n"
    "`storage` disk usage by service\n"
    "`list` what is installed and what is not\n"
    "`logs <service> [lines]`\n"
    "\n"
    "*Act*\n"
    "`start <service>`\n"
    "`stop <service>`\n"
    "`restart <service>` its containers only\n"
    "`repair <service>` regenerate config and recreate\n"
    "`update <service>` or `update all`\n"
    "`cleanup` reclaim Docker space\n"
    "\n"
    "Long jobs reply at once, then send a second message when they finish\\.\n"
    "\n"
    "Removing a service, adding one, changing the domain and uninstalling are "
    "not reachable from here on purpose, so a lost phone cannot destroy "
    "anything\\. Those stay on SSH\\."
)


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
    """Send one message, keeping it inside Telegram's 4096-character limit.

    Truncating blindly can cut a message in the middle of a code fence, which
    leaves MarkdownV2 unbalanced and makes Telegram reject the whole thing, so
    an unclosed fence is closed after the cut.
    """
    limit = 3900
    if len(text) > limit:
        text = text[:limit].rstrip() + "\n\n... truncated ..."
        if text.count("```") % 2:
            text += "\n```"
    if not cc.telegram_send(BOT_TOKEN, CHAT_ID, text):
        # A failed send was completely invisible: the command was logged as
        # received, nothing arrived on the phone, and there was no record of an
        # attempt at all. That is the hardest possible fault to diagnose, and
        # it happened. Telegram's own reason is carried back in
        # cc.last_send_error, and it names the offending offset for a
        # MarkdownV2 message it would not parse.
        say("reply failed: %s | first 120 chars: %r"
            % (cc.last_send_error[0] or "no reason given", text[:120]))


def code_block(text, limit=3000):
    """Terminal output for a command someone asked to run.

    Keeps the tail: the error and the summary line are both at the bottom. The
    shared helper does the fencing, so this and the agent's own notices cannot
    drift apart on how they trim.
    """
    return cc.code_block(text, limit, keep="tail") or "```\n(no output)\n```"


# ── Reply formatting ────────────────────────────────────────────────────────
#
# corex-manage.sh writes for an 80-column terminal: box-drawing rules, aligned
# columns, and lines well over 60 characters. Telegram renders none of that
# well. A code block does not wrap, so a wide line becomes a horizontal
# scrollbar on a phone, and the rules turn into a row of dashes carrying no
# information. So each command's output is reshaped here rather than forwarded.
#
# Only genuine terminal output stays in a code block: `logs`, where alignment
# is the point and monospace is correct.

# Box-drawing rules and the report titles, which are redundant once the reply
# has its own heading.
_NOISE = re.compile(r"^[\s\u2500\u2501\u2502\u2508=_-]*$")


def wrap_names(names, per_line=4):
    """Comma-joined names, wrapped so no line overflows a phone screen."""
    out, row = [], []
    for name in names:
        row.append(name)
        if len(row) == per_line:
            out.append(", ".join(row))
            row = []
    if row:
        out.append(", ".join(row))
    return cc.md_escape(",\n".join(out))


def vitals_line():
    """A one-line reading of the machine, for the top of `status`.

    `status` answers "are my services up" and `health` answers "is the machine
    in trouble", and on a phone nobody wants to ask twice. The three numbers
    that decide whether anything else matters go at the top: heat, because this
    hardware trips at TjMax with nothing in any log; memory; and the fuller
    disk. Everything else stays behind `health`.

    Returns an empty string if the agent cannot answer, because a missing
    header must not cost the reader the service list they asked for.
    """
    res = agent_call({"action": "metrics", "sizes": False}, timeout=30)
    if not res.get("ok"):
        return ""
    m = res.get("metrics") or {}
    cpu = m.get("cpu") or {}
    mem = m.get("memory") or {}
    thermal = m.get("thermal") or {}

    bits = []
    temp = cpu.get("temp_c")
    if temp is not None:
        warn = thermal.get("warn_c") or 80
        mark = " (hot)" if temp >= warn else ""
        bits.append("%.0fC%s" % (temp, mark))
    load = cpu.get("load") or []
    if load:
        bits.append("load %.2f" % load[0])
    if mem.get("total_mb"):
        bits.append("RAM %d%%" % round(mem["used_mb"] * 100.0 / mem["total_mb"]))
    disks = m.get("disks") or []
    if disks:
        worst = max(disks, key=lambda d: d.get("pct", 0))
        bits.append("%s %.0f%% full" % (worst.get("label", "disk"), worst.get("pct", 0)))

    shed = thermal.get("shed") or []
    if shed:
        bits.append("%d container(s) shed for heat" % len(shed))
    return ", ".join(bits)


def fmt_status(output):
    """`status --plain` is tab separated, so it can be grouped properly."""
    groups = {}
    for line in (output or "").splitlines():
        parts = line.split("\t")
        if len(parts) != 2:
            continue
        groups.setdefault(parts[1].strip(), []).append(parts[0].strip())

    if not groups:
        return "\U0001f4ca *Services*\n\nNothing reported\\."

    healthy = sorted(groups.pop("HEALTHY", []))
    disabled = sorted(groups.pop("DISABLED", []))
    summary = []
    if healthy:
        summary.append("%d healthy" % len(healthy))
    problems = sum(len(v) for v in groups.values())
    if problems:
        summary.append("%d needing attention" % problems)
    if disabled:
        summary.append("%d disabled" % len(disabled))

    lines = ["\U0001f4ca *Services*", cc.md_escape(", ".join(summary))]
    vitals = vitals_line()
    if vitals:
        lines += ["", "\U0001fa7a *The machine*", cc.md_escape(vitals),
                  cc.md_escape("Send health for the full hardware report.")]

    # Problems first and named individually, because those are the ones worth
    # reading. Everything healthy is collapsed into one block.
    for state in sorted(groups):
        lines += ["", "\U0001f6a8 *%s*" % cc.md_escape(state.title()),
                  wrap_names(sorted(groups[state]))]
    if disabled:
        lines += ["", "\u23f8 *Disabled*", wrap_names(disabled)]
    if healthy:
        lines += ["", "✅ *Healthy*", wrap_names(healthy)]
    return "\n".join(lines)


_LIST_RE = re.compile(r"^\s*(\S+)\s+(\S+)\s+\[(installed|available)\]\s+(.*)$")


def fmt_list(output):
    installed, available = [], []
    for line in (output or "").splitlines():
        m = _LIST_RE.match(line)
        if not m:
            continue
        (installed if m.group(3) == "installed" else available).append(m.group(1))

    if not installed and not available:
        return "\U0001f4e6 *Services*\n\nCould not read the service list\\."

    lines = ["\U0001f4e6 *Services*"]
    if installed:
        lines += ["", "✅ *Installed* \\(%d\\)" % len(installed),
                  wrap_names(sorted(installed))]
    if available:
        lines += ["", "\u25ab *Not installed* \\(%d\\)" % len(available),
                  wrap_names(sorted(available))]
    # Installing a service is not one of the actions the agent will perform, so
    # say where it is done rather than leaving the reader to try `add` and be
    # told it is unknown.
    lines += ["", cc.md_escape("Installing one is an SSH job: "
                               "sudo bash corex-manage.sh add <service>")]
    return "\n".join(lines)


def fmt_report(heading, output):
    """Reflow a terminal report for a phone.

    Two kinds of content arrive mixed together. Labelled prose lines
    ("CPU temperature: 66C, OK") read best as text, because Telegram wraps
    text and a code block does not. Tables ("Service Data:", "Docker Usage:")
    only make sense with their columns intact, so those go in a code block.
    The rule is the line ending in a colon: it starts a table, and everything
    indented under it belongs to that table.

    The report's own title and its box-drawing rules are dropped, since the
    reply already has a heading and a rule carries no information here.
    """
    parts = [heading]
    prose, table = [], []
    table_indent = None

    def flush_prose():
        if prose:
            parts.append(cc.md_escape("\n".join(prose)))
            prose.clear()

    def flush_table():
        if table:
            parts.append(code_block("\n".join(table), 1500))
            table.clear()

    seen_content = False
    for raw in (output or "").splitlines():
        if not raw.strip() or _NOISE.match(raw):
            continue
        body = raw.rstrip()
        text = body.strip()
        indent = len(body) - len(body.lstrip())

        # The first line is the report's own title when it carries no label.
        if not seen_content and ":" not in text:
            continue
        seen_content = True

        # A table continues while its rows are indented under the header, or
        # sit at column zero. The second case is not a quirk to tolerate but
        # the normal shape of a piped-in table: corex-manage inserts
        # `docker system df` output verbatim, so those rows are unindented
        # while the header above them is not.
        if table_indent is not None and (indent > table_indent or indent == 0):
            # Trim the common prefix rather than stripping, or the columns
            # collapse. Only trim what is actually there.
            prefix = " " * (table_indent + 2)
            table.append(body[len(prefix):] if body.startswith(prefix) else body)
            continue

        table_indent = None
        flush_table()

        if text.endswith(":"):
            flush_prose()
            parts.append("*%s*" % cc.md_escape(text[:-1]))
            table_indent = indent
            continue

        prose.append(text)

    flush_prose()
    flush_table()
    if len(parts) == 1:
        parts.append(cc.md_escape("(no output)"))
    return "\n\n".join(parts)


def fmt_logs(service, output):
    """Container logs stay monospace, but each container gets its own block."""
    chunks = (output or "").split("=== ")
    parts = ["\U0001f4c4 *logs %s*" % cc.md_escape(service)]
    for chunk in chunks:
        if not chunk.strip():
            continue
        head, _, body = chunk.partition(" ===\n")
        if not head:
            parts.append(code_block(chunk, 1200))
            continue
        parts.append("*%s*" % cc.md_escape(head.strip()))
        parts.append(code_block(body, 1200))
    return "\n".join(parts)


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
        if not res.get("ok") and verb != "cleanup":
            reply("\U0001f6a8 " + cc.md_escape(res.get("error", "failed")))
            return
        out = res.get("output", "")
        # Each of these is reshaped rather than forwarded, because the
        # terminal report it comes from is 80 columns of aligned text and
        # box-drawing rules that a phone cannot render usefully.
        if verb == "status":
            reply(fmt_status(out))
        elif verb == "list":
            reply(fmt_list(out))
        elif verb == "health":
            reply(fmt_report("\U0001fa7a *Host health*", out))
        elif verb == "storage":
            reply(fmt_report("\U0001f4be *Storage*", out))
        elif verb == "cleanup":
            if res.get("ok"):
                reply("\U0001f9f9 *cleanup*\n" + cc.md_escape(
                    "Started. I will tell you when it finishes."))
            else:
                reply("\U0001f6a8 " + cc.md_escape(res.get("error", "failed")))
        return
        if res.get("ok"):
            reply("*%s*\n%s" % (cc.md_escape(verb), code_block(res.get("output"))))
        else:
            reply("\U0001f6a8 " + cc.md_escape(res.get("error", "failed")))
        return

    if verb not in ACTION_WORDS:
        reply("\U0001f937 " + cc.md_escape('I do not know "%s".' % words[0])
              + "\n\nSend `help` for the list\\.")
        return

    action = ACTION_WORDS[verb]
    if not arg:
        reply(cc.message("info", "Which service?",
                         "Name one after the command, like this:",
                         detail="%s nextcloud" % action))
        return

    if action == "logs":
        tail = 40
        if len(words) > 2 and words[2].isdigit():
            tail = min(200, int(words[2]))
        res = agent_call({"action": "logs", "service": arg, "tail": tail})
        if res.get("ok"):
            reply(fmt_logs(arg, res.get("output")))
        else:
            reply("\U0001f6a8 " + cc.md_escape(res.get("error", "failed")))
        return

    res = agent_call({"action": action, "service": arg})
    if res.get("ok"):
        reply("⏳ *%s*\n%s" % (
            cc.md_escape("%s %s" % (action, arg)),
            cc.md_escape("Started. I will tell you when it finishes.")))
    else:
        reply("\U0001f6a8 *%s*\n%s" % (
            cc.md_escape("%s %s" % (action, arg)),
            cc.md_escape(res.get("error", "failed"))))


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
