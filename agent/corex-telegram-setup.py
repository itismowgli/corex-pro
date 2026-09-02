#!/usr/bin/env python3
"""Write /etc/corex/telegram.conf from the Uptime Kuma notification config.

Reusing the bot token and chat id already configured in Kuma means the control
bot needs no separate setup, and replies land in the same chat as the alerts.

The token is copied into a file the bot can read rather than the bot reading
Kuma's database: the bot parses untrusted input from the internet, so it is
kept away from the database that holds every notification credential.

Never prints the token. Exits 3 if Kuma has no Telegram notification.
"""

import os
import sys

sys.path.insert(0, "/usr/local/lib/corex")
import corex_common as cc  # noqa: E402

CONF = "/etc/corex/telegram.conf"

TEMPLATE = """# CoreX Telegram control bot.
#
# Commands are accepted ONLY from TELEGRAM_CHAT_ID. Anyone who can post in
# that chat can start, stop, restart, repair and update services, so treat it
# the way you would treat shell access.
#
# Copied from the Uptime Kuma Telegram notification at install time. Edit here
# to point the bot at a different chat; this file is not overwritten once
# TELEGRAM_BOT_TOKEN is set.
TELEGRAM_BOT_TOKEN={token}
TELEGRAM_CHAT_ID={chat}
TELEGRAM_OFFSET_FILE=/var/lib/corex-bot/telegram.offset
TELEGRAM_LOG=/var/log/corex-telegram.log
"""


def main():
    db = sys.argv[1] if len(sys.argv) > 1 else cc.KUMA_DB

    existing = cc.read_conf(CONF)
    if existing.get("TELEGRAM_BOT_TOKEN") and existing.get("TELEGRAM_CHAT_ID"):
        print("telegram.conf already configured, left unchanged", file=sys.stderr)
        return 0

    token, chat = cc.telegram_creds({"KUMA_DB": db})
    if not token or not chat:
        return 3

    fd = os.open(CONF, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o640)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(TEMPLATE.format(token=token, chat=chat))
    print("telegram.conf written for chat %s" % chat, file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
