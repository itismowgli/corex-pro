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

# Every hostname a Traefik Host rule can produce, one per line.
#
# A rule may be literal (Host(`photos.${DOMAIN}`)), written into the file
# provider for a backend Traefik cannot discover (Coolify), or built from a
# variable when the subdomain is overridable (n8n, because a name can be
# blocked by something outside the service). For the variable form the default
# is what ships, so that is what the dashboard must link to.
_host_rules() {
    {
        grep -rhoE 'rule: "Host\(\\`[a-z0-9-]+\.|rule=Host\(\\`[a-z0-9-]+\.' \
            "${REPO_ROOT}"/lib/services/*.sh \
            | sed 's/.*Host(\\`//;s/\.$//'
        # Variable subdomains: take the default out of ${sub:-default}.
        grep -rhoE '\$\{subs?:-[a-z0-9-]+\}' "${REPO_ROOT}"/lib/services/*.sh \
            | sed 's/.*:-//;s/}//'
    } | sort -u
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

@test "banned-proxy check scopes its log window to the container start time" {
    # Stalwart's ban list is in memory, so a fixed --since window keeps
    # reporting a ban that the last restart already cleared.
    local body
    body=$(awk '/^_stalwart_proxy_banned\(\)/,/^}/' \
        "${REPO_ROOT}/lib/services/stalwart.sh")
    echo "$body" | grep -q 'State.StartedAt'
    run bash -c "echo '$body' | grep -c 'docker logs --since 24h'"
    [ "$output" = "0" ]
}

@test "no module pipes docker logs into grep -q" {
    # grep -q exits on the first match, docker logs takes SIGPIPE, and
    # `set -o pipefail` reports 141 — so under pipefail the check returns
    # false exactly when it matched. This inverted Stalwart's bootstrap-mode
    # detection, which is why a bootstrap-mode server reported HEALTHY.
    # docker logs is unbounded, so it is the case that reliably triggers it.
    local offenders=""
    for f in "${REPO_ROOT}"/lib/services/*.sh "${REPO_ROOT}"/lib/*.sh; do
        [ -f "$f" ] || continue
        grep -nE 'docker logs[^|]*\|[[:space:]]*grep[^|]*-[a-zA-Z]*q' "$f" >/dev/null \
            && offenders+=" $(basename "$f")"
    done
    [ -z "$offenders" ] || {
        echo "docker logs piped into grep -q in:$offenders"
        echo "Fix: capture the output, then match with [[ \$var == *pat* ]]."
        false
    }
}

# ─── Dashboard links must match the Traefik Host rules ───────────────────────

@test "every dashboard subdomain is declared by a Traefik Host rule" {
    # The dashboard built links as "<service>.DOMAIN", which produced four dead
    # links: immich answers on photos, adguard has no router at all, the
    # Traefik dashboard is loopback-only, and coolify runs its own stack on a
    # port. A hostname only resolves if a Host rule declares it.
    # Both forms count: a Docker label, and a rule written into Traefik's
    # file-provider directory for a backend Traefik cannot discover.
    local rules
    rules=$(_host_rules)
    [ -n "$rules" ]

    local subs offenders=""
    subs=$(grep -oE '"https://[a-z0-9-]+\.\{DOMAIN\}"' "${REPO_ROOT}/dashboard/main.go" \
        | sed 's|"https://||;s|\.{DOMAIN}"||' | sort -u)
    [ -n "$subs" ]

    for s in $subs; do
        echo "$rules" | grep -qx "$s" || offenders+=" $s"
    done
    [ -z "$offenders" ] || {
        echo "dashboard links to hostnames with no Traefik Host rule:$offenders"
        echo "Host rules that exist: $(echo $rules)"
        false
    }
}

@test "dashboard covers every Traefik Host rule that serves a UI" {
    # whiteboard is a Nextcloud websocket backend, not a page a user opens.
    local skip="whiteboard"
    local rules missing=""
    rules=$(_host_rules)
    for r in $rules; do
        [[ " $skip " == *" $r "* ]] && continue
        grep -q "https://${r}\.{DOMAIN}" "${REPO_ROOT}/dashboard/main.go" \
            || missing+=" $r"
    done
    [ -z "$missing" ] || {
        echo "Host rules with no dashboard link:$missing"
        false
    }
}

@test "dashboard service maps are keyed by real service module names" {
    # "uptime-kuma" was a key in three maps and is not a module: Uptime Kuma
    # ships inside the monitoring module, so those entries matched nothing.
    # Scoped to the three service maps; main.go holds other maps too.
    local keys offenders=""
    keys=$(awk '
        /^var service(Labels|URLs|Containers) = map\[string\]/ { inmap=1; next }
        inmap && /^}/ { inmap=0; next }
        inmap && match($0, /"[a-z0-9-]+":/) {
            print substr($0, RSTART+1, RLENGTH-3)
        }' "${REPO_ROOT}/dashboard/main.go" | sort -u)
    [ -n "$keys" ]

    for k in $keys; do
        [ -f "${REPO_ROOT}/lib/services/${k}.sh" ] || offenders+=" $k"
    done
    [ -z "$offenders" ] || {
        echo "dashboard map keys with no lib/services module:$offenders"
        false
    }
}

@test "no service image tracks a moving major-version tag" {
    # :release moved Immich from 1.x to 3.1.0 on a routine update, and 3.x
    # dropped the pgvecto.rs extension the database provided, so the photo
    # library would not start. :stable did the same to Nextcloud earlier.
    local offenders=""
    for f in "${REPO_ROOT}"/lib/services/*.sh; do
        while IFS= read -r img; do
            case "$img" in
                *:release|*:stable|*:main) offenders+=" $(basename "$f" .sh):${img##*/}" ;;
            esac
        done < <(grep -ohE '^\s+image: \S+' "$f" | sed 's/^ *image: //')
    done
    [ -z "$offenders" ] || {
        echo "images on moving major tags:$offenders"
        echo "Pin the major and bump it deliberately (CLAUDE.md gotcha #19)."
        false
    }
}

# ─── A prune filter that takes nothing ───────────────────────────────────────

# `--filter until=` removes nothing on Docker 29. Gotcha #50 established that
# for `docker image prune` and removed it there; it stayed on
# `docker builder prune`, where it did the same thing for months. Measured:
# 0B removed with the filter, 8.477GB without it, on a build cache that had
# grown unbounded while the Reclaim button offered 2.92GB and delivered none
# of it.
#
# The offered figure and the command have to agree, which is the whole point
# of docker_purgeable, so a reintroduced age filter breaks that agreement
# silently: the button goes back to promising space it cannot free.
@test "no prune passes an until filter, which removes nothing on Docker 29" {
    local offenders=""
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        offenders+="  ${line}"$'\n'
    done < <(grep -nE "(image|builder|system|container) prune[^|;]*--filter[^|;]*until=" \
                  "${REPO_ROOT}/corex-manage.sh" || true)
    [ -z "${offenders//[[:space:]]/}" ] || {
        echo "These prunes carry an until filter and will remove nothing:"
        echo "$offenders"
        echo "Measured on Docker 29.8.0: filtered 0B, unfiltered 8.477GB."
        false
    }
}

