#!/usr/bin/env python3
"""Manage dashboard accounts from the command line, as root.

WHY THIS EXISTS BEFORE THE WEB LOGIN DOES
    A control panel whose own login breaks is a lockout, and the dashboard is
    the thing you open when the box is already in trouble. So the way in from
    SSH is built first and is never allowed to depend on the web tier: this
    script talks to /etc/corex/dashboard-users.json directly, needs no
    container, no agent and no network, and `disable-auth` puts the old
    Traefik basic auth back if the application login ever goes wrong.

    Reached as `corex manage dashboard-user ...`, which is what the
    documentation points at. Running it directly works too.
"""

import argparse
import getpass
import os
import sys
import time

sys.path.insert(0, "/usr/local/lib/corex")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import corex_users as cu  # noqa: E402


def fail(msg):
    sys.stderr.write("[FAIL] %s\n" % msg)
    raise SystemExit(1)


def ok(msg):
    print("[  OK] %s" % msg)


def ask_password(args, prompt="Password: "):
    """A password from --password-stdin, or asked for twice on a terminal."""
    if args.password_stdin:
        password = sys.stdin.readline().rstrip("\n")
        if not password:
            fail("no password arrived on stdin")
        return password
    if not sys.stdin.isatty():
        fail("no terminal to ask on. Pipe the password in and pass --password-stdin.")
    while True:
        first = getpass.getpass(prompt)
        if first != getpass.getpass("Repeat: "):
            print("They do not match. Again.")
            continue
        try:
            cu.check_password(first)
        except cu.UserError as exc:
            print(str(exc))
            continue
        return first


def when(ts):
    if not ts:
        return "-"
    return time.strftime("%Y-%m-%d %H:%M", time.localtime(int(ts)))


# ── Subcommands ─────────────────────────────────────────────────────────────

def cmd_list(args, doc):
    users = doc.get("users", {})
    if not users:
        print("No dashboard accounts yet. Create one with:")
        print("  sudo corex manage dashboard-user add <username>")
        return
    print("%-20s %-24s %-26s %-6s %s"
          % ("USERNAME", "NAME", "EMAIL", "2FA", "PASSWORD SET"))
    for name in sorted(users):
        user = users[name]
        totp = "on" if (user.get("totp") or {}).get("enabled") else "off"
        print("%-20s %-24s %-26s %-6s %s"
              % (name, user.get("display_name", "")[:24],
                 user.get("email", "") or "-", totp,
                 when(user.get("password_changed"))))
    print()
    print("Recovery mail needs an address on the account and a relay at "
          "/etc/corex/smtp.conf.")


def cmd_add(args, doc):
    password = ask_password(args, "Password for %s: " % args.username)
    cu.add_user(doc, args.username, password,
                email=args.email or "", display_name=args.name or "")
    cu.save(doc, args.file)
    ok("created %s" % args.username)
    if not args.email:
        print("      No email address, so this account cannot use the "
              "forgotten-password link. Add one with:")
        print("        sudo corex manage dashboard-user email %s you@example.com"
              % args.username)


def cmd_passwd(args, doc):
    cu.get_user(doc, args.username)
    password = ask_password(args, "New password for %s: " % args.username)
    cu.set_password(doc, args.username, password)
    cu.save(doc, args.file)
    ok("password changed for %s" % args.username)
    print("      Sessions are held in the dashboard's memory and are not "
          "revoked by this. Restart it to sign everyone out:")
    print("        docker restart corex-dashboard")


def cmd_name(args, doc):
    user = cu.get_user(doc, args.username)
    user["display_name"] = args.display_name[:64]
    cu.save(doc, args.file)
    ok("%s is now shown as %s" % (args.username, user["display_name"]))


def cmd_email(args, doc):
    user = cu.get_user(doc, args.username)
    user["email"] = cu.validate_email(args.address)
    cu.save(doc, args.file)
    ok("%s now receives recovery mail at %s" % (args.username, args.address))


def cmd_totp_reset(args, doc):
    cu.reset_totp(doc, args.username)
    cu.save(doc, args.file)
    ok("two-factor authentication turned off for %s" % args.username)
    print("      Sign in with the password alone, then enrol again from the "
          "Account tab.")


def cmd_remove(args, doc):
    cu.remove_user(doc, args.username)
    cu.save(doc, args.file)
    ok("removed %s" % args.username)


def cmd_show(args, doc):
    user = cu.get_user(doc, args.username)
    totp = user.get("totp") or {}
    codes = totp.get("recovery") or []
    print("username        %s" % args.username)
    print("display name    %s" % user.get("display_name", ""))
    print("email           %s" % (user.get("email") or "(none)"))
    print("created         %s" % when(user.get("created")))
    print("password set    %s" % when(user.get("password_changed")))
    print("two-factor      %s" % ("on" if totp.get("enabled") else "off"))
    if codes:
        left = sum(1 for c in codes if not c.get("used"))
        print("recovery codes  %d of %d unused" % (left, len(codes)))
    reset = user.get("reset") or {}
    if reset.get("expires", 0) > time.time():
        print("reset code      outstanding, expires %s" % when(reset["expires"]))


def main():
    parser = argparse.ArgumentParser(
        prog="corex manage dashboard-user",
        description="Manage the accounts that can sign in to the CoreX dashboard.")
    parser.add_argument("--file", default=cu.USERS_FILE,
                        help="user store to operate on (default %s)" % cu.USERS_FILE)
    sub = parser.add_subparsers(dest="cmd", required=True)

    def with_password(p):
        p.add_argument("--password-stdin", action="store_true",
                       help="read the password from stdin instead of asking")

    p = sub.add_parser("list", help="list accounts")
    p.set_defaults(func=cmd_list)

    p = sub.add_parser("add", help="create an account")
    p.add_argument("username")
    p.add_argument("--email", help="address for password recovery")
    p.add_argument("--name", help="display name")
    with_password(p)
    p.set_defaults(func=cmd_add)

    p = sub.add_parser("passwd", help="change an account's password")
    p.add_argument("username")
    with_password(p)
    p.set_defaults(func=cmd_passwd)

    p = sub.add_parser("name", help="change an account's display name")
    p.add_argument("username")
    p.add_argument("display_name")
    p.set_defaults(func=cmd_name)

    p = sub.add_parser("email", help="set the recovery address")
    p.add_argument("username")
    p.add_argument("address")
    p.set_defaults(func=cmd_email)

    p = sub.add_parser("totp-reset", help="turn off two-factor for an account")
    p.add_argument("username")
    p.set_defaults(func=cmd_totp_reset)

    p = sub.add_parser("remove", help="delete an account")
    p.add_argument("username")
    p.set_defaults(func=cmd_remove)

    p = sub.add_parser("show", help="show one account in detail")
    p.add_argument("username")
    p.set_defaults(func=cmd_show)

    args = parser.parse_args()
    if not hasattr(args, "password_stdin"):
        args.password_stdin = False

    if os.geteuid() != 0 and args.file == cu.USERS_FILE:
        fail("run as root: the user store is 0600 root")

    try:
        doc = cu.load(args.file)
        args.func(args, doc)
    except cu.UserError as exc:
        fail(str(exc))


if __name__ == "__main__":
    main()
