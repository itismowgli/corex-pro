#!/bin/bash
# lib/services/authelia.sh — CoreX Pro
# Authelia — one sign-in, with two-factor, for the services that have no real
# login of their own.
#
# Why this is possible now and was not before: gotcha #27. The Cloudflare
# tunnel used to point at container names and ports, so Traefik was only in
# the path for LAN requests and a forwardAuth middleware would have protected
# nothing that came from the internet. The tunnel is one wildcard route to
# Traefik now, so a middleware applies to external traffic as well.
#
# Authelia rather than Authentik, and the reason is this hardware. Authelia is
# one Go binary in one container with a file backend and no Redis. Authentik is
# Python plus PostgreSQL plus Redis plus a worker, well over a gigabyte on a
# box that thermal trips and already runs twenty-two containers.
#
# In front of what, and deliberately not in front of what:
#
#   Portainer, Grafana, AdGuard and n8n get it. Their own logins range from
#   passable to a single shared password, none of them can do two-factor
#   properly, and Prometheus has no login at all.
#
#   Vaultwarden, Nextcloud, Immich, Cal.com and the CoreX dashboard do not.
#   Every one has a real login of its own, so fronting them means signing in
#   twice for one door. The dashboard's login is also tied to the agent, the
#   access log and the passkey store, and is the thing you open when the box
#   is already in trouble.

# ── Metadata ──────────────────────────────────────────────────────────────────
SERVICE_NAME="authelia"
SERVICE_LABEL="Authelia — Shared sign-in with two-factor"
SERVICE_CATEGORY="security"
SERVICE_REQUIRED=false
SERVICE_NEEDS_DOMAIN=true
SERVICE_NEEDS_EMAIL=false
SERVICE_RAM_MB=128
SERVICE_DISK_GB=1
SERVICE_DESCRIPTION="One login, with two-factor, in front of the admin panels that have no real login of their own: Portainer, Grafana, AdGuard and n8n."

SERVICE_MONITORS="Authelia	https://auth.${DOMAIN:-}	[\"200-299\"]"

# The routers that sit behind it. Router names, not service names, because
# that is what the middleware attaches to: grafana lives inside the monitoring
# module, and monitoring's other router (uptime) is left alone.
AUTHELIA_DEFAULT_PROTECT="portainer grafana adguard n8n"

AUTHELIA_IMAGE="authelia/authelia:4.39"

# ── Secrets ───────────────────────────────────────────────────────────────────
# Three of them, generated once and kept in a 0600 file beside the service, the
# way .admin-password and .tunnel-token are. state.json must never hold a
# credential (gotcha #24), and the storage encryption key in particular cannot
# be regenerated: a new one makes the existing database unreadable, which
# takes every enrolled second factor with it.
_authelia_secrets() {
    local dir="${DOCKER_ROOT}/authelia"
    local f="${dir}/.secrets"
    mkdir -p "$dir"

    if [[ -r "$f" ]]; then
        # shellcheck source=/dev/null
        . "$f"
    fi
    local changed=false
    [[ -n "${AUTHELIA_JWT_SECRET:-}" ]]     || { AUTHELIA_JWT_SECRET="$(generate_pass)$(generate_pass)"; changed=true; }
    [[ -n "${AUTHELIA_SESSION_SECRET:-}" ]] || { AUTHELIA_SESSION_SECRET="$(generate_pass)$(generate_pass)"; changed=true; }
    [[ -n "${AUTHELIA_STORAGE_KEY:-}" ]]    || { AUTHELIA_STORAGE_KEY="$(generate_pass)$(generate_pass)"; changed=true; }

    if [[ "$changed" == "true" ]]; then
        local prev; prev="$(umask)"
        umask 077
        cat > "$f" << SECEOF
# Authelia secrets. Generated once and never rotated by CoreX.
#
# AUTHELIA_STORAGE_KEY encrypts the database that holds enrolled second
# factors. Replacing it does not reset a password, it makes every registered
# device unreadable, so treat this file the way you would treat the Restic
# password.
AUTHELIA_JWT_SECRET='${AUTHELIA_JWT_SECRET}'
AUTHELIA_SESSION_SECRET='${AUTHELIA_SESSION_SECRET}'
AUTHELIA_STORAGE_KEY='${AUTHELIA_STORAGE_KEY}'
SECEOF
        umask "$prev"
        chmod 600 "$f"
    fi
}

