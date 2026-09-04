#!/usr/bin/env bats
# test/smoke/test_all_compose.bats
# Smoke tests for docker-compose file generation.
# Each test sources a service module, calls _deploy() with docker mocked,
# and validates the generated compose file.
#
# Run: bats test/smoke/test_all_compose.bats
# Note: Requires lib/services/ to exist (Phase C). Tests skip gracefully if
# service modules don't exist yet.

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

# Common setup: set required env vars, create temp dirs, mock docker
setup() {
    export DOMAIN="test.example.com"
    export SERVER_IP="192.168.1.100"
    export EMAIL="admin@test.example.com"
    export TIMEZONE="UTC"
    export SSH_PORT="2222"
    export CLOUDFLARE_TUNNEL_TOKEN="test-token-abc123"

    # Passwords (would normally come from /root/corex-credentials.txt)
    export MYSQL_ROOT_PASS="testmysqlroot"
    export NEXTCLOUD_DB_PASS="testnextclouddb"
    export N8N_ENCRYPTION_KEY="testn8nkey12345678901234"
    export TM_PASSWORD="testtimemachine"
    export VAULTWARDEN_ADMIN_TOKEN="testvaulttoken"
    export GRAFANA_ADMIN_PASS="testgrafanapass"
    export RESTIC_PASSWORD="testresticpass"
    export IMMICH_DB_PASS="testimmichdb"
    export WEBUI_SECRET_KEY="testwebuisecret"

    # Temp directories (no real SSD needed)
    export DOCKER_ROOT
    DOCKER_ROOT="$(mktemp -d /tmp/corex-test-docker-XXXXXX)"
    export DATA_ROOT
    DATA_ROOT="$(mktemp -d /tmp/corex-test-data-XXXXXX)"
    export BACKUP_ROOT
    BACKUP_ROOT="$(mktemp -d /tmp/corex-test-backup-XXXXXX)"

    # Mock docker and docker compose to prevent actual container operations
    docker() {
        if [[ "${1:-}" == "compose" ]] && [[ "${2:-}" == "up" ]]; then
            return 0  # Pretend docker compose up succeeded
        fi
        return 0
    }
    export -f docker

    # Mock state functions (state.sh may not exist yet)
    state_service_installed() { return 0; }
    export -f state_service_installed

    # Mock logging functions
    log_info()    { :; }
    log_step()    { :; }
    log_success() { :; }
    log_warning() { :; }
    log_error()   { echo "ERROR: $1" >&2; exit 1; }
    export -f log_info log_step log_success log_warning log_error

    # A common.sh helper the modules assume is present, because in production
    # corex-manage.sh and the installer both source common.sh before touching
    # a module. Without it nextcloud_deploy dies on a missing command, and the
    # five tests after it report a compose failure that is really a mock gap.
    generate_pass() { openssl rand -hex 12; }
    export -f generate_pass
}

teardown() {
    rm -rf "$DOCKER_ROOT" "$DATA_ROOT" "$BACKUP_ROOT"
}

# Helper: source a service module if it exists, skip if not
source_service() {
    local svc="$1"
    local path="${REPO_DIR}/lib/services/${svc}.sh"
    if [[ ! -f "$path" ]]; then
        skip "lib/services/${svc}.sh not yet created (Phase C)"
    fi
    # shellcheck disable=SC1090
    source "$path"
}

# Helper: validate a generated compose file
assert_valid_compose() {
    local svc="$1"
    local compose_file="${DOCKER_ROOT}/${svc}/docker-compose.yml"

    [ -f "$compose_file" ] || {
        echo "Compose file not found: $compose_file"
        return 1
    }

    # Validate YAML syntax using docker compose config
    if command -v docker &>/dev/null && docker compose version &>/dev/null 2>&1; then
        docker compose -f "$compose_file" config &>/dev/null || {
            echo "Invalid compose YAML:"
            docker compose -f "$compose_file" config 2>&1
            return 1
        }
    fi
}

# Helper: assert compose file contains expected string
assert_compose_contains() {
    local svc="$1"
    local expected="$2"
    local compose_file="${DOCKER_ROOT}/${svc}/docker-compose.yml"
    grep -q "$expected" "$compose_file" || {
        echo "Expected to find '${expected}' in ${svc}/docker-compose.yml"
        echo "File contents:"
        cat "$compose_file"
        return 1
    }
}

# ─── Traefik ──────────────────────────────────────────────────────────────────