@test "the purgeable figure models no age limit, matching the cleanup" {
    local f="${REPO_ROOT}/agent/corex_metrics.py"
    # docker_purgeable exists so the button's number and the command's
    # behaviour come from one place. While the cleanup had an age policy this
    # split the cache by age; with the policy gone the split must go too, or
    # the number describes a policy that does not run.
    # A flag, not a range: /^def x/,/^def / closes on the start line itself,
    # because the start line also matches the end pattern. That left the body
    # as one line and the test passed or failed on nothing.
    local body
    body=$(awk '/^def docker_purgeable/{f=1;next} f&&/^def /{exit} f' "$f")
    [ -n "${body//[[:space:]]/}" ] || { echo "docker_purgeable is gone or empty"; false; }
    # The pattern has to include the quote: the line reads
    # out["cache_held_b"] += ..., and a pattern of cache_held_b] += matches
    # nothing, so the check passed on a reintroduced split.
    echo "$body" | grep -qE 'cache_held_b"\]\s*\+=' \
        && { echo "it still holds part of the cache back by age, but the cleanup takes all of it"; false; }
    echo "$body" | grep -q "Reclaimable" \
        || { echo "it must read buildkit's own Reclaimable flag"; false; }
    :
}

# ─── The shared login must know every hostname it is put in front of ─────────

# Authelia's access_control is deny by default, on purpose: a hostname carrying
# the middleware but missing from the rules is refused rather than waved
# through. The consequence is that a module answering on more than one
# hostname must declare them all, or the undeclared ones return 403 to
# everything including their bypassed paths, with no way to sign in.
#
# n8n is the module this happens to: it answers on a second name because a
# browser blocklist flagged the first, and `flows.` was hard-denied while
# `n8n.` worked.
@test "a module with several hostnames declares them for the shared login" {
    local f svc offenders=""
    for f in "${REPO_ROOT}"/lib/services/*.sh; do
        svc=$(basename "$f" .sh)
        # The signal is ONE router answering on several names, not a module
        # containing several routers. monitoring ships Grafana and Uptime
        # Kuma, and nextcloud ships the app and the whiteboard; each has its
        # own router with its own single hostname, and counting Host() per
        # file flagged both of them wrongly.
        #
        # One router with several names takes one of two forms: a rule joining
        # Host() clauses with ||, or a helper that builds the rule from a list.
        if grep -qE '_host_rule\(\)' "$f" \
        || grep -qE 'Host\(.*\)[[:space:]]*\|\|[[:space:]]*Host\(' "$f"; then
            grep -q "^${svc}_hostnames()" "$f" \
                || offenders+=" ${svc}"
        fi
    done
    [ -z "$offenders" ] || {
        echo "These answer on more than one hostname but declare no <svc>_hostnames():$offenders"
        echo "Authelia would list only <svc>.DOMAIN and deny the rest with 403."
        false
    }
}

# A browser that has ever cached a basic-auth credential for a protected
# hostname sends it on every request afterwards. With the default forward-auth
# strategy list Authelia inspects that header, fails to authenticate it, and
# answers 401 with WWW-Authenticate: Basic, which is what makes a browser show
# its own sign-in dialog. The single-page app retries and the dialog returns:
# 325 challenges in thirty minutes on n8n, and nothing the operator types into
# it can help, because Authelia is not offering its own credentials there.
@test "the shared login never challenges for basic auth" {
    local cfg="${REPO_ROOT}/lib/services/authelia.sh"
    grep -q "authn_strategies:" "$cfg" \
        || { echo "forward-auth has no authn_strategies, so it defaults to inspecting the Authorization header and will challenge Basic"; false; }
    # Cookie sessions only. Naming HeaderAuthorization or BasicAuth puts the
    # challenge back.
    local block
    block=$(awk '/authn_strategies:/,/^[a-z]/' "$cfg")
    echo "$block" | grep -q "CookieSession" \
        || { echo "CookieSession must be among the strategies or nothing can sign in"; false; }
    echo "$block" | grep -qiE "HeaderAuthorization|name: .BasicAuth" \
        && { echo "a header strategy is listed, which re-enables the WWW-Authenticate: Basic challenge"; false; }
    :
}

@test "authelia asks the module for its hostnames rather than assuming one" {
    # The regression guarded here is subtle and silent: building the module
    # path in the same `local` statement that declares the variable it
    # references yields an empty expansion, the file is not found, and the
    # helper falls back to the module name. That is the old broken behaviour,
    # so the bug reappears looking exactly like a working fix.
    local body
    body=$(awk '/^_authelia_hostnames_for\(\)/,/^}/' "${REPO_ROOT}/lib/services/authelia.sh")
    [ -n "$body" ] || { echo "_authelia_hostnames_for is gone"; false; }
    echo "$body" | grep -qE 'local svc="\$1"[[:space:]]*$' \
        || { echo "svc must be declared on its own line, or \${svc} in the module path expands empty"; false; }
    echo "$body" | grep -q '_hostnames' \
        || { echo "it no longer asks the module for its hostnames"; false; }
    # And the writer must use it for both the protected list and the bypasses.
    local cfg="${REPO_ROOT}/lib/services/authelia.sh"
    [ "$(grep -c '_authelia_hostnames_for "\$r"' "$cfg")" -ge 2 ] \
        || { echo "the protected list and the bypass block must both expand every hostname"; false; }
}

# ─── Databases and caches stay off the web-facing network ────────────────────

# proxy-net is shared by every web-facing container and by cloudflared, so a
# database sitting on it is reachable by all of them. Postgres, MariaDB and
# Redis were all there. Redis is the worst of the three because it
# authenticates nothing: `occ config:system:get redis` shows an empty
# password, so any container on proxy-net could issue commands to it.
#
# An application keeps a foot in both networks. Its database keeps only
# backend-net.
@test "no database or cache container sits on proxy-net" {
    local f base offenders=""
    for f in "${REPO_ROOT}"/lib/services/*.sh; do
        base="$(basename "$f")"
        # Track the most recent container_name, then check the networks line
        # that belongs to the same service block.
        offenders+="$(awk -v mod="$base" '
            /container_name:/ {
                name = $NF
                gsub(/["\047]/, "", name)
                next
            }
            /^[[:space:]]*networks:[[:space:]]*\[/ {
                if (name ~ /(-db|-redis)$/ && $0 ~ /proxy-net/)
                    printf "%s: %s -> %s\n", mod, name, $0
            }
        ' "$f")"
    done
    if [[ -n "${offenders//[[:space:]]/}" ]]; then
        echo "These are reachable from every web-facing container:"
        echo "$offenders"
        echo "Put them on backend-net only. The app keeps both networks."
        false
    fi
}

@test "every module that names backend-net also declares it external" {
    local f base
    for f in "${REPO_ROOT}"/lib/services/*.sh; do
        base="$(basename "$f")"
        grep -q 'networks: \[.*backend-net' "$f" || continue
        # A compose file that references a network it never declares fails
        # with "network backend-net declared as external, but could not be
        # found", or silently invents a project-scoped one, which is worse:
        # the containers come up on a network the database is not on.
        grep -qE '^[[:space:]]*backend-net:[[:space:]]*\{[[:space:]]*external:' "$f" \
            || { echo "$base uses backend-net without declaring it external"; false; }
    done
}

# The Traefik dashboard once had its publish changed to 127.0.0.1 in code
# while deployed instances kept 0.0.0.0, which is what this file's header
# describes. Prometheus had the same shape and worse consequences: it
# authenticates nothing, its API can delete series, and a published port
# bypasses UFW, so it answered the whole LAN while `ufw status` listed no rule
# for it. Anything with no login of its own binds to loopback.
@test "services with no authentication publish only on loopback" {
    local f base offenders=""
    for f in "${REPO_ROOT}"/lib/services/*.sh; do
        base="$(basename "$f")"
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            offenders+="${base}: ${line}"$'\n'
        done < <(grep -oE 'ports: \[?"(0\.0\.0\.0:)?(9090|8080):[0-9]+"' "$f" || true)
    done
    if [[ -n "${offenders//[[:space:]]/}" ]]; then
        echo "Bind these to 127.0.0.1, they have no login:"
        echo "$offenders"
        false
    fi
}

# ─── Credential loading must be identical everywhere ─────────────────────────

@test "cred_get trims column padding and keeps internal spaces" {
    # The credentials file is column-aligned. Keeping the padding sends
    # "      nJBrU8gc..." as a password, which fails against a database
    # initialised with the trimmed value. Splitting on whitespace instead
    # truncates any password containing a space.
    export CRED_FILE="${BATS_TEST_TMPDIR}/creds.txt"
    printf 'MySQL Root:      abc123XYZ\n'            > "$CRED_FILE"
    printf 'Immich DB:       nJBrU8gc2EwCg384\n'    >> "$CRED_FILE"
    printf 'Time Machine:    pass with spaces\n'    >> "$CRED_FILE"
    printf 'Vaultwarden:     tok_9\n'               >> "$CRED_FILE"
    # shellcheck disable=SC1090
    source "${REPO_ROOT}/lib/common.sh"

    [ "$(cred_get 'MySQL Root:')"   = "abc123XYZ" ]
    [ "$(cred_get 'Immich DB:')"    = "nJBrU8gc2EwCg384" ]
    [ "$(cred_get 'Time Machine:')" = "pass with spaces" ]
    [ "$(cred_get 'Vaultwarden:')"  = "tok_9" ]
}

@test "no script reads a credential without stripping the column padding" {
    # lib/preflight.sh used awk on a field number while corex-manage.sh used
    # sed that kept the padding, so the two resolved the same credential to
    # different strings. Immich lost access to its own database on repair.
    #
    # This test used to require the pipe to follow "$CRED_FILE" immediately,
    # which meant a `2>/dev/null` in between hid the offender. lib/backup.sh
    # had exactly that shape, and the padding it left in the Restic password
    # meant the generated backup script could not open the repository it was
    # paired with: every nightly run failed and logged "Backup complete".
    #
    # So the check is on the defect rather than on the technique. A generated
    # standalone script cannot source common.sh, so it has to inline the
    # parse; what it must not do is take one space off and keep the rest.
    # Comments are excluded, and that is not laziness. This repo deliberately
    # keeps a comment recording a trap so it is not reintroduced, and the
    # comment in lib/backup.sh quotes the broken expression in order to
    # explain it. A check that cannot tell a warning from the thing it warns
    # about fails on the documentation, which is the same mistake as matching
    # the word "claude" instead of an attribution trailer.
    local offenders=""
    for f in "${REPO_ROOT}"/*.sh "${REPO_ROOT}"/lib/*.sh "${REPO_ROOT}"/lib/services/*.sh; do
        [ -f "$f" ] || continue
        local code
        code="$(grep -vE '^[[:space:]]*#' "$f")"
        # A sed that consumes exactly one space after the colon.
        echo "$code" | grep -qE "s/\^\[\^:\]\*: //" && offenders+=" $(basename "$f"):sed"
        # An awk field split, which loses any internal space in the value.
        echo "$code" | grep -qE 'CRED_FILE.*\| *awk' && offenders+=" $(basename "$f"):awk"
    done
    [ -z "$offenders" ] || {
        echo "credential parsing that keeps the padding, in:$offenders"
        echo "Fix: cred_get from lib/common.sh, or inline its exact expression:"
        echo "  sed -e 's/^[^:]*:[[:space:]]*//' -e 's/[[:space:]]*\$//'"
        false
    }
}

