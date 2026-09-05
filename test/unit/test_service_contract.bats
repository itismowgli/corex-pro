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