@test "traefik: deploy generates docker-compose.yml" {
    source_service "traefik"
    traefik_dirs
    traefik_deploy
    [ -f "${DOCKER_ROOT}/traefik/docker-compose.yml" ]
}

@test "traefik: compose contains proxy-net" {
    source_service "traefik"
    traefik_dirs
    traefik_deploy
    assert_compose_contains "traefik" "proxy-net"
}

# ─── AdGuard ──────────────────────────────────────────────────────────────────

@test "adguard: deploy generates docker-compose.yml" {
    source_service "adguard"
    adguard_dirs
    adguard_deploy
    [ -f "${DOCKER_ROOT}/adguard/docker-compose.yml" ]
}

# ─── Portainer ────────────────────────────────────────────────────────────────

@test "portainer: deploy generates docker-compose.yml" {
    source_service "portainer"
    portainer_dirs
    portainer_deploy
    [ -f "${DOCKER_ROOT}/portainer/docker-compose.yml" ]
}

@test "portainer: compose uses HTTPS scheme for Traefik" {
    source_service "portainer"
    portainer_dirs
    portainer_deploy
    assert_compose_contains "portainer" "server.scheme=https"
}

# ─── Nextcloud ────────────────────────────────────────────────────────────────

@test "nextcloud: deploy generates docker-compose.yml" {
    source_service "nextcloud"
    nextcloud_dirs
    nextcloud_deploy
    [ -f "${DOCKER_ROOT}/nextcloud/docker-compose.yml" ]
}

@test "nextcloud: compose contains domain reference" {
    source_service "nextcloud"
    nextcloud_dirs
    nextcloud_deploy
    assert_compose_contains "nextcloud" "test.example.com"
}

@test "nextcloud: compose contains OVERWRITEPROTOCOL" {
    source_service "nextcloud"
    nextcloud_dirs
    nextcloud_deploy
    assert_compose_contains "nextcloud" "OVERWRITEPROTOCOL"
}

@test "nextcloud: compose contains TRUSTED_PROXIES" {
    source_service "nextcloud"
    nextcloud_dirs
    nextcloud_deploy
    assert_compose_contains "nextcloud" "TRUSTED_PROXIES"
}

@test "nextcloud: compose contains DB password" {
    source_service "nextcloud"
    nextcloud_dirs
    nextcloud_deploy
    assert_compose_contains "nextcloud" "testnextclouddb"
}

# ─── Immich ───────────────────────────────────────────────────────────────────

@test "immich: deploy generates docker-compose.yml" {
    source_service "immich"
    immich_dirs
    immich_deploy
    [ -f "${DOCKER_ROOT}/immich/docker-compose.yml" ]
}

@test "immich: compose contains DB password" {
    source_service "immich"
    immich_dirs
    immich_deploy
    assert_compose_contains "immich" "testimmichdb"
}

# ─── Vaultwarden ──────────────────────────────────────────────────────────────

@test "vaultwarden: deploy generates docker-compose.yml" {
    source_service "vaultwarden"
    vaultwarden_dirs
    vaultwarden_deploy
    [ -f "${DOCKER_ROOT}/vaultwarden/docker-compose.yml" ]
}

# ─── n8n ──────────────────────────────────────────────────────────────────────

@test "n8n: deploy generates docker-compose.yml" {
    source_service "n8n"
    n8n_dirs
    n8n_deploy
    [ -f "${DOCKER_ROOT}/n8n/docker-compose.yml" ]
}

@test "n8n: compose contains WEBHOOK_URL with domain" {
    source_service "n8n"
    n8n_dirs
    n8n_deploy
    assert_compose_contains "n8n" "WEBHOOK_URL"
    assert_compose_contains "n8n" "test.example.com"
}

# ─── AI Stack ─────────────────────────────────────────────────────────────────

@test "ai: deploy generates docker-compose.yml" {
    source_service "ai"
    ai_dirs
    ai_deploy
    [ -f "${DOCKER_ROOT}/ai/docker-compose.yml" ]
}

@test "ai: compose contains ai-net network" {
    source_service "ai"
    ai_dirs
    ai_deploy
    assert_compose_contains "ai" "ai-net"
}

# ─── Monitoring Stack ─────────────────────────────────────────────────────────

@test "monitoring: deploy generates docker-compose.yml" {
    source_service "monitoring"
    monitoring_dirs
    monitoring_deploy
    [ -f "${DOCKER_ROOT}/monitoring/docker-compose.yml" ]
}

