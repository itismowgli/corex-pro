#!/usr/bin/env python3
"""Command-line client for the CoreX action agent.

    corex-agentctl status
    corex-agentctl stop nextcloud
    corex-agentctl job <job_id>
    corex-agentctl logs immich 60

Exists so the socket can be exercised without the dashboard or Telegram in the
way. It is also what `corex manage agent test` uses, which means the thing
being tested is the same path the real clients take.

Exit status is 0 when the agent reported success, 1 otherwise, so it composes
in a shell.
"""

import json
import socket
import sys

sys.path.insert(0, "/usr/local/lib/corex")
import corex_common as cc  # noqa: E402

CONF = cc.read_conf()
SOCKET_PATH = CONF.get("AGENT_SOCKET", cc.DEFAULT_SOCKET)
TOKEN_FILE = CONF.get("AGENT_TOKEN_FILE", "/etc/corex/agent.token")


def call(payload, timeout=300):
    with open(TOKEN_FILE, encoding="utf-8") as fh:
        payload["token"] = fh.read().strip()
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    sock.connect(SOCKET_PATH)
    try:
        sock.sendall((json.dumps(payload) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = sock.recv(65536)
            if not chunk:
                break
            buf += chunk
    finally:
        sock.close()
    return json.loads(buf.decode("utf-8", "replace") or "{}")


def main(argv):
    if not argv:
        print(__doc__.strip())
        return 2
    req = {"action": argv[0]}
    if argv[0] == "job":
        req["job_id"] = argv[1] if len(argv) > 1 else ""
    else:
        if len(argv) > 1:
            req["service"] = argv[1]
        if argv[0] == "logs" and len(argv) > 2:
            req["tail"] = argv[2]

    try:
        res = call(req)
    except OSError as exc:
        print("cannot reach the agent at %s: %s" % (SOCKET_PATH, exc),
              file=sys.stderr)
        return 1
    except ValueError:
        print("malformed reply from the agent", file=sys.stderr)
        return 1

    if res.get("output"):
        print(res["output"])
    summary = {k: v for k, v in res.items() if k != "output"}
    print(json.dumps(summary, sort_keys=True), file=sys.stderr)
    return 0 if res.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