# The portal password, also persisted, and for the reason gotcha #3 records:
# regenerating it on every repair means the admin password silently becomes a
# value nothing recorded.
_authelia_admin_password() {
    local f="${DOCKER_ROOT}/authelia/.admin-password"
    if [[ -s "$f" ]]; then
        AUTHELIA_ADMIN_PASS="$(cat "$f")"
        return 0
    fi
    AUTHELIA_ADMIN_PASS="$(generate_pass)"
    local prev; prev="$(umask)"; umask 077
    printf '%s' "$AUTHELIA_ADMIN_PASS" > "$f"
    umask "$prev"
    chmod 600 "$f"
}

# Hashed by the Authelia binary itself, in a throwaway container, because the
# argon2id parameters are its own and a hash built any other way is refused at
# sign-in with nothing to say why.
_authelia_hash() {
    local plain="$1" out
    out="$(docker run --rm "$AUTHELIA_IMAGE" \
             authelia crypto hash generate argon2 --password "$plain" 2>/dev/null \
           | sed -n 's/^Digest: //p')"
    [[ -n "$out" ]] || return 1
    printf '%s' "$out"
}

# ── Mail ──────────────────────────────────────────────────────────────────────
# The shared relay, so a second factor can be registered and a password reset.
# Absent is not an error: Authelia then writes notifications to a file, and
# the deploy says where, because a registration link nobody can read is worse
# than one printed on the server.
_authelia_smtp() {
    AUTHELIA_SMTP_ADDRESS=""; AUTHELIA_SMTP_USER=""
    AUTHELIA_SMTP_PASS=""; AUTHELIA_SMTP_SENDER=""
    declare -f smtp_conf_load >/dev/null 2>&1 || return 1
    smtp_conf_load 2>/dev/null || return 1
    [[ -n "${COREX_SMTP_HOST:-}" && -n "${COREX_SMTP_USER:-}" ]] || return 1
    local port="${COREX_SMTP_PORT:-587}"
    # Authelia takes one address with a scheme rather than a host, a port and
    # a pair of TLS booleans. submission is STARTTLS on 587, submissions is
    # implicit TLS on 465.
    if [[ "$port" == "465" ]]; then
        AUTHELIA_SMTP_ADDRESS="submissions://${COREX_SMTP_HOST}:465"
    else
        AUTHELIA_SMTP_ADDRESS="submission://${COREX_SMTP_HOST}:${port}"
    fi
    AUTHELIA_SMTP_USER="$COREX_SMTP_USER"
    # Gmail prints app passwords in four groups; SMTP AUTH wants the sixteen
    # characters with no spaces.
    AUTHELIA_SMTP_PASS="${COREX_SMTP_PASSWORD//[[:space:]]/}"
    AUTHELIA_SMTP_SENDER="CoreX <${COREX_SMTP_FROM:-$COREX_SMTP_USER}>"
    return 0
}

# ── Config ────────────────────────────────────────────────────────────────────

_authelia_conf_file() {
    mkdir -p /etc/corex
    cat > /etc/corex/authelia.conf << ACEOF
# Which Traefik routers sit behind the shared login.
#
# Read by sso_protects in lib/common.sh, which every service module calls when
# it writes its compose file. Changing this list takes effect on the next
# repair of the services concerned:
#
#   sudo corex manage repair portainer
#
# AUTHELIA_ENABLED=false turns the middleware off everywhere without removing
# the service, which is the way out if the portal itself is the problem.
AUTHELIA_ENABLED=true
AUTHELIA_PROTECT="${AUTHELIA_PROTECT:-$AUTHELIA_DEFAULT_PROTECT}"
ACEOF
    chmod 644 /etc/corex/authelia.conf
}