@test "traefik persists the Cloudflare DNS token so repair cannot downgrade ACME" {
    # The token lived only in the environment of whoever ran the command.
    # repair regenerates traefik.yml unconditionally, so a repair without the
    # variable exported rewrote the resolver back to tlsChallenge and restored
    # the wildcard defaultCertificate, undoing DNS-01. Certificates already in
    # acme.json kept working, so the only symptom was that a newly added
    # hostname got the self-signed CA.
    local f="${REPO_ROOT}/lib/services/traefik.sh"
    grep -q '_traefik_cf_token' "$f"
    grep -q '.cf-dns-token' "$f"
    grep -q 'chmod 600 "$token_file"' "$f"

    # The challenge choice must consult the resolved token, not the raw env
    # var, or the persistence is bypassed.
    local body
    body=$(awk '/^_traefik_write_configs\(\)/,/^}/' "$f")
    echo "$body" | grep -q 'cf_token=\$(_traefik_cf_token)'
    run bash -c "echo '$body' | grep -c 'if \[\[ -n \"\\\${CLOUDFLARE_DNS_API_TOKEN:-}\" \]\]'"
    [ "$output" = "0" ]
}

@test "traefik file provider reads a directory so services can add routes" {
    # A single dynamic.yml cannot be extended, which left no way to route a
    # backend Traefik cannot discover by label (Coolify sits on its own
    # network with no interface on proxy-net).
    local f="${REPO_ROOT}/lib/services/traefik.sh"
    grep -q 'directory: /dynamic' "$f"
    run grep -c 'filename: /dynamic.yml' "$f"
    [ "$output" = "0" ]
    grep -q './dynamic:/dynamic:ro' "$f"
    # Coolify must write into that directory from deploy and from repair.
    local c="${REPO_ROOT}/lib/services/coolify.sh"
    grep -q '_coolify_write_route' "$c"
    for fn in coolify_deploy coolify_repair; do
        awk "/^${fn}\(\)/,/^}/" "$c" | grep -q '_coolify_write_route' || {
            echo "$fn does not write the Traefik route"
            false
        }
    done
    awk '/^coolify_destroy\(\)/,/^}/' "$c" | grep -q 'rm -f.*coolify.yml'
}

# ─── corex update must not refuse when there is nothing to pull ──────────────

@test "update checks for local changes only after finding commits to pull" {
    # The check ran before the fetch, so it aborted on a repo that was exactly
    # in sync and had nothing to overwrite. Three stray macOS "._name" files
    # were enough to make `corex update` demand --force.
    local body
    body=$(awk '/^do_update\(\)/,/^}/' "${REPO_ROOT}/corex.sh")
    local behind_line dirty_line
    behind_line=$(echo "$body" | grep -n 'behind=\$(git rev-list --count' | head -1 | cut -d: -f1)
    dirty_line=$(echo "$body" | grep -n 'dirty=\$(git status --porcelain' | head -1 | cut -d: -f1)
    [ -n "$behind_line" ]
    [ -n "$dirty_line" ]
    [ "$behind_line" -lt "$dirty_line" ]
}

@test "update ignores untracked files that no incoming commit touches" {
    # git pull does not overwrite an untracked file unless an incoming commit
    # writes that same path, so only a collision should block.
    local body
    body=$(awk '/^do_update\(\)/,/^}/' "${REPO_ROOT}/corex.sh")
    echo "$body" | grep -q 'untracked-files=no'
    echo "$body" | grep -q 'git diff --name-only HEAD..origin/main'
    echo "$body" | grep -q 'git ls-files --others --exclude-standard'
}

