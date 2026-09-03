#!/bin/sh
# Drives the dashboard's login end to end against the real binary.
#
# This exists because a login that is subtly wrong looks exactly like one that
# works: every unit test passes, the page renders, and the hole is only visible
# when something is actually refused. So this signs in, gets it wrong, enrols
# in two-factor, spends a recovery code, resets a password and kills the agent,
# and checks the answer each time.
#
# corex-agent is replaced by test/e2e/fake-agent.py, which holds the user
# document in memory and records what it was asked to mail. Nothing here needs
# a server, root, or a configured relay.
#
# Run it from the repo root:
#
#   ./test/e2e/dashboard-auth.sh          # needs Docker
#
set -e

if [ "${IN_CONTAINER:-}" != "1" ]; then
    repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    cp "$repo"/dashboard/main.go "$repo"/dashboard/auth.go \
       "$repo"/dashboard/auth_test.go "$repo"/dashboard/go.mod \
       "$repo"/agent/corex_users.py "$work/"
    cp "$repo"/test/e2e/fake-agent.py "$work/fakeagent.py"
    cp "$repo"/test/e2e/dashboard-auth.sh "$work/run.sh"
    exec docker run --rm -e IN_CONTAINER=1 -v "$work":/work -w /work \
        golang:1.24-alpine sh /work/run.sh
fi

cd /work
mkdir -p web/dist && echo '<html><body><div id="root"></div></body></html>' > web/dist/index.html
head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > /work/token
apk add --no-cache python3 curl >/dev/null
go build -o /tmp/dash . 
python3 fakeagent.py & sleep 1
COREX_AGENT_SOCKET=/run/corex/agent.sock COREX_AGENT_TOKEN_FILE=/work/token \
  /tmp/dash > /work/dash.log 2>&1 &
sleep 1
J=/tmp/jar; rm -f $J
say() { printf '\n--- %s\n' "$1"; }
# curl -b/-c keeps the session cookie. --insecure-ish note: the cookie is
# Secure, so the jar is primed over http by hand where needed.
req() { curl -s -o /tmp/body -w '%{http_code}' -b $J -c $J -H 'Content-Type: application/json' "$@"; }

