"""A stand-in for corex-agent, so the login can be driven end to end.

It answers only the three actions auth.go uses, holds the document in memory,
and records what it was asked to mail.
"""
import json, os, socket, socketserver, sys, threading, time
sys.path.insert(0, "/work")
import corex_users as cu

DOC = {"version": 1, "rev": 0, "users": {}}
MAILED = {}
EVENTS = []
TOKEN = open("/work/token").read().strip()
LOCK = threading.Lock()


def handle(req):
    if req.get("token") != TOKEN:
        return {"ok": False, "error": "unauthorised"}
    action = req.get("action")
    if action == "auth-log":
        # The dashboard records every sign-in through the agent now. Answering
        # it keeps those calls from logging a failure on every attempt.
        if req.get("event"):
            EVENTS.append(req)
            return {"ok": True}
        return {"ok": True, "events": list(reversed(EVENTS))[:200]}
    with LOCK:
        if action == "users-get":
            return {"ok": True, "doc": DOC}
        if action == "users-put":
            given = req["doc"]
            if int(given.get("rev", -1)) != DOC["rev"]:
                return {"ok": False, "error": "stale revision, re-read the document"}
            given["rev"] = DOC["rev"] + 1
            DOC.clear(); DOC.update(given)
            return {"ok": True, "rev": DOC["rev"]}
        if action == "auth-reset":
            name = req.get("username", "")
            user = DOC["users"].get(name)
            if not user or not user.get("email"):
                return {"ok": True}
            now = int(time.time())
            code = "%s-%s" % (cu.random_code(4), cu.random_code(4))
            user["reset"] = dict(cu.hash_secret(code, cu.TOKEN_ITERATIONS),
                                 requested=now, expires=now + 900, attempts=0)
            DOC["rev"] += 1
            MAILED[name] = code
            open("/work/mailed.json", "w").write(json.dumps(MAILED))
            return {"ok": True}
    return {"ok": False, "error": "unknown action"}


class H(socketserver.StreamRequestHandler):
    def handle(self):
        raw = self.rfile.readline(65536)
        try:
            resp = handle(json.loads(raw))
        except Exception as exc:
            resp = {"ok": False, "error": repr(exc)}
        self.wfile.write((json.dumps(resp) + "\n").encode())


class S(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True


if __name__ == "__main__":
    cu.add_user(DOC, "operator", "correct horse battery", email="operator@example.com",
                display_name="Operator")
    DOC["rev"] = 1
    path = "/run/corex/agent.sock"
    os.makedirs("/run/corex", exist_ok=True)
    if os.path.exists(path):
        os.unlink(path)
    S(path, H).serve_forever()
