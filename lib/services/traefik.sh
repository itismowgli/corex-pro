#!/bin/bash
# lib/services/traefik.sh — CoreX Pro v2
# Traefik v3.6 — Reverse Proxy & TLS Termination
#
# CRITICAL NOTES:
#   - loadbalancer.server.port = CONTAINER port, NOT host port
#   - acme.json MUST be chmod 600 or Traefik refuses to start
#   - Uses TLS-ALPN-01 challenge (no port 80 needed for cert issuance)
#   - exposedByDefault=false means only labeled containers are routed
#   - Traefik v3.6+ required for Docker Engine 29+ (API auto-negotiation)
#     Versions before v3.6 hardcode Docker API v1.24, which is rejected
#     by Docker Engine 29+ (minimum API raised to v1.44)
#
# LAN FAST-PATH (v2.4.0):
#   - Self-signed CA generates a wildcard cert for *.DOMAIN
#   - Traefik serves the wildcard cert as the default TLS certificate
#   - LAN clients that trust the CA get valid HTTPS without Let's Encrypt
#   - Let's Encrypt (ACME) still works for internet-facing access
#   - File provider loads dynamic.yml for the default cert store

# ── Metadata (auto-discovered by wizard) ──────────────────────────────────────
SERVICE_NAME="traefik"
SERVICE_LABEL="Traefik — Reverse Proxy (required for HTTPS routing)"
SERVICE_CATEGORY="core"
SERVICE_REQUIRED=true
SERVICE_NEEDS_DOMAIN=false
SERVICE_NEEDS_EMAIL=true
SERVICE_RAM_MB=128
SERVICE_DISK_GB=1
SERVICE_DESCRIPTION="Automatic HTTPS for all your services. Manages SSL certificates via Let's Encrypt. Required for all domain-based services."

# ── Private Helpers ───────────────────────────────────────────────────────────

# Generates a self-signed CA and wildcard certificate for *.DOMAIN.
# LAN clients that trust the CA get valid HTTPS for all services without
# relying on Let's Encrypt (which requires TLS-ALPN-01 to reach port 443
# from the internet — often blocked by NAT/ISP on residential connections).
#
# The wildcard cert is loaded as Traefik's DEFAULT TLS certificate via the
# file provider (dynamic.yml). Let's Encrypt certs take priority when
# available (ACME resolver is still configured).
_traefik_generate_lan_certs() {
    local dir="${DOCKER_ROOT}/traefik"
    local cert_dir="${dir}/certs"
    local domain="${DOMAIN:-localhost}"

    # Skip if certs already exist and are for the correct domain
    if [[ -f "${cert_dir}/wildcard.crt" ]]; then
        local existing_domain
        existing_domain=$(openssl x509 -in "${cert_dir}/wildcard.crt" \
            -noout -ext subjectAltName 2>/dev/null \
            | grep -oP '\*\.\K[^ ,]+' | head -1) || true
        if [[ "$existing_domain" == "$domain" ]]; then
            log_info "LAN wildcard cert for *.${domain} already exists — skipping"
            return 0
        fi
        log_info "Domain changed — regenerating LAN certs for *.${domain}"
    fi

    mkdir -p "$cert_dir"

    log_info "Generating CoreX Pro CA + wildcard cert for *.${domain}..."

    # ── Step 1: CA key + certificate (10-year lifetime) ──────────────
    openssl genrsa -out "${cert_dir}/ca.key" 4096 2>/dev/null

    openssl req -new -x509 -sha256 -days 3650 \
        -key "${cert_dir}/ca.key" \
        -out "${cert_dir}/ca.crt" \
        -subj "/C=US/ST=Self-Hosted/O=CoreX Pro/CN=CoreX Pro CA" \
        2>/dev/null

    # ── Step 2: Wildcard key + CSR ───────────────────────────────────
    openssl genrsa -out "${cert_dir}/wildcard.key" 4096 2>/dev/null

    openssl req -new -sha256 \
        -key "${cert_dir}/wildcard.key" \
        -out "${cert_dir}/wildcard.csr" \
        -subj "/C=US/ST=Self-Hosted/O=CoreX Pro/CN=*.${domain}" \
        2>/dev/null

    # ── Step 3: Sign wildcard cert with CA (1-year lifetime) ─────────
    # SAN extension is required — modern browsers reject certs without it
    cat > "${cert_dir}/san.ext" << SANEOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=@alt_names

[alt_names]
DNS.1 = *.${domain}
DNS.2 = ${domain}
SANEOF

    openssl x509 -req -sha256 -days 365 \
        -in "${cert_dir}/wildcard.csr" \
        -CA "${cert_dir}/ca.crt" \
        -CAkey "${cert_dir}/ca.key" \
        -CAcreateserial \
        -out "${cert_dir}/wildcard.crt" \
        -extfile "${cert_dir}/san.ext" \
        2>/dev/null

    # Clean up CSR and extension file (not needed at runtime)
    rm -f "${cert_dir}/wildcard.csr" "${cert_dir}/san.ext" "${cert_dir}/ca.srl"

    chmod 600 "${cert_dir}/ca.key" "${cert_dir}/wildcard.key"

    log_success "LAN certs generated in ${cert_dir}/"
    log_info "  CA cert:       ${cert_dir}/ca.crt (distribute to LAN clients)"
    log_info "  Wildcard cert: ${cert_dir}/wildcard.crt (*.${domain})"
}

