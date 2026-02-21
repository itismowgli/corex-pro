#!/bin/bash
# lib/services/ai.sh — CoreX Pro v2
# AI Stack — Ollama + Open WebUI + Browserless
#
# NOTES:
#   - Ollama: local LLM engine; downloads models on demand
#   - Open WebUI: ChatGPT-like interface connected to Ollama
#   - Browserless: headless Chrome API for AI agents to browse the web
#   - All on ai-net (sandboxed) + open-webui/ollama also on proxy-net
#   - WEBUI_SECRET_KEY is used as both WebUI and Browserless API token
#   - GPU support: uncomment deploy section in compose for NVIDIA GPU

# ── Metadata ──────────────────────────────────────────────────────────────────
SERVICE_NAME="ai"
SERVICE_LABEL="AI Stack — Ollama + Open WebUI + Browserless"
SERVICE_CATEGORY="ai"
SERVICE_REQUIRED=false
SERVICE_NEEDS_DOMAIN=true
SERVICE_NEEDS_EMAIL=false
SERVICE_RAM_MB=4096
SERVICE_DISK_GB=20
SERVICE_DESCRIPTION="Local AI chat with open-source models (Llama, Mistral, etc.). No API costs, complete privacy. Includes web browsing capability for AI agents."

# ── Functions ─────────────────────────────────────────────────────────────────

ai_dirs() {
    mkdir -p "${DOCKER_ROOT}/ai"
    mkdir -p "${DATA_ROOT}/ollama" "${DATA_ROOT}/open-webui" "${DATA_ROOT}/browserless"
    chown -R 1000:1000 "${DATA_ROOT}/ollama" "${DATA_ROOT}/open-webui" "${DATA_ROOT}/browserless"
}

ai_firewall() {
    local lan_subnet="${SERVER_IP%.*}.0/24"
    ufw allow from "$lan_subnet" to any port 11434 proto tcp comment 'Ollama LLM (LAN only)' 2>/dev/null || true
    ufw allow from "$lan_subnet" to any port 3003 proto tcp comment 'Open WebUI (LAN only)'  2>/dev/null || true
}

ai_deploy() {
    ai_dirs
    local dir="${DOCKER_ROOT}/ai"

    cat > "${dir}/docker-compose.yml" << DCEOF
services:
  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    restart: unless-stopped
    ports: ["11434:11434"]
    volumes:
      - ${DATA_ROOT}/ollama:/root/.ollama
    networks: [ai-net, proxy-net]
    security_opt: ["no-new-privileges:true"]
    # Uncomment for NVIDIA GPU support:
    # deploy:
    #   resources:
    #     reservations:
    #       devices:
    #         - driver: nvidia
    #           count: all
    #           capabilities: [gpu]

  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    restart: unless-stopped
    ports: ["3003:8080"]
    volumes:
      - ${DATA_ROOT}/open-webui:/app/backend/data
    environment:
      OLLAMA_BASE_URL: "http://ollama:11434"
      WEBUI_SECRET_KEY: "${WEBUI_SECRET_KEY}"
    depends_on: [ollama]
    networks: [ai-net, proxy-net]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.ai.rule=Host(\`ai.${DOMAIN}\`)"
      - "traefik.http.routers.ai.entrypoints=websecure"
      - "traefik.http.routers.ai.tls.certresolver=myresolver"
      - "traefik.http.services.ai.loadbalancer.server.port=8080"

  browserless:
    image: browserless/chrome:latest
    container_name: browserless
    restart: unless-stopped
    ports: ["3005:3000"]
    environment:
      TOKEN: "${WEBUI_SECRET_KEY}"
      MAX_CONCURRENT_SESSIONS: "5"
    networks: [ai-net]
    security_opt: ["no-new-privileges:true"]

networks:
  ai-net: { external: true }
  proxy-net: { external: true }
DCEOF

    docker compose -f "${dir}/docker-compose.yml" up -d \
        || log_warning "AI stack may not have fully started — check: docker ps"

    # Pull a lightweight model in background
    log_info "Pulling llama3.2:3b model in background (this may take a few minutes)..."
    sleep 5
    (docker exec ollama ollama pull llama3.2:3b 2>/dev/null || true) &

    state_service_installed "ai"
    log_success "AI Stack deployed (Ollama:11434, WebUI:3003, Browserless:3005)"
}

ai_destroy() {
    local dir="${DOCKER_ROOT}/ai"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" down
    state_service_removed "ai"
}

ai_status() {
    if container_running "ollama" && container_running "open-webui"; then echo "HEALTHY"
    elif container_exists "ollama"; then echo "UNHEALTHY"
    else echo "MISSING"; fi
}

ai_repair() {
    local dir="${DOCKER_ROOT}/ai"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" up -d --force-recreate
}

ai_credentials() {
    echo "Open WebUI (AI Chat): https://ai.${DOMAIN} (create admin on first visit)"
    echo "  Ollama API: http://${SERVER_IP}:11434"
    echo "  Browserless: http://${SERVER_IP}:3005"
    echo "  WebUI Secret: ${WEBUI_SECRET_KEY}"
}