# Regenerated unconditionally, because CoreX owns it (gotcha #22).
_authelia_write_config() {
    local dir="${DOCKER_ROOT}/authelia"
    local policy="one_factor" have_smtp=false

    if _authelia_smtp; then
        # two_factor only where a registration link can actually be delivered.
        # Asking for a second factor on a box that cannot send mail locks the
        # operator out of the portal with no way to enrol a device.
        policy="two_factor"
        have_smtp=true
    fi

    local protect_hosts="" r
    for r in ${AUTHELIA_PROTECT:-$AUTHELIA_DEFAULT_PROTECT}; do
        protect_hosts+="      - '${r}.${DOMAIN}'"$'\n'
    done

    cat > "${dir}/configuration.yml" << CFEOF
# Generated by CoreX. Edits are overwritten on the next repair; the list of
# protected hostnames lives in /etc/corex/authelia.conf.
theme: dark

server:
  address: 'tcp://0.0.0.0:9091'
  buffers:
    read: 8192
    write: 8192

log:
  level: info
  format: text

totp:
  issuer: '${DOMAIN}'
  period: 30
  skew: 1

identity_validation:
  reset_password:
    jwt_secret: '${AUTHELIA_JWT_SECRET}'

authentication_backend:
  password_reset:
    disable: false
  # Watched, so a password changed through the portal or by hand takes effect
  # without a restart. The file is user state and is never regenerated.
  file:
    path: /config/users_database.yml
    watch: true
    search:
      email: true

access_control:
  # Deny by default, so adding a hostname to the middleware without adding it
  # here refuses the request rather than waving it through.
  default_policy: deny
  rules:
    - domain: 'auth.${DOMAIN}'
      policy: bypass
    - domain:
${protect_hosts}      policy: ${policy}

session:
  # In memory, no Redis. One operator and a handful of sessions, on hardware
  # where a second data store costs more than it is worth. Sessions are lost
  # on restart, which means signing in again and nothing else.
  secret: '${AUTHELIA_SESSION_SECRET}'
  cookies:
    - domain: '${DOMAIN}'
      authelia_url: 'https://auth.${DOMAIN}'
      default_redirection_url: 'https://dashboard.${DOMAIN}'
      name: corex_authelia
      same_site: lax
      expiration: '12h'
      inactivity: '1h'
      remember_me: '1M'

regulation:
  max_retries: 5
  find_time: '2m'
  ban_time: '10m'

storage:
  encryption_key: '${AUTHELIA_STORAGE_KEY}'
  local:
    path: /config/db.sqlite3

CFEOF

    # Appended with its own heredoc rather than built into a variable first.
    # A heredoc body inside a command substitution is scanned for quotes by
    # bash, so one apostrophe in a YAML comment in there is an unterminated
    # string and the whole file fails to parse. Writing straight to the file
    # removes the question.
    if [[ "$have_smtp" == "true" ]]; then
        cat >> "${dir}/configuration.yml" << NSEOF
notifier:
  disable_startup_check: false
  smtp:
    address: '${AUTHELIA_SMTP_ADDRESS}'
    username: '${AUTHELIA_SMTP_USER}'
    password: '${AUTHELIA_SMTP_PASS}'
    sender: '${AUTHELIA_SMTP_SENDER}'
NSEOF
    else
        cat >> "${dir}/configuration.yml" << NFEOF
notifier:
  disable_startup_check: false
  # No relay is configured, so the registration link and any password reset
  # are written here instead of being emailed. Read it with:
  #   sudo cat ${DOCKER_ROOT}/authelia/notification.txt
  filesystem:
    filename: /config/notification.txt
NFEOF
    fi
    chmod 640 "${dir}/configuration.yml"
}