# ── Functions ─────────────────────────────────────────────────────────────────

traefik_dirs() {
    mkdir -p "${DOCKER_ROOT}/traefik"
    mkdir -p "${DOCKER_ROOT}/traefik/certs"
}

traefik_firewall() {
    ufw allow 80/tcp   comment 'HTTP (Traefik redirects to HTTPS)' 2>/dev/null || true
    ufw allow 443/tcp  comment 'HTTPS (Traefik TLS termination)'   2>/dev/null || true
    # Port 8080 (Traefik dashboard) is bound to localhost only — no UFW rule needed
}

# ── Generated Traefik configuration ───────────────────────────────────────────
# Writes traefik.yml and dynamic.yml. Called UNCONDITIONALLY from both deploy
# and repair.
#
# Previously traefik.yml was written only by deploy and dynamic.yml only when
# missing, so neither ever changed on an existing install. Observed in the
# field: a months-old dynamic.yml still pointed defaultCertificate at
# "/certs/${DOMAIN}.crt" from an earlier naming scheme. That file no longer
# exists, so Traefik silently fell back to its built-in "TRAEFIK DEFAULT CERT"
# placeholder and every LAN browser showed ERR_CERT_AUTHORITY_INVALID. Both
# files are generated, not user-edited, so regenerating them is always correct.
_traefik_write_configs() {
    local dir="${DOCKER_ROOT}/traefik"

    # ── ACME requires an account email ───────────────────────────────────
    # Let's Encrypt will not register an account without one, so an empty
    # value produces `email: ""` and Traefik then never requests a single
    # certificate — silently. No error, no ACME attempt, just the fallback
    # cert and a browser warning, which is very hard to trace back here.
    #
    # This bit in practice: state.json had an empty email, so regenerating
    # traefik.yml replaced a previously working address with "". Preserve
    # whatever is already in the file rather than overwrite it with nothing.
    local acme_email="${EMAIL:-}"
    if [[ -z "$acme_email" && -f "${dir}/traefik.yml" ]]; then
        acme_email=$(grep -m1 -E '^\s+email:' "${dir}/traefik.yml" 2>/dev/null \
            | sed 's/.*email:[[:space:]]*"\?\([^"]*\)"\?.*/\1/')
        [[ -n "$acme_email" ]] && \
            log_warning "EMAIL not set — keeping existing ACME email: ${acme_email}"
    fi
    if [[ -z "$acme_email" ]]; then
        log_warning "No ACME email available. Let's Encrypt cannot issue certificates"
        echo "    without one, and Traefik will fail silently — it simply never"
        echo "    requests a certificate. Set it and repair:"
        echo "      sudo EMAIL=you@example.com bash corex-manage.sh repair traefik"
        echo "    Persist it so future repairs keep it:"
        echo "      corex manage status   # check state.json has an email"
    fi

    # ── ACME challenge selection ─────────────────────────────────────────
    # TLS-ALPN-01 (tlsChallenge) requires Let's Encrypt to reach port 443
    # from the internet. Most residential ISPs block 80/443 inbound, and
    # CGNAT makes it impossible regardless — so for a large share of CoreX's
    # target users it can never succeed. It then burns through Let's
    # Encrypt's "5 failed authorizations per hostname per hour" limit and
    # starts returning 429, which looks like a different problem entirely.
    #
    # DNS-01 needs no inbound connectivity at all: Traefik proves control by
    # writing a TXT record through the Cloudflare API. It also supports
    # wildcards. So when a Cloudflare DNS token is available, prefer it.
    local acme_challenge
    if [[ -n "${CLOUDFLARE_DNS_API_TOKEN:-}" ]]; then
        acme_challenge=$(cat << 'ACMEEOF'
      dnsChallenge:
        provider: cloudflare
        resolvers:
          - "1.1.1.1:53"
          - "8.8.8.8:53"
ACMEEOF
)
        log_info "ACME: DNS-01 via Cloudflare (works behind blocked ports/CGNAT)"
    else
        acme_challenge="      tlsChallenge: {}"
        log_warning "ACME: TLS-ALPN-01 — requires inbound port 443 from the internet."
        echo "    If your ISP blocks 443 or you are behind CGNAT, Let's Encrypt"
        echo "    cannot validate and browsers will warn about the fallback cert."
        echo "    Set CLOUDFLARE_DNS_API_TOKEN to use DNS-01 instead:"
        echo "      dash.cloudflare.com → My Profile → API Tokens → Create Token"
        echo "      Template 'Edit zone DNS', scoped to your zone."
    fi

    # ── Static config: entrypoints, providers, certificate resolvers ───
    cat > "${dir}/traefik.yml" << TEOF
# Traefik defaults to log level ERROR, which hides ALL ACME activity —
# including the reason a certificate was never requested. A misconfigured
# resolver then presents only as a browser warning with an empty log, which is
# close to undiagnosable. INFO is quiet in normal operation (a handful of lines
# at startup) and is the difference between a five-minute fix and an afternoon.
log:
  level: INFO
api:
  dashboard: true
  # insecure mode binds to the 'traefik' entrypoint (127.0.0.1:8080)
  # Docker publishes 127.0.0.1:8080 → localhost only; no external access
  insecure: true
entryPoints:
  traefik:
    # Bind to all interfaces INSIDE the container, not the container's
    # loopback. Docker publishes to a container's external interface, so an
    # entrypoint on 127.0.0.1 can never receive a published connection — the
    # dashboard and API were unreachable with "connection reset by peer".
    # Exposure is restricted by the publish itself: "127.0.0.1:8080:8080" in
    # the compose keeps it on the host's loopback only, which is the same
    # security posture but actually works.
    address: ":8080"
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":443"
    transport:
      respondingTimeouts:
        readTimeout: "0s"
        writeTimeout: "0s"
        idleTimeout: "300s"
providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
    network: proxy-net
  file:
    filename: /dynamic.yml
    watch: true
certificatesResolvers:
  myresolver:
    acme:
${acme_challenge}
      email: "${acme_email}"
      storage: /acme.json
TEOF

    # ── Default certificate: ONLY when ACME cannot work ────────────────
    # A defaultCertificate for *.DOMAIN matches every route, so Traefik TLS
    # resolution always succeeds and the certResolver is NEVER invoked: no
    # ACME request, no error, nothing in the log. Measured on a live server,
    # removing this block caused DNS-01 to issue 10 certificates within
    # seconds after months of issuing none.
    #
    # The self-signed wildcard is therefore a FALLBACK, for installs where
    # ACME is impossible (no DNS token and inbound 443 blocked). Where ACME
    # can work, publicly-valid certificates are strictly better: no per-device
    # CA trust, and they work on phones and for shared links.
    local tls_default_block
    if [[ -n "${CLOUDFLARE_DNS_API_TOKEN:-}" ]]; then
        tls_default_block="tls:
  options:
    default:
      minVersion: VersionTLS12"
        log_info "TLS: no self-signed default; ACME certificates cover all routes"
    else
        tls_default_block="tls:
  options:
    default:
      minVersion: VersionTLS12
  stores:
    default:
      defaultCertificate:
        certFile: /certs/wildcard.crt
        keyFile: /certs/wildcard.key"
        log_info "TLS: self-signed wildcard default; trust the CA on LAN clients"
    fi

    # ── Dynamic config ─────────────────────────────────────────────────
    # Traefik uses this as the fallback cert when no ACME cert matches.
    # LAN clients hitting *.DOMAIN via AdGuard DNS rewrite get a valid
    # cert (once the CA is trusted on the client device).
    cat > "${dir}/dynamic.yml" << DYEOF
${tls_default_block}
DYEOF
}

