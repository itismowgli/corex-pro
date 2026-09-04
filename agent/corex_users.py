"""The dashboard's user store.

WHERE THIS LIVES AND WHY
    /etc/corex/dashboard-users.json, mode 0600 root. Not state.json: that file
    is 0644 and bind-mounted into the dashboard container, and state_set
    already refuses secret-looking keys for exactly this reason (gotcha #24).

    The dashboard container runs as nobody and cannot read this file. It
    reaches it through the agent's users-get and users-put actions, and does
    the hashing itself in Go. Only one thing stays entirely on this side: the
    password reset mail, because /etc/corex/smtp.conf is 0600 root and the web
    tier must never learn the relay's credentials.

THE HASH RECORD
    Every secret in this file, password, recovery code and reset token alike,
    is stored as the same self-describing object:

        {"algo": "pbkdf2-sha256", "iterations": N,
         "salt": "<base64>", "hash": "<base64>"}

    Self-describing because two implementations read it, this one and the Go
    one in dashboard/auth.go, and an iteration count agreed by convention
    rather than written down is a bug waiting for whichever side changes
    first. It also lets a recovery code, which carries 50 bits of its own
    entropy, use a cheaper count than a password without either side needing
    to know which is which.
"""

import base64
import hashlib
import json
import os
import re
import secrets
import smtplib
import time
from email.message import EmailMessage
from email.utils import formatdate, make_msgid

USERS_FILE = "/etc/corex/dashboard-users.json"
SMTP_CONF = "/etc/corex/smtp.conf"

ALGO = "pbkdf2-sha256"
DK_LEN = 32

# OWASP's 2023 floor for PBKDF2-HMAC-SHA256. About a quarter of a second on
# the mobile CPUs CoreX targets, which is the point: it is the login path, and
# it is rate limited.
PASSWORD_ITERATIONS = 600000
# Recovery codes and reset tokens are machine-generated with 50 and 40 bits of
# entropy, so the iteration count is not what is protecting them, and up to ten
# recovery hashes may be checked in one attempt.
TOKEN_ITERATIONS = 120000

RESET_TTL = 900          # 15 minutes
RESET_MIN_INTERVAL = 60  # per user, so a stuck client cannot flood a mailbox

# No 0, O, 1, I or L. These codes get read off a screen and typed on a phone.
CODE_ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"

USERNAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,31}$")
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[a-z]{2,}$", re.I)

MAX_USERS = 32
MAX_DOC_BYTES = 128 * 1024


class UserError(Exception):
    """Something the caller did wrong, safe to show them."""


# ── The document ────────────────────────────────────────────────────────────

def empty_doc():
    return {"version": 1, "rev": 0, "users": {}}


def load(path=None):
    path = path or USERS_FILE
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except FileNotFoundError:
        return empty_doc()
    except (OSError, ValueError) as exc:
        raise UserError("cannot read %s: %s" % (path, exc))
    if not isinstance(doc, dict) or not isinstance(doc.get("users"), dict):
        raise UserError("%s is not a user document" % path)
    doc.setdefault("version", 1)
    doc.setdefault("rev", 0)
    return doc


def save(doc, path=None):
    """Replace the file atomically, at 0600, never widening the mode.

    The temp file is created with the mode already correct rather than
    chmod'ed afterwards, so there is no window in which a password hash is
    world readable, and os.replace preserves the temp file's mode, which is
    the trap that put a 0600 state.json in front of the dashboard once
    already.
    """
    path = path or USERS_FILE
    doc["rev"] = int(doc.get("rev", 0)) + 1
    body = json.dumps(doc, indent=2, sort_keys=True) + "\n"
    if len(body) > MAX_DOC_BYTES:
        raise UserError("the user document is implausibly large; refusing to write it")

    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(body)
            fh.flush()
            os.fsync(fh.fileno())
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    os.replace(tmp, path)
    try:
        os.chmod(path, 0o600)
        os.chown(path, 0, 0)
    except OSError:
        pass
    return doc["rev"]


def get_user(doc, username):
    user = doc.get("users", {}).get(username)
    if user is None:
        raise UserError("no such user: %s" % username)
    return user


# ── Hashing ─────────────────────────────────────────────────────────────────

