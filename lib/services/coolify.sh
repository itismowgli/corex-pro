#!/bin/bash
# lib/services/coolify.sh — CoreX Pro v2
# Coolify — Web Hosting PaaS (Vercel / Netlify / Heroku alternative)
#
# CRITICAL NOTES:
#   - Coolify self-installs its own Docker stack and its own Traefik instance
#   - NEVER auto-install via this script — port conflicts with CoreX Traefik
#   - Run the helper install script MANUALLY after CoreX is fully set up
#   - FIRST VISITOR at port 8000 becomes admin — do it immediately

# ── Metadata ──────────────────────────────────────────────────────────────────
SERVICE_NAME="coolify"
SERVICE_LABEL="Coolify — Web Hosting PaaS (replaces Vercel / Netlify)"
SERVICE_CATEGORY="productivity"
SERVICE_REQUIRED=false
SERVICE_NEEDS_DOMAIN=false
SERVICE_NEEDS_EMAIL=false
SERVICE_RAM_MB=1024
SERVICE_DISK_GB=5
SERVICE_DESCRIPTION="Deploy web apps, APIs, and databases with one click. Connect GitHub for auto-deploys. Replaces Vercel, Netlify, Heroku, and Railway."

# ── Functions ─────────────────────────────────────────────────────────────────

coolify_dirs() {
    mkdir -p "${DOCKER_ROOT}/coolify"
}

coolify_firewall() {
    ufw allow 8000/tcp comment 'Coolify Web Hosting' 2>/dev/null || true
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

    state_service_installed "coolify"
    log_success "Coolify helper script created (manual install required)"
}

coolify_destroy() {
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
    log_warning "Coolify manages its own stack. To repair:"
    log_warning "  curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash"
}

coolify_credentials() {
    echo "Coolify: http://${SERVER_IP}:8000 (create admin on first visit)"
    echo "  Run installer: cd ${DOCKER_ROOT}/coolify && sudo ./install.sh"
}