@test "AppleDouble sidecars are gitignored" {
    grep -qx '\._\*' "${REPO_ROOT}/.gitignore"
}

@test "update fails loudly when it cannot ask for confirmation" {
    # read returns an empty answer with no terminal, so the prompt printed a
    # bare "Aborted." and returned 0. A cron job or a sudo -n invocation
    # reported success while updating nothing.
    local body
    body=$(awk '/^do_update\(\)/,/^}/' "${REPO_ROOT}/corex.sh")
    echo "$body" | grep -q '! -t 0'
    # The no-terminal branch must return non-zero.
    echo "$body" | grep -A 8 '! -t 0' | grep -q 'return 1'
    # --force must be a usable non-interactive path, so it has to be tested
    # BEFORE the terminal check or it cannot be used without a terminal.
    local force_line tty_line
    force_line=$(echo "$body" | grep -n 'confirm="y"' | head -1 | cut -d: -f1)
    tty_line=$(echo "$body" | grep -n '! -t 0' | head -1 | cut -d: -f1)
    [ -n "$force_line" ]
    [ -n "$tty_line" ]
    [ "$force_line" -lt "$tty_line" ]
}

@test "update dispatch forwards its flags to do_update" {
    # The case branch called do_update with no arguments, so --force never
    # arrived and `corex update --force` behaved exactly like `corex update`.
    # The warning told the user to run a flag that could not work.
    local branch
    branch=$(awk '/^    update\)/,/^        ;;/' "${REPO_ROOT}/corex.sh")
    echo "$branch" | grep -q 'shift'
    echo "$branch" | grep -qE 'do_update "\$@"'
}

# ─── update must look at every image in a stack ──────────────────────────────

@test "update does not decide a whole stack from one image" {
    # The digest shortcut read `config --images | head -1`, so one current
    # image was enough to skip the rest. monitoring ships five and ai three,
    # and the one it always checked (node-exporter) rarely changes, so
    # uptime-kuma sat ten months behind while every run reported success.
    local body
    body=$(awk '/^_update_single\(\)/,/^}/' "${REPO_ROOT}/corex-manage.sh")
    run bash -c "echo '$body' | grep -c 'config --images 2>/dev/null | head -1'"
    [ "$output" = "0" ]
    # It must iterate the images.
    echo "$body" | grep -q 'while IFS= read -r img'
}

@test "update fails when the pull or the restart fails" {
    # pull ran unchecked and success was logged either way, so a rate limit or
    # an expired tag was indistinguishable from an update.
    local body
    body=$(awk '/^_update_single\(\)/,/^}/' "${REPO_ROOT}/corex-manage.sh")
    echo "$body" | grep -qE 'if ! docker compose .* pull'
    echo "$body" | grep -qE 'if ! docker compose .* up -d'
    echo "$body" | grep -q 'return 1'
}

@test "update --all names the services that failed" {
    local body
    body=$(awk '/^cmd_update\(\)/,/^}/' "${REPO_ROOT}/corex-manage.sh")
    echo "$body" | grep -q 'failed+=" \$svc"'
    echo "$body" | grep -q 'Services that did not update'
}

# ─── Nothing gets indexed ────────────────────────────────────────────────────

@test "X-Robots-Tag is applied at the entrypoint, not per service" {
    # A per-service label is one forgotten label away from a hostname being
    # indexable, and a service that sets its own value wins over the global
    # one because router middlewares run after entrypoint middlewares.
    local f="${REPO_ROOT}/lib/services/traefik.sh"
    grep -q 'noindex@file' "$f"
    grep -q 'X-Robots-Tag: "noindex, nofollow, noarchive, nosnippet, noimageindex, notranslate"' "$f"

    # The entrypoint carries it.
    awk '/^  websecure:/,/^providers:/' "$f" | grep -q 'noindex@file'

    # No service may set X-Robots-Tag itself.
    local offenders=""
    for m in "${REPO_ROOT}"/lib/services/*.sh; do
        [ "$(basename "$m")" = "traefik.sh" ] && continue
        grep -q 'X-Robots-Tag=' "$m" && offenders+=" $(basename "$m")"
    done
    [ -z "$offenders" ] || {
        echo "services setting X-Robots-Tag themselves:$offenders"
        echo "It is set once on the websecure entrypoint."
        false
    }
}

# ─── Node services need a deliberate heap, not an inferred one ───────────────

@test "node services have enough memory for their heap" {
    # n8n crash-looped 33 times on a 512m limit with "JavaScript heap out of
    # memory", dying at a ~250MB heap: Node sizes its old-space from the
    # cgroup limit, so 512m gives it roughly 256MB. OOMKilled stayed false
    # because Node killed itself rather than the kernel killing the container,
    # so nothing in docker pointed at memory.
    local f="${REPO_ROOT}/lib/services/n8n.sh"
    grep -qE '^\s+memory: 1536m' "$f"
    grep -q 'max-old-space-size' "$f"

    # And the heap cap must stay below the container limit, or the kernel
    # OOM-kills the container instead of Node collecting.
    local limit heap
    limit=$(grep -oE 'memory: ([0-9]+)m' "$f" | head -1 | grep -oE '[0-9]+')
    heap=$(grep -oE 'max-old-space-size=([0-9]+)' "$f" | head -1 | grep -oE '[0-9]+')
    [ -n "$limit" ]
    [ -n "$heap" ]
    [ "$heap" -lt "$limit" ]
}

@test "uptime-kuma is not left on a 1.x-sized memory limit" {
    # 2.x is heavier than the 1.x line it was pinned up from. Scoped to the
    # uptime-kuma block: cadvisor sits at 256m and is Go, so it is fine there.
    local block limit
    # A comma range would end on its own start line, since "  uptime-kuma:"
    # also matches "^  [a-z]". Skip the start line, then stop at the next
    # service at the same indent.
    block=$(awk '/^  uptime-kuma:/{f=1;next} f&&/^  [a-z]/{exit} f' \
        "${REPO_ROOT}/lib/services/monitoring.sh")
    limit=$(echo "$block" | grep -oE 'memory: ([0-9]+)m' | head -1 | grep -oE '[0-9]+')
    [ -n "$limit" ]
    [ "$limit" -ge 512 ]
}

@test "n8n can answer on more than one hostname, first is primary" {
    # A hostname can be blocked by something outside the service: Safe
    # Browsing flagged n8n.DOMAIN while n8n kept returning HTTP 200, and
    # Chrome then refuses it everywhere including the LAN. Keeping a second,
    # unflagged name routed means a URL that opens while a review is pending.
    local f="${REPO_ROOT}/lib/services/n8n.sh"
    grep -q '_n8n_subdomains' "$f"
    grep -q '_n8n_host_rule' "$f"

    # The primary must drive the links n8n generates about itself, or webhooks
    # point at the wrong host.
    grep -q 'N8N_HOST: "${sub}.${DOMAIN}"' "$f"
    grep -q 'WEBHOOK_URL: "https://${sub}.${DOMAIN}"' "$f"
    # And the router rule must cover every configured name.
    grep -q 'routers.n8n.rule=${host_rule}' "$f"

    # _n8n_subdomain takes the first word of the list.
    awk '/^_n8n_subdomain\(\)/,/^}/' "$f" | grep -q '${subs%% \*}'
}

# ─── Routes for containers CoreX did not deploy ──────────────────────────────

@test "corex manage route validates its inputs" {
    # A malformed hostname yields a router Traefik silently ignores, and a
    # backend without a scheme is rejected at load along with the rest of the
    # file, taking every other route in it down with it.
    local body
    body=$(awk '/^cmd_route\(\)/,/^}/' "${REPO_ROOT}/corex-manage.sh")
    echo "$body" | grep -q 'Not a hostname'
    echo "$body" | grep -q 'Backend must be http'
    echo "$body" | grep -qE 'https\?://'
}

@test "route files live where a traefik repair will not delete them" {
    # _traefik_write_configs must only ever touch its own generated file, or a
    # repair would silently drop every user route.
    grep -q 'route_dir="\${DOCKER_ROOT}/traefik/dynamic"' "${REPO_ROOT}/corex-manage.sh"
    local body
    body=$(awk '/^_traefik_write_configs\(\)/,/^}/' "${REPO_ROOT}/lib/services/traefik.sh")
    # The only removal allowed in there is the legacy single dynamic.yml.
    local removals
    removals=$(echo "$body" | grep -cE 'rm -[rf]+ .*dynamic' || true)
    [ "$removals" -le 1 ]
    echo "$body" | grep -qE 'rm -f "\$\{dir\}/dynamic\.yml"'
    # And it must not wipe the directory.
    run bash -c "echo '$body' | grep -c 'rm -rf .*dynamic'"
    [ "$output" = "0" ]
}

@test "an https backend gets the insecure-backend transport" {
    # Portainer's certificate is issued for 0.0.0.0, so verification against a
    # container name or IP fails and Traefik returns 500.
    local body
    body=$(awk '/^cmd_route\(\)/,/^}/' "${REPO_ROOT}/corex-manage.sh")
    echo "$body" | grep -q 'serversTransport: insecure-backend'
}

# ─── A disabled service must stay disabled ───────────────────────────────────

@test "state_service_is_enabled distinguishes false from absent" {
    # jq's alternative operator treats false as absent, so `.enabled // true`
    # evaluates to true for a disabled service and the flag read back as
    # enabled no matter what was written.
    export COREX_STATE_FILE="${BATS_TEST_TMPDIR}/enabled.json"
    # shellcheck disable=SC1090
    source "${REPO_ROOT}/lib/state.sh"
    state_init
    state_service_installed grafana
    state_service_installed n8n

    state_service_is_enabled grafana          # absent or true means enabled
    state_service_disable grafana
    run state_service_is_enabled grafana
    [ "$status" -ne 0 ]                        # now disabled
    state_service_is_enabled n8n               # unaffected
    state_service_enable grafana
    state_service_is_enabled grafana           # re-enabled
    state_service_is_enabled never-installed   # unknown defaults to enabled
}

@test "the enabled flag is read, not just written" {
    # It was written by `corex manage disable` and read by nothing, so
    # disabling a service stopped it and the next doctor run saw a stopped
    # container, called it UNHEALTHY and started it again.
    grep -q 'state_service_is_enabled' "${REPO_ROOT}/lib/state.sh"
    local m="${REPO_ROOT}/corex-manage.sh"
    # repair must skip it, or nothing stays off.
    awk '/^cmd_repair\(\)/,/^}/' "$m" | grep -q 'state_service_is_enabled'
    # update must skip it too, since `up -d` would start it.
    awk '/^cmd_update\(\)/,/^}/' "$m" | grep -q 'state_service_is_enabled'
    # and status must say DISABLED rather than UNHEALTHY.
    grep -q 'DISABLED' "$m"
}

@test "no jq alternative operator on a boolean field" {
    # `.bool // default` is a trap: false takes the default.
    local offenders=""
    for f in "${REPO_ROOT}"/lib/*.sh "${REPO_ROOT}"/*.sh; do
        [ -f "$f" ] || continue
        # Allow for a closing paren before the operator: `.enabled) //` is the
        # same trap and the narrower pattern missed it, which let the bug back
        # in via state_service_installed.
        grep -qE '\.enabled\)?[[:space:]]*//' "$f" && offenders+=" $(basename "$f")"
    done
    [ -z "$offenders" ] || {
        echo "jq // used on a boolean field in:$offenders"
        false
    }
}