_traefik_write_compose() {
    local dir="${DOCKER_ROOT}/traefik"
    cat > "${dir}/docker-compose.yml" << DCEOF
services:
  traefik:
    image: traefik:v3.6
    container_name: traefik
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "127.0.0.1:8080:8080"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik.yml:/traefik.yml:ro
      - ./dynamic.yml:/dynamic.yml:ro
      - ./acme.json:/acme.json
      - ./certs:/certs:ro
    environment:
      # Traefik's Cloudflare DNS-01 provider reads this. Empty when no token
      # is configured, in which case tlsChallenge is used instead.
      CF_DNS_API_TOKEN: "${CLOUDFLARE_DNS_API_TOKEN:-}"
    networks: [proxy-net]
    security_opt: ["no-new-privileges:true"]
    deploy:
      resources:
        limits:
          memory: 256m
          cpus: "0.5"
        reservations:
          memory: 64m
networks:
  proxy-net: { external: true }
DCEOF
}

traefik_deploy() {
    traefik_dirs
    local dir="${DOCKER_ROOT}/traefik"

    # acme.json must exist with chmod 600 before container starts
    touch "${dir}/acme.json" && chmod 600 "${dir}/acme.json"

    # Generate self-signed CA + wildcard cert for LAN HTTPS
    _traefik_generate_lan_certs

    _traefik_write_configs

    _traefik_write_compose

    docker compose -f "${dir}/docker-compose.yml" up -d \
        || log_warning "Traefik may not have started — check: docker ps"
    state_service_installed "traefik"
    log_success "Traefik deployed (80→443, dashboard:8080)"
}