say "an unauthenticated API call must be refused"
CODE=$(req http://127.0.0.1:8080/api/services); echo "$CODE $(cat /tmp/body)"
[ "$CODE" = "401" ] || { echo FAIL; exit 1; }

say "the app shell is still served"
CODE=$(req http://127.0.0.1:8080/); echo "$CODE"
[ "$CODE" = "200" ] || { echo FAIL; exit 1; }

say "a wrong password"
CODE=$(req -X POST -d '{"username":"operator","password":"nope"}' http://127.0.0.1:8080/api/auth/login)
echo "$CODE $(cat /tmp/body)"; [ "$CODE" = "401" ] || { echo FAIL; exit 1; }

say "an unknown user gets the same answer"
CODE=$(req -X POST -d '{"username":"nobody","password":"nope"}' http://127.0.0.1:8080/api/auth/login)
echo "$CODE $(cat /tmp/body)"; [ "$CODE" = "401" ] || { echo FAIL; exit 1; }

say "the right password"
CODE=$(req -X POST -d '{"username":"operator","password":"correct horse battery"}' http://127.0.0.1:8080/api/auth/login)
echo "$CODE $(cat /tmp/body)"; [ "$CODE" = "200" ] || { echo FAIL; exit 1; }

say "and now the API answers"
CODE=$(req http://127.0.0.1:8080/api/auth/me); echo "$CODE $(cat /tmp/body)"
[ "$CODE" = "200" ] || { echo FAIL; exit 1; }
grep -q '"authenticated":true' /tmp/body || { echo FAIL; exit 1; }

say "enrol in two-factor"
CODE=$(req -X POST http://127.0.0.1:8080/api/auth/totp/begin); echo "$CODE $(cat /tmp/body)"
SECRET=$(python3 -c "import json;print(json.load(open('/tmp/body'))['secret'])")
OTP=$(python3 - "$SECRET" <<'PY'
import base64, hmac, hashlib, struct, sys, time
s = sys.argv[1] + "=" * (-len(sys.argv[1]) % 8)
key = base64.b32decode(s)
c = int(time.time()) // 30
h = hmac.new(key, struct.pack(">Q", c), hashlib.sha1).digest()
o = h[-1] & 0xf
print("%06d" % ((struct.unpack(">I", h[o:o+4])[0] & 0x7fffffff) % 1000000))
PY
)
CODE=$(req -X POST -d "{\"code\":\"$OTP\"}" http://127.0.0.1:8080/api/auth/totp/enable)
echo "$CODE $(cat /tmp/body)"; [ "$CODE" = "200" ] || { echo FAIL; exit 1; }
RECOVERY=$(python3 -c "import json;print(json.load(open('/tmp/body'))['recovery_codes'][0])")
RECOVERY2=$(python3 -c "import json;print(json.load(open('/tmp/body'))['recovery_codes'][1])")
echo "first recovery code: $RECOVERY"

say "signing in now owes a second factor"
rm -f $J
CODE=$(req -X POST -d '{"username":"operator","password":"correct horse battery"}' http://127.0.0.1:8080/api/auth/login)
echo "$CODE $(cat /tmp/body)"; grep -q '"awaiting_totp":true' /tmp/body || { echo FAIL; exit 1; }

say "a half-signed-in session cannot reach the API"
CODE=$(req http://127.0.0.1:8080/api/services); echo "$CODE $(cat /tmp/body)"
[ "$CODE" = "401" ] || { echo FAIL; exit 1; }

say "a wrong code is refused"
CODE=$(req -X POST -d '{"code":"000000"}' http://127.0.0.1:8080/api/auth/totp)
echo "$CODE $(cat /tmp/body)"; [ "$CODE" = "401" ] || { echo FAIL; exit 1; }

say "a recovery code completes it"
CODE=$(req -X POST -d "{\"code\":\"$RECOVERY\"}" http://127.0.0.1:8080/api/auth/totp)
echo "$CODE $(cat /tmp/body)"; [ "$CODE" = "200" ] || { echo FAIL; exit 1; }

say "and the same recovery code cannot be used twice"
rm -f $J
req -X POST -d '{"username":"operator","password":"correct horse battery"}' http://127.0.0.1:8080/api/auth/login >/dev/null
CODE=$(req -X POST -d "{\"code\":\"$RECOVERY\"}" http://127.0.0.1:8080/api/auth/totp)
echo "$CODE $(cat /tmp/body)"; [ "$CODE" = "401" ] || { echo FAIL; exit 1; }

say "password reset by emailed code"
rm -f $J
CODE=$(req -X POST -d '{"username":"operator"}' http://127.0.0.1:8080/api/auth/reset/request)
echo "$CODE $(cat /tmp/body)"; [ "$CODE" = "200" ] || { echo FAIL; exit 1; }
RC=$(python3 -c "import json;print(json.load(open('/work/mailed.json'))['operator'])")
echo "the agent mailed: $RC"
CODE=$(req -X POST -d "{\"username\":\"operator\",\"code\":\"WRONG-11\",\"password\":\"a-new-long-password\"}" http://127.0.0.1:8080/api/auth/reset/complete)
echo "wrong code: $CODE $(cat /tmp/body)"; [ "$CODE" = "403" ] || { echo FAIL; exit 1; }
CODE=$(req -X POST -d "{\"username\":\"operator\",\"code\":\"$RC\",\"password\":\"a-new-long-password\"}" http://127.0.0.1:8080/api/auth/reset/complete)
echo "right code: $CODE $(cat /tmp/body)"; [ "$CODE" = "200" ] || { echo FAIL; exit 1; }

say "the reset code cannot be replayed"
CODE=$(req -X POST -d "{\"username\":\"operator\",\"code\":\"$RC\",\"password\":\"another-long-password\"}" http://127.0.0.1:8080/api/auth/reset/complete)
echo "$CODE $(cat /tmp/body)"; [ "$CODE" = "403" ] || { echo FAIL; exit 1; }

say "reset also cleared two-factor? it must NOT have"
rm -f $J
CODE=$(req -X POST -d '{"username":"operator","password":"a-new-long-password"}' http://127.0.0.1:8080/api/auth/login)
echo "$CODE $(cat /tmp/body)"; grep -q '"awaiting_totp":true' /tmp/body || { echo "FAIL: reset bypassed 2FA"; exit 1; }

say "a fully signed-in session, for the last two checks"
rm -f $J
req -X POST -d '{"username":"operator","password":"a-new-long-password"}' http://127.0.0.1:8080/api/auth/login >/dev/null
# A second recovery code, not the authenticator: the enrolling code was spent
# in this same 30 second window, and the replay guard correctly refuses it.
CODE=$(req -X POST -d "{\"code\":\"$RECOVERY2\"}" http://127.0.0.1:8080/api/auth/totp)
echo "$CODE $(cat /tmp/body)"; [ "$CODE" = "200" ] || { echo FAIL; exit 1; }

say "no new session can be created without the store, even inside the cache window"
pkill -f fakeagent.py; sleep 1
CODE=$(curl -s -o /tmp/body -w '%{http_code}' -H 'Content-Type: application/json' \
  -X POST -d '{"username":"operator","password":"a-new-long-password"}' http://127.0.0.1:8080/api/auth/login)
echo "$CODE $(cat /tmp/body)"; [ "$CODE" = "503" ] || { echo FAIL; exit 1; }

say "and once the cached answer expires, an existing session is refused too"
sleep 6
CODE=$(req http://127.0.0.1:8080/api/services); echo "$CODE $(cat /tmp/body)"
[ "$CODE" = "503" ] || { echo FAIL; exit 1; }

printf '\nALL E2E CHECKS PASSED\n'