# ─── Removal must close the ports it opened ──────────────────────────────────

@test "every module that opens a port declares how to revoke it" {
    # No <svc>_destroy revoked anything, so removing a service left its rules
    # in place forever. Uninstalling Stalwart left 25, 143, 465, 587 and 993
    # open to the internet with nothing listening behind them.
    local offenders=""
    for f in "${REPO_ROOT}"/lib/services/*.sh; do
        grep -q 'ufw allow' "$f" || continue
        grep -q '^SERVICE_FIREWALL_SPECS=' "$f" || offenders+=" $(basename "$f" .sh)"
    done
    [ -z "$offenders" ] || {
        echo "modules opening ports with no SERVICE_FIREWALL_SPECS:$offenders"
        false
    }
}

@test "declared firewall specs cover every port the module opens" {
    # A spec list that misses a rule leaves that port open on removal.
    local offenders=""
    for f in "${REPO_ROOT}"/lib/services/*.sh; do
        grep -q '^SERVICE_FIREWALL_SPECS=' "$f" || continue
        local svc opened declared p
        svc=$(basename "$f" .sh)
        # Cut the line at `comment` and at the `2>/dev/null` redirect first,
        # or the 2 from the redirect counts as a port.
        opened=$(grep -oE 'ufw allow [^#]*' "$f" \
            | sed -e 's/comment.*//' -e 's/2>.*//' \
            | grep -oE '\b[0-9]+(:[0-9]+)?\b' | sort -u)
        declared=$(grep '^SERVICE_FIREWALL_SPECS=' "$f" \
            | grep -oE '\b[0-9]+(:[0-9]+)?\b' | sort -u)
        for p in $opened; do
            echo "$declared" | grep -qx "$p" || offenders+=" ${svc}:${p}"
        done
    done
    [ -z "$offenders" ] || {
        echo "ports opened but not declared for revocation:$offenders"
        false
    }
}

@test "cmd_remove revokes the firewall rules after destroy" {
    local body
    body=$(awk '/^cmd_remove\(\)/,/^}/' "${REPO_ROOT}/corex-manage.sh")
    echo "$body" | grep -q 'ufw_revoke'
    # And it must run after destroy, not before.
    local d r
    d=$(echo "$body" | grep -n '"destroy"' | head -1 | cut -d: -f1)
    r=$(echo "$body" | grep -n 'ufw_revoke' | head -1 | cut -d: -f1)
    [ "$d" -lt "$r" ]
}

# ─── Disable must work for a service that installs its own stack ─────────────

@test "enable and disable do not require a CoreX compose file" {
    # Both hard-failed with "No compose file", so neither worked for Coolify,
    # which installs its own stack. It could not be switched off through CoreX
    # at all.
    local m="${REPO_ROOT}/corex-manage.sh"
    grep -q '_service_containers' "$m"
    for fn in cmd_enable cmd_disable; do
        awk "/^${fn}\(\)/,/^}/" "$m" | grep -q '_service_containers' || {
            echo "$fn still depends on a compose file"
            false
        }
    done
}

@test "disable clears restart=always so a reboot does not undo it" {
    # A container on restart=always comes back when the daemon restarts even
    # though it was stopped deliberately. Coolify's five containers were all
    # on always, so stopping them would not have survived a reboot.
    local body
    body=$(awk '/^cmd_disable\(\)/,/^}/' "${REPO_ROOT}/corex-manage.sh")
    echo "$body" | grep -q 'docker update --restart=no'
    # And the policy change must come before the stop, not after.
    local u s
    u=$(echo "$body" | grep -n 'restart=no' | head -1 | cut -d: -f1)
    s=$(echo "$body" | grep -n 'docker stop' | head -1 | cut -d: -f1)
    [ "$u" -lt "$s" ]
}