@test "monitoring: compose contains monitoring-net" {
    source_service "monitoring"
    monitoring_dirs
    monitoring_deploy
    assert_compose_contains "monitoring" "monitoring-net"
}

# ─── Cal.com ──────────────────────────────────────────────────────────────────
#
# These call the generation functions rather than calcom_deploy. Deploy pulls a
# 1.6GB image, waits for a database and applies several hundred migrations,
# none of which belongs in a smoke test; compose generation is the part this
# file exists to check.

calcom_prepare() {
    source_service "calcom"
    state_get() { echo "null"; }
    export -f state_get
    calcom_dirs
    _calcom_secrets
    _calcom_write_helper
    _calcom_write_compose
}

@test "calcom: compose is generated" {
    calcom_prepare
    [ -f "${DOCKER_ROOT}/calcom/docker-compose.yml" ]
}

@test "calcom: web is routed on its own subdomain" {
    calcom_prepare
    assert_compose_contains "calcom" "Host(\`cal.test.example.com\`)"
}

@test "calcom: traefik targets the container port, not a host port" {
    calcom_prepare
    assert_compose_contains "calcom" "loadbalancer.server.port=3000"
}

# The image is only usable unbuilt because start.sh rewrites the compiled
# assets when the runtime URL differs from the built-in one. If this ever
# stopped being the public HTTPS address, every generated link would point at
# localhost and the fix would look like "rebuild the image".
@test "calcom: the app is told its public https address" {
    calcom_prepare
    assert_compose_contains "calcom" 'NEXT_PUBLIC_WEBAPP_URL: "https://cal.test.example.com"'
    assert_compose_contains "calcom" 'NEXTAUTH_URL: "https://cal.test.example.com"'
}

# A moving tag here would carry a major upgrade into a database that has to
# migrate for it (gotcha #19 and #26).
@test "calcom: the image is pinned to a version" {
    calcom_prepare
    run grep -E 'image: calcom/cal\.com:v[0-9]+\.[0-9]+\.[0-9]+' \
        "${DOCKER_ROOT}/calcom/docker-compose.yml"
    [ "$status" -eq 0 ]
}

# start.sh passes this to wait-for-it.sh, so it needs the port too. Without it
# the first migration races the database.
@test "calcom: the database host carries its port" {
    calcom_prepare
    assert_compose_contains "calcom" 'DATABASE_HOST: "calcom-db:5432"'
}

@test "calcom: nothing is published to the host" {
    calcom_prepare
    run grep -E '^\s+- "[0-9]+:[0-9]+"' "${DOCKER_ROOT}/calcom/docker-compose.yml"
    [ "$status" -ne 0 ]
}

@test "calcom: the compose file is not world readable" {
    calcom_prepare
    run stat -c '%a' "${DOCKER_ROOT}/calcom/docker-compose.yml"
    [ "$output" = "600" ]
}

@test "calcom: secrets file is not world readable" {
    calcom_prepare
    run stat -c '%a' "${DOCKER_ROOT}/calcom/.secrets.env"
    [ "$output" = "600" ]
}

# The encryption key is an AES-256 key upstream rejects at any other length.
@test "calcom: the encryption key is exactly 32 characters" {
    calcom_prepare
    run grep -cE '^CALCOM_ENCRYPTION_KEY=[0-9a-f]{32}$' "${DOCKER_ROOT}/calcom/.secrets.env"
    [ "$output" = "1" ]
}

@test "calcom: the helper is valid python" {
    calcom_prepare
    [ -f "${DOCKER_ROOT}/calcom/helper.py" ]
    if ! command -v python3 &>/dev/null; then
        skip "python3 not available"
    fi
    run python3 -m py_compile "${DOCKER_ROOT}/calcom/helper.py"
    [ "$status" -eq 0 ]
}

# ─── Dashboard ────────────────────────────────────────────────────────────────
#
# These call _dashboard_write_compose rather than dashboard_deploy, which
# compiles a TypeScript app and a Go binary. What is worth checking here is the
# middleware chain: get it wrong in one direction and the operator is asked for
# a password twice, and in the other the dashboard that can stop every service
# on the box is published with nothing in front of it.

dashboard_prepare() {
    source_service "dashboard"
    _dashboard_write_compose
}

@test "dashboard: compose is generated" {
    state_get() { echo "null"; }
    export -f state_get
    dashboard_prepare
    assert_compose_contains "dashboard" "corex-dashboard"
}

