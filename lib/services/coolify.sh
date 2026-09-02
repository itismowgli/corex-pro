#!/bin/bash
# lib/services/coolify.sh — CoreX Pro v2
# Coolify — Web Hosting PaaS (Vercel / Netlify / Heroku alternative)
#
# CRITICAL NOTES:
#   - Coolify self-installs its own Docker stack and its own Traefik instance
#   - NEVER auto-install via this script — port conflicts with CoreX Traefik
#   - Run the helper install script MANUALLY after CoreX is fully set up
#   - FIRST VISITOR at port 8000 becomes admin — do it immediately
#   - Reached at https://coolify.DOMAIN through a Traefik file-provider route.
#     Coolify runs on its own Docker network with no path to proxy-net, so
#     Traefik cannot discover it by label and has to address it directly.

# ── Metadata ──────────────────────────────────────────────────────────────────
SERVICE_NAME="coolify"
SERVICE_LABEL="Coolify — Web Hosting PaaS (replaces Vercel / Netlify)"
SERVICE_CATEGORY="productivity"
SERVICE_REQUIRED=false
SERVICE_NEEDS_DOMAIN=false
SERVICE_NEEDS_EMAIL=false
SERVICE_RAM_MB=1024
SERVICE_DISK_GB=5
# UFW rules this service opens, as full `ufw allow` specs. cmd_remove
# revokes them, because leaving a port open with nothing behind it is all
# of the exposure and none of the service.
SERVICE_FIREWALL_SPECS=("8000/tcp")
SERVICE_DESCRIPTION="Deploy web apps, APIs, and databases with one click. Connect GitHub for auto-deploys. Replaces Vercel, Netlify, Heroku, and Railway."

# ── Functions ─────────────────────────────────────────────────────────────────

coolify_dirs() {
    mkdir -p "${DOCKER_ROOT}/coolify"
}

coolify_firewall() {
    # Port 8000 stays open on the LAN. It is how Coolify is reached before the
    # Traefik route exists, and the route itself connects to it.
    ufw allow 8000/tcp comment 'Coolify Web Hosting' 2>/dev/null || true
}

# ── _coolify_write_route ──────────────────────────────────────────────────────
# Publish Coolify at https://coolify.DOMAIN.
#
# Coolify installs its own stack on its own `coolify` Docker network, with no
# interface on proxy-net, so `coolify:8080` does not resolve from Traefik and a
# Docker label cannot describe the backend. Traefik therefore addresses it by
# the server's own address and published port.
#
# The route lives in Traefik's file-provider directory rather than in
# Coolify's compose, because Coolify manages that compose and rewrites it on
# upgrade. This file survives a Coolify reinstall untouched.
_coolify_write_route() {
    local route_dir="${DOCKER_ROOT}/traefik/dynamic"
    local route="${route_dir}/coolify.yml"

    # Without a domain there is nothing to route; port 8000 is still the way in.
    if [[ -z "${DOMAIN:-}" ]]; then
        rm -f "$route"
        return 0
    fi
    [[ -d "$route_dir" ]] || return 0

    cat > "$route" << CFEOF
http:
  routers:
    coolify:
      rule: "Host(\`coolify.${DOMAIN}\`)"
      entryPoints:
        - websecure
      service: coolify
      tls:
        certResolver: myresolver
  services:
    coolify:
      loadBalancer:
        servers:
          - url: "http://${SERVER_IP}:8000"
CFEOF
    log_success "Coolify route written: https://coolify.${DOMAIN}"
}

coolify_deploy() {
    coolify_dirs
    local dir="${DOCKER_ROOT}/coolify"

    # Coolify cannot be auto-installed (it installs its own Traefik which conflicts)
    # We create a helper script to be run manually instead
    cat > "${dir}/install.sh" << 'CLEOF'
#!/bin/bash
echo "Installing Coolify (self-hosted Vercel/Netlify/Heroku)..."
echo "This installs its own Docker containers and Traefik instance."
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
echo ""
echo "Done! Access at http://YOUR_SERVER_IP:8000"
echo "⚠ Create admin account IMMEDIATELY — first visitor becomes admin!"
CLEOF
    chmod +x "${dir}/install.sh"

    log_warning "Coolify: run manually after setup is complete:"
    log_warning "  cd ${DOCKER_ROOT}/coolify && sudo ./install.sh"

    _coolify_write_route

    state_service_installed "coolify"
    log_success "Coolify helper script created (manual install required)"
}

coolify_destroy() {
    rm -f "${DOCKER_ROOT}/traefik/dynamic/coolify.yml"
    # Coolify has its own uninstaller
    log_warning "Coolify must be removed manually (it manages its own stack)"
    log_warning "See: https://coolify.io/docs/installation#uninstall"
    state_service_removed "coolify"
}

coolify_status() {
    if container_running "coolify-realtime"; then echo "HEALTHY"
    elif container_exists "coolify-realtime"; then echo "UNHEALTHY"
    else echo "MISSING"; fi
}

coolify_repair() {
    # The route is CoreX's to regenerate even though the stack is not.
    _coolify_write_route
    log_warning "Coolify manages its own stack. To repair the stack itself:"
    log_warning "  curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash"
}

coolify_credentials() {
    if [[ -n "${DOMAIN:-}" ]]; then
        echo "Coolify: https://coolify.${DOMAIN} (create admin on first visit)"
        echo "  Also on the LAN at http://${SERVER_IP}:8000"
    else
        echo "Coolify: http://${SERVER_IP}:8000 (create admin on first visit)"
    fi
    echo "  Run installer: cd ${DOCKER_ROOT}/coolify && sudo ./install.sh"
    echo "  Set the same URL as Coolify's own Instance FQDN in its settings,"
    echo "  or it will keep generating links to port 8000"
}
