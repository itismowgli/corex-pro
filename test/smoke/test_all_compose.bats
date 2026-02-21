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