@test "dashboard: basic auth is in front until the app login is turned on" {
    state_get() { echo "null"; }
    export -f state_get
    dashboard_prepare
    assert_compose_contains "dashboard" "routers.dashboard.middlewares=dash-auth"
}

@test "dashboard: enabling the app login takes basic auth off the router" {
    state_get() { [[ "$1" == "dashboard_app_auth" ]] && echo "true" || echo "null"; }
    export -f state_get
    dashboard_prepare
    run grep "routers.dashboard.middlewares" "${DOCKER_ROOT}/dashboard/docker-compose.yml"
    [ "$status" -ne 0 ]
}

@test "dashboard: the LAN allowlist survives the app login being turned on" {
    mkdir -p "${DOCKER_ROOT}/traefik/dynamic"
    state_get() {
        case "$1" in
            dashboard_app_auth|dashboard_lan_only) echo "true" ;;
            *) echo "null" ;;
        esac
    }
    export -f state_get
    dashboard_prepare
    assert_compose_contains "dashboard" "routers.dashboard.middlewares=dash-lan@file"
    run grep "dash-auth" "${DOCKER_ROOT}/dashboard/docker-compose.yml"
    # The middleware is still defined by its label, it is just not on the
    # router any more, so the grep hits the definition and nothing else.
    [ "$status" -eq 0 ]
}

@test "dashboard: the compose file is valid YAML in both auth modes" {
    state_get() { echo "null"; }
    export -f state_get
    dashboard_prepare
    assert_valid_compose "dashboard"
    state_get() { [[ "$1" == "dashboard_app_auth" ]] && echo "true" || echo "null"; }
    export -f state_get
    dashboard_prepare
    assert_valid_compose "dashboard"
}

# ─── Authelia and the shared login ────────────────────────────────────────────
#
# The middleware label is the part worth testing, in both directions and for
# a reason that is not symmetrical. Missing, and four admin panels are
# published with only their own passwords. Present when Authelia is not
# running, and Traefik puts those four routers into an error state and their
# hostnames answer 404, so a label written unconditionally is an outage.

# The real sso_label_for from lib/common.sh, so the label text and its
# indentation are what is being checked rather than a copy of them. Only
# sso_protects is stubbed: it reads a fixed path and asks whether a container
# is running, neither of which exists here.
_sso_load() {
    # shellcheck disable=SC1090
    source "${REPO_DIR}/lib/common.sh"
    # common.sh brings the real logging functions with it, and these tests
    # want the quiet ones back.
    log_info()    { :; }
    log_step()    { :; }
    log_success() { :; }
    log_warning() { :; }
    log_error()   { echo "ERROR: $1" >&2; exit 1; }
    export -f log_info log_step log_success log_warning log_error
}

sso_on() {
    _sso_load
    sso_protects() {
        [[ " portainer grafana adguard n8n " == *" $1 "* ]]
    }
    export -f sso_protects
}

sso_off() {
    _sso_load
    sso_protects() { return 1; }
    export -f sso_protects
}

@test "authelia: compose is generated and defines the forwardAuth middleware" {
    source_service "authelia"
    _authelia_write_compose
    assert_compose_contains "authelia" "middlewares.authelia.forwardauth.address=http://authelia:9091/api/authz/forward-auth"
    assert_compose_contains "authelia" "routers.authelia.rule=Host(\`auth.test.example.com\`)"
    assert_valid_compose "authelia"
}

@test "authelia: the storage key and the session secret are not the same value" {
    source_service "authelia"
    _authelia_secrets
    [ -n "$AUTHELIA_STORAGE_KEY" ]
    [ -n "$AUTHELIA_SESSION_SECRET" ]
    [ "$AUTHELIA_STORAGE_KEY" != "$AUTHELIA_SESSION_SECRET" ]
}

@test "authelia: secrets survive a second run, because a new storage key loses every enrolled device" {
    source_service "authelia"
    _authelia_secrets
    local first="$AUTHELIA_STORAGE_KEY"
    unset AUTHELIA_STORAGE_KEY AUTHELIA_JWT_SECRET AUTHELIA_SESSION_SECRET
    _authelia_secrets
    [ "$AUTHELIA_STORAGE_KEY" = "$first" ]
}

