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
    rules=$(grep -rhoE 'rule: "Host\(\\`[a-z0-9-]+\.|rule=Host\(\\`[a-z0-9-]+\.' \
        "${REPO_ROOT}"/lib/services/*.sh \
        | sed 's/.*Host(\\`//;s/\.$//' | sort -u)
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
    rules=$(grep -rhoE 'rule: "Host\(\\`[a-z0-9-]+\.|rule=Host\(\\`[a-z0-9-]+\.' \
        "${REPO_ROOT}"/lib/services/*.sh \
        | sed 's/.*Host(\\`//;s/\.$//' | sort -u)
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

@test "no script parses the credentials file by hand" {
    # lib/preflight.sh used awk on a field number while corex-manage.sh used
    # sed that kept the padding, so the two resolved the same credential to
    # different strings. Immich lost access to its own database on repair.
    local offenders=""
    for f in "${REPO_ROOT}"/*.sh "${REPO_ROOT}"/lib/*.sh; do
        [ -f "$f" ] || continue
        grep -qE 'grep "[^"]+:" "\$CRED_FILE" \| (awk|sed)' "$f" \
            && offenders+=" $(basename "$f")"
    done
    [ -z "$offenders" ] || {
        echo "hand-rolled credential parsing in:$offenders"
        echo "Fix: use cred_get from lib/common.sh."
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