def hash_secret(plain, iterations=PASSWORD_ITERATIONS):
    salt = secrets.token_bytes(16)
    dk = hashlib.pbkdf2_hmac("sha256", plain.encode("utf-8"), salt,
                             iterations, DK_LEN)
    return {
        "algo": ALGO,
        "iterations": iterations,
        "salt": base64.b64encode(salt).decode(),
        "hash": base64.b64encode(dk).decode(),
    }


def verify_secret(record, plain):
    if not isinstance(record, dict) or record.get("algo") != ALGO:
        return False
    try:
        salt = base64.b64decode(record["salt"])
        want = base64.b64decode(record["hash"])
        iterations = int(record["iterations"])
    except (KeyError, ValueError, TypeError):
        return False
    if iterations < 1000 or iterations > 5000000:
        return False
    got = hashlib.pbkdf2_hmac("sha256", plain.encode("utf-8"), salt,
                              iterations, len(want))
    return secrets.compare_digest(got, want)


def random_code(length):
    return "".join(secrets.choice(CODE_ALPHABET) for _ in range(length))


def recovery_codes(count=10):
    """Plaintext codes and their hashes. The plaintext is shown once."""
    plain = ["%s-%s" % (random_code(5), random_code(5)) for _ in range(count)]
    stored = [dict(hash_secret(code, TOKEN_ITERATIONS), used=False)
              for code in plain]
    return plain, stored


def totp_secret():
    """A base32 secret, which is what an authenticator app expects."""
    return base64.b32encode(secrets.token_bytes(20)).decode().rstrip("=")


# ── Mutations, shared by the CLI and the agent ──────────────────────────────

def validate_username(username):
    if not USERNAME_RE.match(username or ""):
        raise UserError(
            "a username is 1 to 32 characters of a-z, 0-9, dot, dash or "
            "underscore, starting with a letter or digit")
    return username


def validate_email(address):
    if address and not EMAIL_RE.match(address):
        raise UserError("that does not look like an email address")
    return address or ""


def check_password(password):
    if len(password or "") < 12:
        raise UserError("the password must be at least 12 characters")
    if len(password) > 200:
        raise UserError("the password must be at most 200 characters")
    return password


def add_user(doc, username, password, email="", display_name=""):
    validate_username(username)
    validate_email(email)
    check_password(password)
    if username in doc["users"]:
        raise UserError("%s already exists" % username)
    if len(doc["users"]) >= MAX_USERS:
        raise UserError("this dashboard already has %d accounts" % MAX_USERS)
    doc["users"][username] = {
        "display_name": display_name or username,
        "email": email,
        "password": hash_secret(password),
        "created": int(time.time()),
        "password_changed": int(time.time()),
        "totp": {"enabled": False},
    }
    return doc["users"][username]


def set_password(doc, username, password):
    user = get_user(doc, username)
    check_password(password)
    user["password"] = hash_secret(password)
    user["password_changed"] = int(time.time())
    user.pop("reset", None)
    return user


def reset_totp(doc, username):
    user = get_user(doc, username)
    user["totp"] = {"enabled": False}
    return user


def remove_user(doc, username):
    get_user(doc, username)
    if len(doc["users"]) <= 1:
        raise UserError(
            "%s is the only account. Removing it would lock the dashboard, "
            "so add another first, or turn the login off with "
            "`corex manage dashboard-user disable-auth`." % username)
    doc["users"].pop(username)


# ── Password reset, which is the half that stays privileged ─────────────────

def smtp_conf(path=None):
    """Parse /etc/corex/smtp.conf. Values are single quoted, so strip one layer.

    An unquoted password containing a space is read by bash as a command
    prefix and never set at all, which is why smtp_conf_write quotes them.
    """
    path = path or SMTP_CONF
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
        return {}
    return conf