@test "enable restores a restart policy that disable removed" {
    # Otherwise a re-enabled service runs until the next reboot and then stays
    # down, which is worse than either state.
    local body
    body=$(awk '/^cmd_enable\(\)/,/^}/' "${REPO_ROOT}/corex-manage.sh")
    echo "$body" | grep -q 'restart=unless-stopped'
}

# ─── Disks: a swap or a replacement has to come back on its own ───────────────

# The installer labels both partitions and then wrote fstab entries keyed on
# UUID, which belongs to one filesystem. Replacing the SSD, or restoring onto a
# new one, produced a disk that would not mount however correct its contents.
@test "the installer mounts the data partition by label, not UUID" {
    run grep -c 'LABEL=COREX_DATA .*MOUNT_POOL\|LABEL=COREX_DATA \$MOUNT_POOL' "${REPO_ROOT}/lib/drive.sh"
    [ "$status" -eq 0 ]
}

# nofail lets a headless box boot without the data disk, which is right. What
# was wrong is that Docker then started anyway and every bind mount created an
# empty directory on the root filesystem, so the databases initialised fresh
# and the box came up looking new instead of looking broken.
@test "Docker is made to require the data mount" {
    grep -q "RequiresMountsFor" "${REPO_ROOT}/lib/disks.sh"
}

@test "the data mount keeps nofail so a missing disk still boots to a shell" {
    # disks.sh builds the line from variables, so match the options it writes
    # rather than a literal that only exists once expanded.
    grep -qE 'ext4 defaults,noatime,nofail' "${REPO_ROOT}/lib/disks.sh"
    grep -qE 'LABEL=COREX_DATA .*nofail' "${REPO_ROOT}/lib/drive.sh"
}

# Writing LABEL= for a label nothing carries is how a box stops booting
# cleanly, so both writers check before they commit to it.
@test "nothing writes a LABEL= fstab entry without checking the label exists" {
    grep -q "blkid -L" "${REPO_ROOT}/lib/disks.sh"
    grep -qE "blkid -s LABEL|e2label" "${REPO_ROOT}/lib/drive.sh"
}

@test "disk adopt refuses the disk holding the running system" {
    grep -q "holds the running system" "${REPO_ROOT}/lib/disks.sh"
}

@test "disk adopt demands a typed confirmation" {
    grep -q 'DESTROY' "${REPO_ROOT}/lib/disks.sh"
}

# lsblk -r leaves empty columns empty, and bash collapses runs of IFS
# whitespace, so a tab separator shifted every later value one place left and
# the listing reported the mountpoint as the label.
@test "the disk listing does not split lsblk output on IFS whitespace" {
    ! grep -q "IFS=\$'\\\\t' read -r dev size tran" "${REPO_ROOT}/lib/disks.sh"
    grep -q "IFS='|' read -r dev size tran" "${REPO_ROOT}/lib/disks.sh"
}

# ─── Fast tier ────────────────────────────────────────────────────────────────

# A module regenerates its compose file on every repair (gotcha #22), so a path
# edited there is reverted the next time anyone runs `corex manage repair`, and
# the database then starts against an empty directory on the old disk and
# initialises itself fresh. The bind keeps the path the module writes and
# changes only what is behind it.
@test "the fast tier moves databases with bind mounts, not compose edits" {
    grep -q "none bind,nofail" "${REPO_ROOT}/lib/disks.sh"
    ! grep -qE "sed .*docker-compose.yml" "${REPO_ROOT}/lib/disks.sh"
}

# A bind that failed while its filesystem mounted is the same catastrophe in a
# smaller costume, so Docker requires each bind target and not just the disk.
@test "the docker guard covers each fast-tier bind target" {
    grep -q "RequiresMountsFor=\${src}" "${REPO_ROOT}/lib/disks.sh"
}

# These four directories run as four different uids that the database images
# check on startup.
@test "the fast tier copy preserves ownership numerically" {
    grep -q "rsync -aHAX --numeric-ids" "${REPO_ROOT}/lib/disks.sh"
}

# Deleting the source before the destination has proved itself leaves no way
# back if a database refuses to open on the new disk.
@test "the fast tier keeps the original until it is committed" {
    grep -q "pre-fast" "${REPO_ROOT}/lib/disks.sh"
    grep -q "disks_fast_commit" "${REPO_ROOT}/lib/disks.sh"
}

@test "fast-commit refuses to delete an original that is not yet replaced" {
    grep -q "is not reading from the fast disk; keeping" "${REPO_ROOT}/lib/disks.sh"
}

# ─── Update status ────────────────────────────────────────────────────────────

# The check answers from a cache held for a day, and nothing invalidated it
# when an update ran. So a service that had just been updated kept its "Update
# available" badge and kept offering the button for up to 24 hours, which reads
# as the update having silently failed. The check itself was never wrong: run
# fresh against a service reporting an update, both digests matched exactly.
@test "an update re-checks the service it just updated" {
    grep -q "_update_recheck" "${REPO_ROOT}/corex-manage.sh"
    grep -q "def recheck" "${REPO_ROOT}/agent/corex_updates.py"
}

@test "the re-check runs for every service in an update-all, not just a single one" {
    # _update_single is what update-all loops over, so the call belongs there
    # rather than beside the single-service branch.
    run bash -c "awk '/^_update_single\(\)/,/^}/' '${REPO_ROOT}/corex-manage.sh' | grep -c _update_recheck"
    [ "$output" -ge 1 ]
}

# A failed registry lookup afterwards must not turn a successful update into a
# reported failure.
@test "the re-check can never fail an update" {
    run bash -c "awk '/^_update_recheck\(\)/,/^}/' '${REPO_ROOT}/corex-manage.sh' | grep -c 'return 0'"
    [ "$output" -ge 1 ]
}

# An update is not the only thing that replaces an image: a repair, the
# scheduled maintenance, or someone at a shell all pull too. So the verdict
# records the digest it was made about, and a local comparison catches every
# one of those without a registry round trip.
@test "every verdict records the image digest it was judged on" {
    run grep -c '"local": _base\|"local": local\[0\]' "${REPO_ROOT}/agent/corex_updates.py"
    [ "$output" -ge 4 ]
}

@test "a cached verdict is discarded when its image has moved underneath it" {
    grep -q "_answer_is_about_a_different_image" "${REPO_ROOT}/agent/corex_updates.py"
    grep -q "the local image changed since this was checked" "${REPO_ROOT}/agent/corex_updates.py"
}

# Reporting unknown keeps the Update button where it was. Claiming "current"
# on an answer we know is about a different image would hide a working control
# on a stale claim.
@test "an invalidated verdict becomes unknown, not current" {
    run bash -c "grep -A 4 'the local image changed since this was checked' '${REPO_ROOT}/agent/corex_updates.py' | grep -c 'unknown'"
    [ "$output" -ge 0 ]
    grep -q '"state": "unknown", "images": \[\]' "${REPO_ROOT}/agent/corex_updates.py"
}

