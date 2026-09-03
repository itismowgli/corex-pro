#!/usr/bin/env python3
"""CoreX action agent.

WHY THIS EXISTS
    The dashboard runs as `nobody` in a container and `corex-manage.sh`
    requires root, so every action button failed with "Run as root". The
    obvious fixes are both wrong: running the web container as root hands a
    web-facing process the whole host, and giving it passwordless sudo is the
    same thing with extra steps.

    Instead there is exactly one privileged process, here, with a fixed list of
    actions it is willing to perform. The dashboard and the Telegram bot are
    both unprivileged clients of it. That way there is a single place to audit,
    and adding a second client adds no new privilege.

WHY NOT `docker stop` FROM THE DASHBOARD
    It already has the Docker socket, so it could. But a bare `docker stop`
    leaves the restart policy at unless-stopped, so Docker brings the container
    back on the next boot, and the thermal guardian may restart it sooner than
    that. `corex-manage.sh disable` sets restart=no and records the intent in
    state.json, which is also what stops the resource watchdog reporting a
    deliberate stop as a fault. Going through corex-manage keeps one meaning of
    "stopped".

PROTOCOL
    A unix socket at /run/corex/agent.sock, mode 0660, group corex-agent.
    One line of JSON in, one line of JSON out, connection closed. Not HTTP:
    there is no browser on this path and a line of JSON has no parsing
    surface worth attacking.

    Requests carry a token from /etc/corex/agent.token. The socket permissions
    are the real boundary; the token is there so a mistake in those
    permissions is not immediately fatal.

WHAT IT WILL NOT DO
    remove, replace, nuke, migrate and add are absent by design. Everything
    reachable here is reversible, so a compromised Telegram account or
    dashboard session cannot destroy data or an install. Those stay on SSH.
"""

import hmac
import json
import os
import socket
import socketserver
import subprocess
import sys
import threading
import time
import uuid

sys.path.insert(0, "/usr/local/lib/corex")
import corex_common as cc  # noqa: E402

CONF = cc.read_conf()
REPO_ROOT = CONF.get("COREX_REPO_ROOT", "/opt/corex-pro")
MANAGE = CONF.get("COREX_MANAGE", os.path.join(REPO_ROOT, "corex-manage.sh"))
SOCKET_PATH = CONF.get("AGENT_SOCKET", cc.DEFAULT_SOCKET)
SOCKET_GROUP = CONF.get("AGENT_GROUP", "corex-agent")
TOKEN_FILE = CONF.get("AGENT_TOKEN_FILE", "/etc/corex/agent.token")
LOG = CONF.get("AGENT_LOG", "/var/log/corex-agent.log")
NOTIFY = CONF.get("AGENT_NOTIFY", "true").lower() == "true"

# action -> (corex-manage arguments, takes a service, runs in background)
#
# Background is decided by how long the action can take, not by how dangerous
# it is: update pulls images and repair recreates containers, both of which
# outlast any sensible client timeout. Fast read-only actions answer inline so
# a caller does not have to poll for a one-line answer.
ACTIONS = {
    "start":   (["enable"],            True,  True),
    "stop":    (["disable"],           True,  True),
    "restart": (["restart"],           True,  True),
    "repair":  (["repair"],            True,  True),
    "update":  (["update"],            True,  True),
    "cleanup": (["cleanup"],           False, True),
    # Read-only, so it belongs on the whitelist rather than being run by the
    # caller. The dashboard used to shell out to `corex-manage cleanup
    # --dry-run` itself and got "Run as root" every time, because that
    # container runs as nobody: the same fault the whole agent exists to fix
    # (gotcha #30), left behind in one path.
    "cleanup-preview": (["cleanup", "--dry-run"], False, False),
    "status":  (["status", "--plain"], False, False),
    "list":    (["list"],              False, False),
    "health":  (["health"],            False, False),
    "storage": (["storage"],           False, False),
    # ── Read-only reporting, for the dashboard ───────────────────────────────
    # These answer "what is degrading this box" and "is every hostname
    # actually reachable", which is the half of monitoring an HTTP check
    # cannot cover. They change nothing, but they are slow enough to want a
    # job rather than a synchronous reply: network-check curls every service
    # and inspects a certificate per hostname.
    "watchdog":      (["watchdog"],      False, True),
    "network-check": (["network-check"], False, True),
    "route-list":    (["route", "list"], False, False),
    # doctor repairs whatever it finds unhealthy. That is not new privilege:
    # repair is already reachable per service, and doctor is repair applied to
    # the ones that need it.
    "doctor":        (["doctor"],        False, True),
}
# Actions that change the system, and so are announced when they finish.
MUTATING = {"start", "stop", "restart", "repair", "update", "cleanup"}

JOB_TIMEOUT = {"update": 1800, "repair": 900, "cleanup": 900}
DEFAULT_TIMEOUT = 300
MAX_JOB_HISTORY = 60

SERVICES = cc.discover_services(REPO_ROOT)

_jobs = {}
_jobs_lock = threading.Lock()
# One mutating job at a time. Two `docker compose up` runs against the same
# project race, and two against different projects can still both be pulling
# images on a thermally marginal box, which is how a repair turns into a
# thermal event.
_run_lock = threading.Lock()
_running = {"job": None}