def send_mail(conf, to_address, subject, body):
    host = conf.get("COREX_SMTP_HOST", "")
    if not host:
        raise UserError("no mail relay is configured. Run: corex manage mail-setup")
    port = int(conf.get("COREX_SMTP_PORT", "587") or 587)
    mode = (conf.get("COREX_SMTP_TLS_MODE", "starttls") or "starttls").lower()
    user = conf.get("COREX_SMTP_USER", "")
    # Gmail app passwords are shown in groups of four with spaces, and the
    # spaces are not part of the password.
    password = (conf.get("COREX_SMTP_PASSWORD", "") or "").replace(" ", "")
    sender = conf.get("COREX_SMTP_FROM", "") or user

    msg = EmailMessage()
    msg["From"] = sender
    msg["To"] = to_address
    msg["Subject"] = subject
    msg["Date"] = formatdate(localtime=True)
    msg["Message-ID"] = make_msgid()
    msg.set_content(body)

    if mode in ("ssl", "tls"):
        server = smtplib.SMTP_SSL(host, port, timeout=30)
    else:
        server = smtplib.SMTP(host, port, timeout=30)
    try:
        server.ehlo()
        if mode == "starttls":
            server.starttls()
            server.ehlo()
        if user and password:
            server.login(user, password)
        server.send_message(msg)
    finally:
        try:
            server.quit()
        except Exception:
            pass


def request_reset(doc, username, domain="", conf=None, now=None):
    """Issue a reset code and mail it. Returns True if mail was sent.

    An unknown user, or one with no address on file, is not an error and not
    reported as one: answering differently for a name that exists is how a
    login form becomes a list of valid usernames. The caller says the same
    thing either way.
    """
    now = int(now if now is not None else time.time())
    user = doc.get("users", {}).get(username)
    if not user or not user.get("email"):
        return False

    previous = user.get("reset") or {}
    if now - int(previous.get("requested", 0)) < RESET_MIN_INTERVAL:
        return False

    code = "%s-%s" % (random_code(4), random_code(4))
    user["reset"] = dict(hash_secret(code, TOKEN_ITERATIONS),
                         requested=now, expires=now + RESET_TTL, attempts=0)

    where = "https://dashboard.%s" % domain if domain else "your CoreX dashboard"
    send_mail(
        conf if conf is not None else smtp_conf(),
        user["email"],
        "CoreX dashboard password reset",
        "Someone asked to reset the password for %s on your CoreX dashboard.\n"
        "\n"
        "    %s\n"
        "\n"
        "Enter it at %s within %d minutes. It can only be used once.\n"
        "\n"
        "If this was not you, nothing has changed and you can ignore this "
        "message. Whoever asked could not see your password and cannot use "
        "this code without also reaching the dashboard.\n"
        % (username, code, where, RESET_TTL // 60),
    )
    return True


# ── The access log ──────────────────────────────────────────────────────────
#
# Append only, on the privileged side, for the same reason the user store is:
# a record of who signed in from where is worth something only if the thing
# being audited cannot quietly edit it. The dashboard can add a line and read
# the tail; it cannot rewrite one.

AUTH_LOG = "/var/log/corex-dashboard-auth.log"
AUTH_LOG_MAX = 5000

# What a caller is allowed to record. An open-ended string would let a
# web-facing process write whatever it liked into the operator's audit trail.
AUTH_EVENTS = {
    "login", "login-failed", "logout", "session-revoked", "session-expired",
    "password-changed", "password-reset", "reset-requested",
    "totp-enabled", "totp-disabled", "recovery-code-used",
    "passkey-added", "passkey-removed", "passkey-login",
    "stepup", "stepup-failed",
    "power-reboot", "power-shutdown",
    "locked-out",
}


def auth_log_append(event, username="", ip="", user_agent="", detail="", path=None):
    """Record one event. Never raises: an unwritable log must not block a login."""
    path = path or AUTH_LOG
    if event not in AUTH_EVENTS:
        return False
    row = {
        "t": int(time.time()),
        "event": event,
        "user": str(username)[:64],
        "ip": str(ip)[:64],
        # Trimmed hard. This is attacker-controlled text being written to a
        # file an operator will read, and a browser user agent is long enough
        # to bury the rest of the line.
        "ua": re.sub(r"[\x00-\x1f]", " ", str(user_agent))[:180],
        "detail": re.sub(r"[\x00-\x1f]", " ", str(detail))[:200],
    }
    try:
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(row, sort_keys=True) + "\n")
        os.chmod(path, 0o640)
    except OSError:
        return False
    return True


def auth_log_read(limit=200, path=None):
    """The most recent events, newest first."""
    path = path or AUTH_LOG
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            lines = fh.readlines()[-AUTH_LOG_MAX:]
    except OSError:
        return []
    out = []
    for line in reversed(lines):
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict):
            out.append(row)
        if len(out) >= limit:
            break
    return out