# Written only when absent. This is the one file here that is genuine user
# state rather than generated config: the portal writes to it on a password
# reset, and an operator may add accounts. Regenerating it would undo both.
_authelia_write_users() {
    local dir="${DOCKER_ROOT}/authelia"
    local f="${dir}/users_database.yml"
    [[ -f "$f" ]] && return 0

    _authelia_admin_password
    local hash
    hash="$(_authelia_hash "$AUTHELIA_ADMIN_PASS")" || {
        log_warning "Could not hash the portal password with ${AUTHELIA_IMAGE}"
        return 1
    }
    local email="${EMAIL:-}"
    [[ -n "$email" ]] || email="admin@${DOMAIN}"

    cat > "$f" << UDEOF
# Authelia accounts. CoreX writes this once and never again, because the
# portal itself writes here on a password reset.
#
# Add a user:  docker run --rm ${AUTHELIA_IMAGE} \\
#                authelia crypto hash generate argon2 --password 'secret'
#              then copy the Digest line in as the password below.
users:
  admin:
    disabled: false
    displayname: 'CoreX Admin'
    password: '${hash}'
    email: '${email}'
    groups:
      - admins
UDEOF
    chmod 640 "$f"
}

# ── Contract ──────────────────────────────────────────────────────────────────

authelia_dirs() {
    mkdir -p "${DOCKER_ROOT}/authelia"
    # The image runs as 1000:1000, and it writes its database and, on a
    # password reset, the users file. A directory it cannot write leaves the
    # container up and the portal answering 500 on sign-in.
    chown -R 1000:1000 "${DOCKER_ROOT}/authelia"
    chmod 750 "${DOCKER_ROOT}/authelia"
}

authelia_firewall() {
    : # Traefik fronts it; no port of its own
}