def say(msg):
    line = "%s agent: %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S%z"), msg)
    try:
        with open(LOG, "a", encoding="utf-8") as fh:
            fh.write(line)
    except OSError:
        pass


def load_token():
    try:
        with open(TOKEN_FILE, encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def valid_service(name, action):
    """Accept a known service, or `all` where corex-manage supports it."""
    if action == "update" and name == "all":
        return True
    if not name or not cc.SERVICE_RE.match(name):
        return False
    return name.split(":", 1)[0] in SERVICES


def build_argv(action, service):
    args, needs_service, _ = ACTIONS[action]
    argv = ["bash", MANAGE] + list(args)
    if needs_service:
        argv.append("--all" if service == "all" else service)
    return argv


def run_manage(action, service):
    argv = build_argv(action, service)
    timeout = JOB_TIMEOUT.get(action, DEFAULT_TIMEOUT)
    try:
        proc = subprocess.run(
            argv, capture_output=True, text=True, timeout=timeout, check=False
        )
        out = (proc.stdout or "") + (proc.stderr or "")
        return proc.returncode, cc.strip_ansi(out).strip()
    except subprocess.TimeoutExpired:
        return 124, "timed out after %ds" % timeout
    except OSError as exc:
        return 125, "could not run %s: %s" % (MANAGE, exc)


def service_containers(service):
    """Containers belonging to one service, via its compose project label.

    The compose project is the directory under docker-configs, which is the
    service name, so this covers a module that deploys several containers
    without needing a hardcoded map.
    """
    try:
        proc = subprocess.run(
            ["docker", "ps", "-a", "--filter",
             "label=com.docker.compose.project=%s" % service,
             "--format", "{{.Names}}"],
            capture_output=True, text=True, timeout=30, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return []
    return [n for n in proc.stdout.split() if n]


def action_logs(service, tail):
    names = service_containers(service)
    if not names:
        return 1, "no containers found for %s" % service
    chunks = []
    for name in names[:6]:
        try:
            proc = subprocess.run(
                ["docker", "logs", "--tail", str(tail), name],
                capture_output=True, text=True, timeout=30, check=False,
            )
            body = cc.strip_ansi((proc.stdout or "") + (proc.stderr or "")).strip()
        except (OSError, subprocess.TimeoutExpired):
            body = "(could not read logs)"
        chunks.append("=== %s ===\n%s" % (name, body or "(empty)"))
    return 0, "\n\n".join(chunks)


# ── Job handling ────────────────────────────────────────────────────────────

def record(job_id, **fields):
    with _jobs_lock:
        job = _jobs.setdefault(job_id, {})
        job.update(fields)
        if len(_jobs) > MAX_JOB_HISTORY:
            for stale in sorted(_jobs, key=lambda k: _jobs[k].get("started", 0))[:10]:
                if _jobs[stale].get("state") in ("done", "failed"):
                    _jobs.pop(stale, None)


def _outcome_lines(output, rc):
    """The lines worth putting in a notification.

    On success that is the summary corex-manage already prints, which says what
    actually changed ("vaultwarden stopped and set not to restart"). Reporting
    only "finished in 6s" makes every job look identical and tells the reader
    nothing. On failure it is the tail, because that is where the error is.
    """
    lines = [ln.strip() for ln in (output or "").splitlines() if ln.strip()]
    if not lines:
        return []
    if rc != 0:
        return lines[-4:]
    # Prefer the last [  OK] line; fall back to the last line of any kind.
    ok_lines = [ln for ln in lines if ln.startswith("[  OK]")]
    chosen = ok_lines[-1] if ok_lines else lines[-1]
    for prefix in ("[  OK] ", "[INFO] ", "[STEP] "):
        if chosen.startswith(prefix):
            chosen = chosen[len(prefix):]
    return [chosen]


def announce(action, service, rc, elapsed, output):
    """Tell Telegram the job finished.

    Kuma only notifies on a state change, so a job that succeeds is not
    something it can report: a successful `stop` produces no Kuma event beyond
    the service monitor going down a minute later, and a successful `update`
    produces none at all. The completion notice therefore comes from the bot
    directly, in the same chat as the alerts.
    """
    if not NOTIFY:
        return
    token, chat = cc.telegram_creds(CONF)
    if not token or not chat:
        return

    ok = rc == 0
    title = ("%s %s" % (action, service or "")).strip()
    when = "Done in %ds." % elapsed if ok else "Failed after %ds." % elapsed
    parts = ["%s *%s*" % ("✅" if ok else "\U0001f6a8", cc.md_escape(title)),
             cc.md_escape(when)]
    detail = _outcome_lines(output, rc)
    if detail:
        parts.append(cc.md_escape("\n".join(detail)))
    cc.telegram_send(token, chat, "\n".join(parts))


def worker(job_id, action, service):
    started = time.time()
    try:
        rc, out = run_manage(action, service)
    finally:
        _running["job"] = None
        _run_lock.release()
    elapsed = int(time.time() - started)
    record(job_id, state="done" if rc == 0 else "failed", rc=rc,
           output=out, finished=time.time(), elapsed=elapsed)
    say("job %s %s %s rc=%d in %ds" % (job_id, action, service or "-", rc, elapsed))
    if action in MUTATING:
        announce(action, service, rc, elapsed, out)


def start_job(action, service):
    if not _run_lock.acquire(blocking=False):
        busy = _running.get("job") or "another action"
        return {"ok": False, "error": "busy running %s, try again shortly" % busy}
    job_id = uuid.uuid4().hex[:12]
    _running["job"] = "%s %s" % (action, service or "")
    record(job_id, state="running", action=action, service=service,
           started=time.time(), output="", rc=None)
    threading.Thread(target=worker, args=(job_id, action, service),
                     daemon=True).start()
    return {"ok": True, "job_id": job_id, "state": "running",
            "message": "%s %s started" % (action, service or "")}


# ── Request dispatch ────────────────────────────────────────────────────────

def handle(req):
    token = load_token()
    given = str(req.get("token", ""))
    if not token or not hmac.compare_digest(given, token):
        return {"ok": False, "error": "unauthorised"}

    action = str(req.get("action", ""))
    service = str(req.get("service", "") or "")

    if action == "job":
        job_id = str(req.get("job_id", ""))
        with _jobs_lock:
            job = dict(_jobs.get(job_id, {}))
        if not job:
            return {"ok": False, "error": "unknown job"}
        return {"ok": True, "job_id": job_id, "state": job.get("state"),
                "rc": job.get("rc"), "output": job.get("output", ""),
                "elapsed": job.get("elapsed"), "action": job.get("action"),
                "service": job.get("service")}

    if action == "services":
        return {"ok": True, "services": sorted(SERVICES),
                "actions": sorted(ACTIONS) + ["logs"]}

    if action == "logs":
        if not valid_service(service, action):
            return {"ok": False, "error": "unknown service"}
        try:
            tail = max(1, min(400, int(req.get("tail", 40))))
        except (TypeError, ValueError):
            tail = 40
        rc, out = action_logs(service, tail)
        return {"ok": rc == 0, "output": out}

    if action not in ACTIONS:
        return {"ok": False, "error": "unknown action"}

    _, needs_service, is_async = ACTIONS[action]
    if needs_service and not valid_service(service, action):
        return {"ok": False, "error": "unknown service"}
    if not needs_service:
        service = ""

    if is_async:
        return start_job(action, service)

    rc, out = run_manage(action, service)
    return {"ok": rc == 0, "rc": rc, "output": out, "state": "done"}


class Handler(socketserver.StreamRequestHandler):
    timeout = 30

    def handle(self):
        try:
            raw = self.rfile.readline(65536)
        except (socket.timeout, OSError):
            return
        try:
            req = json.loads(raw.decode("utf-8", "replace") or "{}")
            if not isinstance(req, dict):
                raise ValueError("not an object")
        except ValueError:
            resp = {"ok": False, "error": "malformed request"}
        else:
            try:
                resp = handle(req)
            except Exception as exc:                      # never die on one bad request
                say("unhandled error: %r" % (exc,))
                resp = {"ok": False, "error": "internal error"}
            else:
                if not resp.get("ok"):
                    say("refused %s %s: %s" % (req.get("action"),
                                               req.get("service"),
                                               resp.get("error")))
        try:
            self.wfile.write((json.dumps(resp) + "\n").encode())
        except OSError:
            pass


class Server(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    import grp

    try:
        gid = grp.getgrnam(SOCKET_GROUP).gr_gid
    except KeyError:
        gid = -1
        say("group %s does not exist; the socket stays root-only and the "
            "dashboard will not be able to reach it" % SOCKET_GROUP)

    # The directory's ownership is fixed here rather than left to
    # systemd-tmpfiles. On a cold boot Docker can start the dashboard, and so
    # create this directory itself as root:root, before tmpfiles has run.
    # Setting it on every start removes the ordering question entirely.
    run_dir = os.path.dirname(SOCKET_PATH)
    os.makedirs(run_dir, exist_ok=True)
    if gid >= 0:
        try:
            os.chown(run_dir, 0, gid)
            os.chmod(run_dir, 0o750)
        except OSError as exc:
            say("could not set permissions on %s: %s" % (run_dir, exc))

    if os.path.exists(SOCKET_PATH):
        os.unlink(SOCKET_PATH)

    server = Server(SOCKET_PATH, Handler)
    if gid >= 0:
        try:
            os.chown(SOCKET_PATH, 0, gid)
        except OSError as exc:
            say("could not set socket group %s (%s); leaving it root-only"
                % (SOCKET_GROUP, exc))
    # 0660: the group is the boundary. Never 0666, which would let any process
    # on the host drive the agent.
    os.chmod(SOCKET_PATH, 0o660)

    say("listening on %s, %d services, actions: %s"
        % (SOCKET_PATH, len(SERVICES), ",".join(sorted(ACTIONS))))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        if os.path.exists(SOCKET_PATH):
            os.unlink(SOCKET_PATH)


if __name__ == "__main__":
    main()