# A cold container stopped on purpose is asleep, not broken. Requiring exit 0
# reported every correctly sleeping Portainer as UNHEALTHY, because measured on
# that image a clean `docker stop` leaves exit code 2, not 0 and not 143.
# doctor would then "repair" it by starting it, defeating cold mode.
# The logic moved into container_stopped_deliberately in common.sh, because
# keeping a copy per module is how portainer came to accept 0/2/143 while
# monitoring accepted only 0. The property is unchanged; only its address is.
@test "the cold-mode check accepts the exit codes a clean stop really produces" {
    local alts
    # The one case line that lists the accepted codes, as a pipe-separated set.
    alts=$(awk '/^container_stopped_deliberately\(\)/,/^}/' "${REPO_ROOT}/lib/common.sh" \
           | grep -oE '^[[:space:]]*[0-9|]+\)' | tr -d ' )')
    [ -n "$alts" ] || { echo "no exit-code case found in the helper"; false; }
    local c
    for c in 0 2 137 143; do
        [[ "|${alts}|" == *"|${c}|"* ]] \
            || { echo "exit code ${c} is not accepted as a deliberate stop (got: ${alts})"; false; }
    done
}

# OOMKilled stays true until the container is recreated (gotcha #29), so a
# container killed for memory must never read as a deliberate stop.
@test "a cold container killed for memory is not reported as sleeping" {
    run bash -c "awk '/^container_stopped_deliberately\(\)/,/^}/' '${REPO_ROOT}/lib/common.sh' | grep -c 'OOMKilled'"
    [ "$output" -ge 1 ]
}

# ─── The host must end up resolving through AdGuard ──────────────────────────

# The public resolvers AdGuard writes during deploy are a bootstrap step, valid
# only until AdGuard itself can answer. For a long time nothing switched back,
# so every install left the box resolving its own hostnames to the public edge:
# measured at 5.03s of DNS and 6.60s total for a request to a service the same
# machine was running, against 0.04s pinned to the LAN address. Uptime Kuma
# runs on the box, so its own checks took that path too.
@test "adguard hands the host resolver back to itself" {
    local f="${REPO_ROOT}/lib/services/adguard.sh"
    grep -q "_adguard_own_the_resolver" "$f" \
        || { echo "nothing switches the host off the bootstrap resolvers"; false; }
    # Called from deploy, not merely defined.
    awk '/^adguard_deploy\(\)/,/^}/' "$f" | grep -q "_adguard_own_the_resolver" \
        || { echo "the switch is defined but deploy never calls it"; false; }
}

# Writing a resolver the box cannot use is worse than leaving it wrong: it
# cannot then pull the image that would repair AdGuard. The switch has to prove
# a real lookup works and put the public resolvers back when it does not.
@test "the resolver switch verifies a lookup and rolls back" {
    local body
    body=$(awk '/^_adguard_own_the_resolver\(\)/,/^}/' "${REPO_ROOT}/lib/services/adguard.sh")
    echo "$body" | grep -q "getent hosts" \
        || { echo "nothing proves the new resolver actually resolves"; false; }
    echo "$body" | grep -q "nameserver 1.1.1.1" \
        || { echo "no rollback to a working resolver when the lookup fails"; false; }
}

# ─── An unclaimed media server must not be published ─────────────────────────

# A fresh Jellyfin answers a setup wizard with no password, and whoever
# finishes it becomes the administrator. Issuing the certificate publishes the
# hostname to the public Certificate Transparency logs, so the name is
# discoverable within minutes and secrecy is not a defence.
@test "a new jellyfin install starts restricted to the LAN" {
    local f="${REPO_ROOT}/lib/services/jellyfin.sh"
    grep -q "_jellyfin_guard_unclaimed_wizard" "$f" \
        || { echo "nothing keeps the unclaimed setup wizard off the internet"; false; }
    # It must run before the middleware label is computed, or it lands one
    # repair too late: the first install, the one that needed it, is published.
    local body guard_line label_line
    body=$(awk '/^jellyfin_deploy\(\)/,/^}/' "$f")
    guard_line=$(echo "$body" | grep -n "_jellyfin_guard_unclaimed_wizard" | head -1 | cut -d: -f1)
    label_line=$(echo "$body" | grep -n "sso_label_for jellyfin" | head -1 | cut -d: -f1)
    [ -n "$guard_line" ] && [ -n "$label_line" ]
    [ "$guard_line" -lt "$label_line" ] \
        || { echo "the guard runs after the label, so it takes effect one repair late"; false; }
}

# ─── The wizard must not quote a number it does not count ────────────────────

# The mode screen tells the reader how many services need a domain. A literal
# there is wrong the first time a module is added, and nothing fails when it
# drifts: the wizard just tells the next person something untrue at the one
# point where they cannot check it.
@test "the wizard counts domain-only services rather than naming a figure" {
    local body
    body=$(awk '/How you reach your services/,/configure-later/' "${REPO_ROOT}/lib/wizard.sh")
    echo "$body" | grep -q '_nd_count' \
        || { echo "the count is not computed"; false; }
    echo "$body" | grep -qE '\b(Nine|Ten|Eleven|Twelve|Thirteen|[0-9]+) services need' \
        && { echo "a hardcoded count is back in the mode screen"; false; }
    :
}

# Compose generation runs on every repair, so a download inside it makes repair
# depend on the network: on a box that cannot reach GitHub, the one command
# that fixes a broken service would sit waiting on an optional thumbnail. It
# also turned the two second smoke suite into a 145MB download.
@test "compose generation never reaches the network" {
    local body
    body=$(awk '/^_nextcloud_write_compose\(\)/,/^}/' "${REPO_ROOT}/lib/services/nextcloud.sh")
    echo "$body" | grep -qE 'curl|wget|_nextcloud_fetch_ffmpeg' \
        && { echo "_nextcloud_write_compose fetches something; move it to _dirs"; false; }
    :
}

# An air-gapped install, and any test, must be able to refuse the download and
# still get a working service.
@test "the ffmpeg fetch can be declined" {
    local body
    body=$(awk '/^_nextcloud_fetch_ffmpeg\(\)/,/^}/' "${REPO_ROOT}/lib/services/nextcloud.sh")
    echo "$body" | grep -q 'COREX_NO_DOWNLOADS' \
        || { echo "no way to decline the download"; false; }
    echo "$body" | grep -q 'connect-timeout' \
        || { echo "a dead network would hang rather than fail"; false; }
}

# The resolver switch waits for AdGuard to bind port 53, which is correct on a
# real box and is pure delay anywhere there is no AdGuard: it added 30s per
# adguard deploy to the smoke suite, taking it from seconds to 141s. Gate the
# wait on the container actually being there.
@test "the resolver switch does not wait when there is no adguard to wait for" {
    local body
    body=$(awk '/^_adguard_own_the_resolver\(\)/,/^}/' "${REPO_ROOT}/lib/services/adguard.sh")
    echo "$body" | grep -q 'declare -f container_running' \
        || { echo "the readiness wait is not gated on the container existing"; false; }
    # The gate must come before the polling loop, or it saves nothing.
    local gate_line poll_line
    gate_line=$(echo "$body" | grep -n 'declare -f container_running' | head -1 | cut -d: -f1)
    poll_line=$(echo "$body" | grep -n 'sleep 2' | head -1 | cut -d: -f1)
    [ -n "$gate_line" ] && [ -n "$poll_line" ] && [ "$gate_line" -lt "$poll_line" ] \
        || { echo "the gate is after the wait, so the wait still happens"; false; }
}

# ─── Video containers, and the LAN mask ──────────────────────────────────────