# Split out so a test can generate the compose file without writing to
# /etc/corex, hashing a password in a container or touching four other
# services, the same way _dashboard_write_compose is.
_authelia_write_compose() {
    local dir="${DOCKER_ROOT}/authelia"
    mkdir -p "$dir"
    cat > "${dir}/docker-compose.yml" << DCEOF
services:
  authelia:
    image: ${AUTHELIA_IMAGE}
    container_name: authelia
    restart: unless-stopped
    user: "1000:1000"
    volumes:
      - ${DOCKER_ROOT}/authelia:/config
    environment:
      TZ: "${TIMEZONE:-UTC}"
    networks: [proxy-net]
    security_opt: ["no-new-privileges:true"]
    healthcheck:
      test: ["CMD", "authelia", "healthcheck"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 20s
    deploy:
      resources:
        limits:
          memory: 256m
          cpus: "0.5"
        reservations:
          memory: 64m
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.authelia.rule=Host(\`auth.${DOMAIN}\`)"
      - "traefik.http.routers.authelia.entrypoints=websecure"
      - "traefik.http.routers.authelia.tls.certresolver=myresolver"
      - "traefik.http.services.authelia.loadbalancer.server.port=9091"
      # The middleware every protected router names. It is defined here, on
      # the container that answers it, so it cannot outlive the service: a
      # router pointing at a middleware Traefik does not know goes into an
      # error state and its hostname returns 404, which is why sso_protects
      # also checks that this container is running.
      - "traefik.http.middlewares.authelia.forwardauth.address=http://authelia:9091/api/authz/forward-auth"
      - "traefik.http.middlewares.authelia.forwardauth.trustForwardHeader=true"
      - "traefik.http.middlewares.authelia.forwardauth.authResponseHeaders=Remote-User,Remote-Groups,Remote-Name,Remote-Email"
networks:
  proxy-net: { external: true }
DCEOF

}

authelia_deploy() {
    if [[ -z "${DOMAIN:-}" ]]; then
        log_warning "Authelia needs a domain: the session cookie is scoped to one"
        return 1
    fi
    authelia_dirs
    local dir="${DOCKER_ROOT}/authelia"

    _authelia_secrets
    # shellcheck source=/dev/null
    [[ -r /etc/corex/authelia.conf ]] && . /etc/corex/authelia.conf
    _authelia_conf_file
    _authelia_write_config
    _authelia_write_users || true
    _authelia_write_compose

    docker compose -f "${dir}/docker-compose.yml" up -d \
        || log_warning "Authelia may not have started, check: docker logs authelia"
    state_service_installed "authelia"
    log_success "Authelia deployed (https://auth.${DOMAIN})"

    _authelia_apply_to_protected
}

# The protected services carry the middleware label, and each one writes its
# own compose file, so they have to be regenerated for the label to appear or
# disappear. Doing it here means installing or removing Authelia is one
# command rather than five.
_authelia_apply_to_protected() {
    local list="${AUTHELIA_PROTECT:-$AUTHELIA_DEFAULT_PROTECT}" r svc
    log_info "Applying the shared login to: ${list}"
    for r in $list; do
        # grafana's router lives in the monitoring module.
        svc="$r"
        [[ "$r" == "grafana" ]] && svc="monitoring"
        state_service_is_installed "$svc" 2>/dev/null || {
            log_info "  ${r}: ${svc} is not installed, nothing to do"
            continue
        }
        # A service switched off with `corex manage disable` stays off. Running
        # its deploy would start every container in it, which on the monitoring
        # module is five, and would silently undo a deliberate decision. The
        # label lands the next time it is enabled, because enable regenerates
        # the compose file.
        state_service_is_enabled "$svc" 2>/dev/null || {
            log_info "  ${r}: ${svc} is disabled, leaving it stopped"
            continue
        }
        local module="${SCRIPT_DIR:-}/lib/services/${svc}.sh"
        [[ -f "$module" ]] || continue
        (
            # A subshell, so sourcing another module cannot leave its
            # SERVICE_NAME and its functions behind in this one.
            # shellcheck source=/dev/null
            source "$module"
            if declare -f "${svc}_deploy" >/dev/null 2>&1; then
                "${svc}_deploy" >/dev/null 2>&1 \
                    && echo "  ${r}: now behind the shared login" \
                    || echo "  ${r}: could not be regenerated, run: corex manage repair ${svc}"
            fi
        )
    done
}

authelia_destroy() {
    local dir="${DOCKER_ROOT}/authelia"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" down
    # Turn the middleware off before the container goes, or four routers name
    # a middleware that no longer exists and four hostnames answer 404.
    if [[ -f /etc/corex/authelia.conf ]]; then
        sed -i 's/^AUTHELIA_ENABLED=.*/AUTHELIA_ENABLED=false/' /etc/corex/authelia.conf
    fi
    state_service_removed "authelia"
    _authelia_apply_to_protected
    log_info "The protected services are open again, on their own logins"
}

authelia_status() {
    if ! container_exists "authelia"; then echo "MISSING"; return 0; fi
    if ! container_running "authelia"; then echo "UNHEALTHY"; return 0; fi
    # A running Authelia proves nothing on its own, the same way a running
    # Stalwart did not (gotcha #23). If the portal cannot answer, four
    # hostnames are refusing every request.
    local code
    code="$(docker exec authelia authelia healthcheck >/dev/null 2>&1 && echo ok || echo fail)"
    if [[ "$code" != "ok" ]]; then echo "UNHEALTHY"; return 0; fi
    echo "HEALTHY"
}

authelia_repair() {
    authelia_deploy
    local dir="${DOCKER_ROOT}/authelia"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" up -d --force-recreate
}

authelia_credentials() {
    local dir="${DOCKER_ROOT}/authelia"
    local pass="(see ${dir}/.admin-password)"
    [[ -s "${dir}/.admin-password" ]] && pass="$(cat "${dir}/.admin-password")"
    echo "Authelia: https://auth.${DOMAIN}"
    echo "  Username: admin"
    echo "  Password: ${pass}"
    echo "  In front of: $(sed -n 's/^AUTHELIA_PROTECT=//p' /etc/corex/authelia.conf 2>/dev/null | tr -d '"')"
    echo "  Register a second factor at first sign-in; the link is emailed"
    echo "  through the shared relay. Without a relay the link is written to"
    echo "  ${dir}/notification.txt instead."
    echo "  AdGuard stays reachable on http://${SERVER_IP}:3000 without the"
    echo "  portal, deliberately: it is the DNS, so a login that needs DNS"
    echo "  must not be the only way to fix DNS."
}
