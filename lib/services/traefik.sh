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
    ufw allow 8080/tcp comment 'Traefik Dashboard'                 2>/dev/null || true
}

traefik_deploy() {
    traefik_dirs
    local dir="${DOCKER_ROOT}/traefik"

    # acme.json must exist with chmod 600 before container starts
    touch "${dir}/acme.json" && chmod 600 "${dir}/acme.json"

    # Generate self-signed CA + wildcard cert for LAN HTTPS
    _traefik_generate_lan_certs

    # ── Static config: entrypoints, providers, certificate resolvers ───
    cat > "${dir}/traefik.yml" << TEOF
api:
  insecure: true
  dashboard: true
entryPoints:
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
      tlsChallenge: {}
      email: "${EMAIL}"
      storage: /acme.json
TEOF

    # ── Dynamic config: default wildcard cert for LAN HTTPS ────────────
    # Traefik uses this as the fallback cert when no ACME cert matches.
    # LAN clients hitting *.DOMAIN via AdGuard DNS rewrite get a valid
    # cert (once the CA is trusted on the client device).
    cat > "${dir}/dynamic.yml" << DYEOF
tls:
  stores:
    default:
      defaultCertificate:
        certFile: /certs/wildcard.crt
        keyFile: /certs/wildcard.key
DYEOF

    cat > "${dir}/docker-compose.yml" << DCEOF
services:
  traefik:
    image: traefik:v3.6
    container_name: traefik
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "8080:8080"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik.yml:/traefik.yml:ro
      - ./dynamic.yml:/dynamic.yml:ro
      - ./acme.json:/acme.json
      - ./certs:/certs:ro
    networks: [proxy-net]
    security_opt: ["no-new-privileges:true"]
networks:
  proxy-net: { external: true }
DCEOF

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

    # Regenerate LAN certs if missing (e.g. after manual cleanup)
    _traefik_generate_lan_certs

    # Regenerate dynamic.yml if missing
    if [[ ! -f "${dir}/dynamic.yml" ]]; then
        cat > "${dir}/dynamic.yml" << DYEOF
tls:
  stores:
    default:
      defaultCertificate:
        certFile: /certs/wildcard.crt
        keyFile: /certs/wildcard.key
DYEOF
    fi

    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" up -d --force-recreate
}

traefik_credentials() {
    echo "Traefik Dashboard: http://${SERVER_IP}:8080 (no auth)"
    if [[ -f "${DOCKER_ROOT}/traefik/certs/ca.crt" ]]; then
        echo "LAN CA cert: ${DOCKER_ROOT}/traefik/certs/ca.crt (trust on client devices for HTTPS)"
    fi
}