traefik_destroy() {
    local dir="${DOCKER_ROOT}/traefik"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" down
    state_service_removed "traefik"
}

traefik_status() {
    if container_running "traefik"; then echo "HEALTHY"
    elif container_exists "traefik"; then echo "UNHEALTHY"
    else echo "MISSING"; fi
}

traefik_repair() {
    traefik_dirs
    local dir="${DOCKER_ROOT}/traefik"

    # Regenerate the compose file. This module is the clearest example of why
    # it matters: the dashboard publish was changed to "127.0.0.1:8080:8080"
    # in code, but every existing install kept the old "8080:8080" binding —
    # exposing the Traefik dashboard, and therefore the whole routing table,
    # to the LAN. Docker's published ports bypass UFW, so the firewall did not
    # cover it either. Without regenerating here that fix reached nobody.
    _traefik_write_compose

    # Regenerate LAN certs if missing (e.g. after manual cleanup)
    _traefik_generate_lan_certs

    # Always regenerate traefik.yml and dynamic.yml. Doing this only when the
    # file was missing meant a stale config survived forever — which is how an
    # install ended up serving Traefik's placeholder certificate.
    _traefik_write_configs

    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" up -d --force-recreate
}

traefik_credentials() {
    echo "Traefik Dashboard: http://127.0.0.1:8080 (localhost only — SSH tunnel to access remotely)"
    echo "  SSH tunnel: ssh -L 8080:localhost:8080 user@${SERVER_IP} then open http://localhost:8080"
    if [[ -f "${DOCKER_ROOT}/traefik/certs/ca.crt" ]]; then
        echo "LAN CA cert: ${DOCKER_ROOT}/traefik/certs/ca.crt (trust on client devices for HTTPS)"
    fi
}
