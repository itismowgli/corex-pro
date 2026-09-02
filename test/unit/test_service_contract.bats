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