# A rewrap copies streams; a conversion decodes and re-encodes them. On this
# hardware that is the difference between 17 seconds at 66C and hours at full
# load, which is the workload that has actually tripped the machine. The copy
# flag is the whole safety property of this module.
@test "the video fix rewraps and never re-encodes" {
    local f="${REPO_ROOT}/lib/video.sh"
    grep -q '\-c copy' "$f" || { echo "the rewrap does not stream-copy"; false; }
    # Any codec selection means a re-encode.
    grep -qE '\-c:v +(libx|h264_|hevc_)|\-c:a +(aac|libmp3)' "$f" \
        && { echo "a re-encode has appeared in the rewrap path"; false; }
    :
}

# The original is the only copy, and a file that exists is not a file that
# plays. The new one is checked for the same duration before anything is
# removed.
@test "the video fix verifies before it replaces" {
    local body
    body=$(awk '/^_video_rewrap_one\(\)/,/^}/' "${REPO_ROOT}/lib/video.sh")
    echo "$body" | grep -q 'show_entries format=duration' \
        || { echo "nothing verifies the output before the original goes"; false; }
    local verify_line remove_line
    verify_line=$(echo "$body" | grep -n 'show_entries format=duration' | head -1 | cut -d: -f1)
    remove_line=$(echo "$body" | grep -n 'rm -f "\$src"' | head -1 | cut -d: -f1)
    [ -z "$remove_line" ] || [ "$verify_line" -lt "$remove_line" ] \
        || { echo "the original is removed before the check"; false; }
}

# Decided by the file's own bytes, not its extension. Plenty of .mov files are
# already MP4 inside, and rewrapping those is pointless work on gigabytes.
@test "the video fix reads the container brand, not the extension" {
    grep -q 'head -c 12' "${REPO_ROOT}/lib/video.sh" \
        || { echo "the container brand is not read from the file"; false; }
}

# A /24 is right in most houses and silently wrong everywhere else: on the /22
# a mesh system hands out, most of the wifi lands outside the allowlist and a
# LAN-only service answers 403 to devices in the same room, with no remedy from
# the client side.
@test "the LAN allowlist takes its mask from the interface" {
    local body
    body=$(awk '/_authelia_write_lan_middleware\(\)/,/^}/' "${REPO_ROOT}/lib/services/authelia.sh")
    echo "$body" | grep -q 'ip -o -4 addr show' \
        || { echo "the netmask is assumed rather than read"; false; }
    echo "$body" | grep -q 'ip_network' \
        || { echo "the network address is not computed from the real prefix"; false; }
}

# "Uploads are slow" is usually a negotiated link speed and almost never looks
# like a fault: nothing errors, every service answers, and the only evidence is
# a number nobody reads. A gigabit card on a 100Mb link caps the whole box at
# about 12MB/s. The check has to say which END is limiting, because a server
# whose card offers gigabit is not the thing to change.
@test "the network check reports the wired link and names the limiting end" {
    local body
    body=$(awk '/^_network_check_link\(\)/,/^}/' "${REPO_ROOT}/corex-manage.sh")
    echo "$body" | grep -q 'Link partner advertised' \
        || { echo "it does not look at what the other end offers"; false; }
    echo "$body" | grep -q 'Supported link modes' \
        || { echo "it does not look at what the card can do"; false; }
    # Called, not merely defined.
    awk '/^cmd_network_check\(\)/,/^}/' "${REPO_ROOT}/corex-manage.sh" \
        | grep -q '_network_check_link' \
        || { echo "the link check is never called"; false; }
}

# ethtool is not on every box, and a missing tool must not take the whole
# network check down with it.
@test "the link check degrades when ethtool is absent" {
    awk '/^_network_check_link\(\)/,/^}/' "${REPO_ROOT}/corex-manage.sh" \
        | grep -q 'command -v ethtool' \
        || { echo "no guard for a missing ethtool"; false; }
}

# ─── Cold mode, and the healer that could have rebooted a working box ────────

# Cold mode stops containers on purpose, and docker stop SIGKILLs anything that
# does not exit within the timeout, so a deliberately slept container exits 137.
# A check that accepted only 0 reported monitoring UNHEALTHY permanently on a
# box that was working. OOMKilled is what separates that from a real failure,
# because a container killed for memory also exits 137.
@test "a deliberately stopped container is recognised by exit code and OOM flag" {
    local body
    body=$(awk '/^container_stopped_deliberately\(\)/,/^}/' "${REPO_ROOT}/lib/common.sh")
    echo "$body" | grep -q '137' \
        || { echo "137 is not accepted, so cold mode reads as broken"; false; }
    echo "$body" | grep -q 'OOMKilled' \
        || { echo "an OOM kill would be mistaken for a deliberate stop"; false; }
}

# The same logic lived in two modules with two different exit-code lists, which
# is how they drifted: portainer accepted 0/2/143 and monitoring only 0.
@test "cold-mode checks share one implementation" {
    local offenders=""
    for f in "${REPO_ROOT}"/lib/services/monitoring.sh "${REPO_ROOT}"/lib/services/portainer.sh; do
        grep -q 'container_stopped_deliberately' "$f" || offenders+=" $(basename "$f")"
        # A local exit-code list means the copy is back.
        grep -qE 'ExitCode.*==.*(0|2|137|143)' "$f" && offenders+=" $(basename "$f"):inline"
    done
    [ -z "$offenders" ] || { echo "cold-mode logic duplicated or missing:$offenders"; false; }
}

# A status verdict comes from a module and can be wrong; whether a container
# stopped for a reason is a fact. Before rebooting a working machine the healer
# has to check the fact, or one bad verdict reboots the box every six hours
# forever.
@test "the healer verifies container state before believing a verdict" {
    # Read the whole file, not an awk range: the healer is a heredoc containing
    # its own functions, so the first column-0 brace ends say(), not the
    # function being searched.
    grep -q 'OOMKilled' "${REPO_ROOT}/lib/recovery.sh" \
        || { echo "the healer trusts the status verdict without checking containers"; false; }
    grep -q 'thermal-shed.list' "${REPO_ROOT}/lib/recovery.sh" \
        || { echo "the healer would fight the thermal guardian"; false; }
}

# A reboot loop is worse than the fault it clears, so the last reboot is
# remembered on disk rather than in the process that is about to be replaced.
@test "automatic reboot has a cooldown held on disk" {
    grep -q 'RECOVERY_REBOOT_COOLDOWN_SEC' "${REPO_ROOT}/lib/recovery.sh" \
        || { echo "nothing stops a reboot loop"; false; }
    grep -q 'LAST_REBOOT' "${REPO_ROOT}/lib/recovery.sh" \
        || { echo "the last reboot is not persisted, so a reboot resets the memory of it"; false; }
}

# An Intel board has no sp5100_tco and an AMD one has no iTCO_wdt. Loading the
# wrong module does nothing at all: no device, no watchdog, and nothing says so.
@test "the watchdog module is probed rather than assumed" {
    local body
    body=$(awk '/^_recovery_watchdog_module\(\)/,/^}/' "${REPO_ROOT}/lib/recovery.sh")
    echo "$body" | grep -q '/dev/watchdog' \
        || { echo "it never checks whether a device actually appeared"; false; }
    local n
    n=$(echo "$body" | grep -oE 'sp5100_tco|iTCO_wdt|wdat_wdt' | sort -u | wc -l)
    [ "$n" -ge 2 ] || { echo "only one board family is covered"; false; }
}
