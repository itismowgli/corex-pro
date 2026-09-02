#!/usr/bin/env bats
# Service-module contract tests.
#
# The headline test here is "repair regenerates the compose file". For a long
# time 14 of 16 modules recreated their container from whatever compose file
# was already on disk, which meant every CoreX fix to env vars, resource
# limits, security_opt, published ports or Traefik labels silently never
# reached an existing install. The concrete casualty was the Traefik dashboard:
# the publish was changed to 127.0.0.1 in code, but deployed instances kept
# 0.0.0.0 and exposed the routing table to the LAN.
#
# `corex doctor` / `corex manage repair` is the only mechanism users have for
# picking up fixes, so this property is load-bearing for the whole project.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export REPO_ROOT

    # Modules that legitimately have no compose file of their own:
    #   coolify — installs its own stack via upstream script (see NOT-TO-DO #4)
    #   ups     — NUT runs on the host, not in Docker
    NO_COMPOSE="coolify ups"
    export NO_COMPOSE
}

_repair_body() {
    local svc="$1"
    awk "/^${svc}_repair\(\)/,/^}/" "${REPO_ROOT}/lib/services/${svc}.sh"
}

# ─── The load-bearing property ────────────────────────────────────────────────

@test "every service repair() regenerates its compose file" {
    local offenders=""
    for f in "${REPO_ROOT}"/lib/services/*.sh; do
        local svc
        svc=$(basename "$f" .sh)
        [[ " $NO_COMPOSE " == *" $svc "* ]] && continue
        grep -q "^${svc}_repair()" "$f" || continue

        local body
        body=$(_repair_body "$svc")
        # Regeneration counts if repair writes the compose itself, calls a
        # dedicated writer, or calls its own idempotent deploy.
        if ! echo "$body" | grep -qE "_${svc}_write_compose|${svc}_deploy|cat > .*docker-compose\.yml"; then
            offenders+=" $svc"
        fi
    done
    [ -z "$offenders" ] || {
        echo "repair() recreates from a STALE compose file in:$offenders"
        echo "Fix: call <svc>_deploy or a _<svc>_write_compose helper first."
        false
    }
}

@test "modules excluded from the compose rule really have no compose" {
    # Guards against quietly adding a service to NO_COMPOSE to dodge the test.
    for svc in $NO_COMPOSE; do
        local f="${REPO_ROOT}/lib/services/${svc}.sh"
        [ -f "$f" ] || continue
        run grep -c 'docker-compose.yml" << ' "$f"
        [ "$output" = "0" ] || {
            echo "$svc is in NO_COMPOSE but does write a compose file"
            false
        }
    done
}

# ─── Traefik dashboard must not be world-bound ───────────────────────────────

@test "traefik dashboard is published on loopback only" {
    # "8080:8080" binds 0.0.0.0, and Docker's published ports write straight
    # into DOCKER-USER, so UFW's default-deny does not cover them.
    local f="${REPO_ROOT}/lib/services/traefik.sh"
    run grep -E '^\s+- "8080:8080"' "$f"
    [ "$status" -ne 0 ]
    grep -qE '127\.0\.0\.1:8080:8080' "$f"
}

# ─── Module contract basics ──────────────────────────────────────────────────

@test "every module defines all seven contract functions" {
    local missing=""
    for f in "${REPO_ROOT}"/lib/services/*.sh; do
        local svc
        svc=$(basename "$f" .sh)
        for fn in dirs firewall deploy destroy status repair credentials; do
            grep -q "^${svc}_${fn}()" "$f" || missing+=" ${svc}_${fn}"
        done
    done
    [ -z "$missing" ] || { echo "missing functions:$missing"; false; }
}

@test "every module parses cleanly" {
    for f in "${REPO_ROOT}"/lib/services/*.sh; do
        run bash -n "$f"
        [ "$status" -eq 0 ] || { echo "parse error in $f"; false; }
    done
}

# ─── Credentials must not be regenerated on every run ────────────────────────

@test "stalwart admin password is persisted, not regenerated per run" {
    # A repair that silently rotates the admin password to a value nothing
    # records is indistinguishable from losing it.
    local f="${REPO_ROOT}/lib/services/stalwart.sh"
    grep -q '.admin-password' "$f"
    grep -q 'STALWART_RECOVERY_ADMIN' "$f"
    # The variables current images ignore must not be SET (the string still
    # appears in a comment explaining why they are wrong, which is fine).
    run grep -cE '^\s*STALWART_ADMIN_SECRET:' "$f"
    [ "$output" = "0" ]
}

@test "generated secrets are persisted, not regenerated on every run" {
    # repair() now calls deploy() so that compose fixes reach existing
    # installs. That makes any secret generated inline in deploy rotate on
    # every repair — silently changing a login to a value nothing records.
    # Every module that generates a secret must therefore reuse a persisted
    # one when present.
    local offenders=""
    for f in "${REPO_ROOT}"/lib/services/*.sh; do
        local svc
        svc=$(basename "$f" .sh)
        grep -qE 'openssl rand|generate_pass' "$f" || continue
        # Must read back a persisted dotfile before generating.
        grep -qE '\-s "\$(pass_file|token_file)"|-s "\$f"|cat "\$(pass_file|token_file)"' "$f" \
            || offenders+=" $svc"
    done
    [ -z "$offenders" ] || {
        echo "secrets regenerate on every run in:$offenders"
        echo "Fix: read back a persisted 0600 file before generating."
        false
    }
}

@test "nextcloud image pins a major version rather than tracking :stable" {
    # :stable follows majors, so a routine update performs an unattended major
    # upgrade — and Nextcloud does not support skipping majors.
    local f="${REPO_ROOT}/lib/services/nextcloud.sh"
    run grep -c 'image: nextcloud:stable' "$f"
    [ "$output" = "0" ]
    grep -qE 'image: nextcloud:[0-9]+' "$f"
}

# ─── state.json holds no credentials ─────────────────────────────────────────

@test "state_set refuses to write secret-looking keys" {
    # state.json is 0644 and bind-mounted into the dashboard container, so a
    # credential written there lands inside a web-facing service. It really
    # happened: cloudflare_tunnel_token lived in state.json for several
    # releases.
    export COREX_STATE_FILE="${BATS_TEST_TMPDIR}/state.json"
    # shellcheck disable=SC1090
    source "${REPO_ROOT}/lib/state.sh"
    state_init

    run state_set "cloudflare_tunnel_token" "secret-value"
    [ "$status" -ne 0 ]
    run grep -c "secret-value" "$COREX_STATE_FILE"
    [ "$output" = "0" ]

    # A non-secret key still writes normally.
    run state_set "domain" "example.com"
    [ "$status" -eq 0 ]
    grep -q "example.com" "$COREX_STATE_FILE"
}

@test "state.json stays readable by the dashboard container after a write" {
    # mv from mktemp preserves 0600, which silently made state.json
    # unreadable to the dashboard on the next write.
    export COREX_STATE_FILE="${BATS_TEST_TMPDIR}/state2.json"
    # shellcheck disable=SC1090
    source "${REPO_ROOT}/lib/state.sh"
    state_init
    state_set "domain" "example.com"
    state_service_installed "nextcloud"
    run stat -c "%a" "$COREX_STATE_FILE"
    [ "$output" = "644" ]
}

@test "state_strip_secrets removes a legacy token from an existing state file" {
    export COREX_STATE_FILE="${BATS_TEST_TMPDIR}/state3.json"
    # shellcheck disable=SC1090
    source "${REPO_ROOT}/lib/state.sh"
    state_init
    # Simulate a state file written by an older CoreX.
    jq '.cloudflare_tunnel_token = "legacy-token"' "$COREX_STATE_FILE" > "$COREX_STATE_FILE.t"
    mv "$COREX_STATE_FILE.t" "$COREX_STATE_FILE"
    grep -q "legacy-token" "$COREX_STATE_FILE"

    state_strip_secrets
    run grep -c "legacy-token" "$COREX_STATE_FILE"
    [ "$output" = "0" ]
}

@test "no module writes a credential into state.json" {
    run grep -rhoE 'state_set "[a-z_]+"' --include='*.sh' "$REPO_ROOT"
    for key in $(echo "$output" | sed 's/state_set "//;s/"//' | sort -u); do
        case "$key" in
            *token*|*secret*|*password*|*passwd*|*key*|*credential*)
                echo "state_set writes secret-looking key: $key"
                false
                ;;
        esac
    done
}

# ─── Secrets must not be mounted into the web-facing dashboard ───────────────

@test "dashboard does not mount the credentials file" {
    run grep -c 'corex-credentials.txt:/root/corex-credentials.txt' \
        "${REPO_ROOT}/lib/services/dashboard.sh"
    [ "$output" = "0" ]
}

# ─── A repair with no token must not destroy a working tunnel ────────────────

@test "cloudflared resolves its token before removing the container" {
    # The old order was `docker rm -f cloudflared` and then the token check,
    # so a repair on a box whose state.json lacked the token tore down the
    # live tunnel and returned only a warning.
    local f="${REPO_ROOT}/lib/services/cloudflared.sh"
    local body
    body=$(awk '/^cloudflared_deploy\(\)/,/^}/' "$f")
    local rm_line token_line
    token_line=$(echo "$body" | grep -n '_cloudflared_token' | head -1 | cut -d: -f1)
    rm_line=$(echo "$body" | grep -n 'docker rm -f cloudflared' | head -1 | cut -d: -f1)
    [ -n "$token_line" ]
    [ -n "$rm_line" ]
    [ "$token_line" -lt "$rm_line" ]
}

@test "cloudflared persists its token to a 0600 dotfile" {
    grep -q 'chmod 600 "\$token_file"' "${REPO_ROOT}/lib/services/cloudflared.sh"
    grep -q '.tunnel-token' "${REPO_ROOT}/lib/services/cloudflared.sh"
}

@test "cloudflared compose is not world-readable (it embeds the token)" {
    grep -q 'chmod 600 "\${dir}/docker-compose.yml"' \
        "${REPO_ROOT}/lib/services/cloudflared.sh"
}

# ─── A running container is not proof of health ──────────────────────────────

@test "stalwart_status checks for a banned proxy and bootstrap mode" {
    # stalwart_status returned HEALTHY through a total external outage: a bot
    # scan had banned cloudflared's container IP, and a bootstrap-mode server
    # answers HTTP while being unable to carry mail at all.
    local f="${REPO_ROOT}/lib/services/stalwart.sh"
    grep -q '_stalwart_proxy_banned' "$f"
    grep -q '_stalwart_bootstrap_mode' "$f"
    local body
    body=$(awk '/^stalwart_status\(\)/,/^}/' "$f")
    echo "$body" | grep -q '_stalwart_proxy_banned'
    echo "$body" | grep -q '_stalwart_bootstrap_mode'
}

@test "stalwart credentials output has no duplicated line" {
    local body
    body=$(awk '/^stalwart_credentials\(\)/,/^}/' "${REPO_ROOT}/lib/services/stalwart.sh")
    local dupes
    dupes=$(echo "$body" | sort | uniq -d | grep -c . || true)
    [ "$dupes" = "0" ]
}