@test "authelia: the config denies by default and lists every protected host" {
    source_service "authelia"
    _authelia_secrets
    _authelia_write_config
    local cfg="${DOCKER_ROOT}/authelia/configuration.yml"
    grep -q "default_policy: deny" "$cfg"
    grep -q "portainer.test.example.com" "$cfg"
    grep -q "grafana.test.example.com" "$cfg"
    grep -q "auth.test.example.com" "$cfg"
}

@test "authelia: without a relay the policy drops to one factor" {
    source_service "authelia"
    # No relay, so no way to deliver a registration link. Asking for a second
    # factor here would lock the operator out of the portal with no way in.
    smtp_conf_load() { return 1; }
    export -f smtp_conf_load
    _authelia_secrets
    _authelia_write_config
    grep -q "policy: one_factor" "${DOCKER_ROOT}/authelia/configuration.yml"
    grep -q "filename: /config/notification.txt" "${DOCKER_ROOT}/authelia/configuration.yml"
}

@test "portainer: no middleware label when the shared login is not installed" {
    sso_off
    source_service "portainer"
    portainer_deploy
    run grep "routers.portainer.middlewares" "${DOCKER_ROOT}/portainer/docker-compose.yml"
    [ "$status" -ne 0 ]
    assert_valid_compose "portainer"
}

@test "portainer: the middleware label appears when it is" {
    sso_on
    source_service "portainer"
    portainer_deploy
    assert_compose_contains "portainer" "routers.portainer.middlewares=authelia@docker"
    assert_valid_compose "portainer"
}

@test "n8n: the middleware label follows the same switch" {
    sso_off
    source_service "n8n"
    n8n_deploy
    run grep "routers.n8n.middlewares" "${DOCKER_ROOT}/n8n/docker-compose.yml"
    [ "$status" -ne 0 ]
    sso_on
    n8n_deploy
    assert_compose_contains "n8n" "routers.n8n.middlewares=authelia@docker"
    assert_valid_compose "n8n"
}

@test "monitoring: grafana is protected and uptime kuma is not" {
    sso_on
    source_service "monitoring"
    monitoring_deploy
    assert_compose_contains "monitoring" "routers.grafana.middlewares=authelia@docker"
    # Kuma is the page you open to find out why something is down, so it keeps
    # its own login and stays reachable when the portal is not.
    run grep "routers.uptime.middlewares" "${DOCKER_ROOT}/monitoring/docker-compose.yml"
    [ "$status" -ne 0 ]
    assert_valid_compose "monitoring"
}

@test "adguard: it gets a Traefik router, and keeps port 3000 either way" {
    sso_on
    source_service "adguard"
    adguard_deploy
    assert_compose_contains "adguard" "routers.adguard.rule=Host(\`adguard.test.example.com\`)"
    assert_compose_contains "adguard" "routers.adguard.middlewares=authelia@docker"
    # The escape hatch. AdGuard is the DNS, so a login that needs DNS must not
    # be the only way to reach the thing that serves it.
    assert_compose_contains "adguard" '"3000:'
    assert_valid_compose "adguard"
}

@test "adguard: no domain means no router at all, not a broken one" {
    sso_off
    source_service "adguard"
    DOMAIN="" adguard_deploy
    run grep "traefik.enable" "${DOCKER_ROOT}/adguard/docker-compose.yml"
    [ "$status" -ne 0 ]
    assert_valid_compose "adguard"
}

@test "lan-only puts the allowlist before the auth portal in the chain" {
    # Order matters: a request from the internet should be refused by the
    # allowlist rather than costing a round trip to the portal first.
    _sso_load
    sso_lan_only() { [[ "$1" == "portainer" ]]; }
    sso_protects() { [[ " portainer grafana n8n " == *" $1 "* ]]; }
    export -f sso_lan_only sso_protects
    source_service "portainer"
    portainer_deploy
    assert_compose_contains "portainer" "routers.portainer.middlewares=corex-lan@file,authelia@docker"
    assert_valid_compose "portainer"
}

@test "a lan-only router with no shared login carries only the allowlist" {
    _sso_load
    sso_lan_only() { [[ "$1" == "adguard" ]]; }
    sso_protects() { return 1; }
    export -f sso_lan_only sso_protects
    source_service "adguard"
    adguard_deploy
    assert_compose_contains "adguard" "routers.adguard.middlewares=corex-lan@file"
    run grep "authelia@docker" "${DOCKER_ROOT}/adguard/docker-compose.yml"
    [ "$status" -ne 0 ]
    assert_valid_compose "adguard"
}
