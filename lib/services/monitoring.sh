#!/bin/bash
# lib/services/monitoring.sh — CoreX Pro v2
# Monitoring Stack — Uptime Kuma + Grafana + Prometheus + Node Exporter + cAdvisor
#
# CRITICAL NOTES:
#   - Prometheus data dir MUST be owned by uid 65534 (nobody:nogroup)
#   - Grafana data dir MUST be owned by uid 472 (grafana user in container)
#   - prometheus.yml is a file mount (not directory) — create file first
#   - monitoring-net is separate from proxy-net (Prometheus/exporters not exposed)

# ── Metadata ──────────────────────────────────────────────────────────────────
SERVICE_NAME="monitoring"
SERVICE_LABEL="Monitoring Stack — Uptime Kuma + Grafana + Prometheus"
SERVICE_CATEGORY="monitoring"
SERVICE_REQUIRED=false
SERVICE_NEEDS_DOMAIN=true
SERVICE_NEEDS_EMAIL=false
SERVICE_RAM_MB=1024
SERVICE_DISK_GB=5
SERVICE_DESCRIPTION="Complete observability stack. Uptime Kuma for status pages, Grafana for dashboards, Prometheus for metrics collection. Monitor all services from one place."

# ── Functions ─────────────────────────────────────────────────────────────────

monitoring_dirs() {
    mkdir -p "${DOCKER_ROOT}/monitoring"
    mkdir -p "${DATA_ROOT}/uptime-kuma" "${DATA_ROOT}/grafana" "${DATA_ROOT}/prometheus"
    chown -R 1000:1000 "${DATA_ROOT}/uptime-kuma"
    chown -R 472:472 "${DATA_ROOT}/grafana"         # Grafana runs as uid 472
    chown -R 65534:65534 "${DATA_ROOT}/prometheus"  # Prometheus runs as nobody (65534)
}

monitoring_firewall() {
    ufw allow 3001/tcp comment 'Uptime Kuma Status Page' 2>/dev/null || true
    ufw allow 3002/tcp comment 'Grafana Dashboards'      2>/dev/null || true
    ufw allow 9090/tcp comment 'Prometheus (LAN only)'   2>/dev/null || true
}

monitoring_deploy() {
    monitoring_dirs
    local dir="${DOCKER_ROOT}/monitoring"

    # Prometheus scrape config
    cat > "${dir}/prometheus.yml" << PEOF
global:
  scrape_interval: 30s

scrape_configs:
  - job_name: node
    static_configs:
      - targets: ["node-exporter:9100"]
  - job_name: cadvisor
    static_configs:
      - targets: ["cadvisor:8080"]
PEOF

    cat > "${dir}/docker-compose.yml" << DCEOF
services:
  uptime-kuma:
    image: louislam/uptime-kuma:latest
    container_name: uptime-kuma
    restart: unless-stopped
    ports: ["3001:3001"]
    volumes:
      - ${DATA_ROOT}/uptime-kuma:/app/data
    networks: [proxy-net, monitoring-net]
    security_opt: ["no-new-privileges:true"]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.uptime.rule=Host(\`status.${DOMAIN}\`)"
      - "traefik.http.routers.uptime.entrypoints=websecure"
      - "traefik.http.routers.uptime.tls.certresolver=myresolver"
      - "traefik.http.services.uptime.loadbalancer.server.port=3001"

  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    restart: unless-stopped
    ports: ["9090:9090"]
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ${DATA_ROOT}/prometheus:/prometheus
    command: ["--config.file=/etc/prometheus/prometheus.yml", "--storage.tsdb.retention.time=30d"]
    networks: [monitoring-net]

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    restart: unless-stopped
    ports: ["3002:3000"]
    volumes:
      - ${DATA_ROOT}/grafana:/var/lib/grafana
    environment:
      GF_SECURITY_ADMIN_PASSWORD: "${GRAFANA_ADMIN_PASS}"
      GF_SERVER_ROOT_URL: "https://grafana.${DOMAIN}"
    networks: [proxy-net, monitoring-net]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.grafana.rule=Host(\`grafana.${DOMAIN}\`)"
      - "traefik.http.routers.grafana.entrypoints=websecure"
      - "traefik.http.routers.grafana.tls.certresolver=myresolver"
      - "traefik.http.services.grafana.loadbalancer.server.port=3000"

  node-exporter:
    image: prom/node-exporter:latest
    container_name: node-exporter
    restart: unless-stopped
    pid: host
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    command: ["--path.procfs=/host/proc", "--path.sysfs=/host/sys", "--path.rootfs=/rootfs"]
    networks: [monitoring-net]

  cadvisor:
    image: gcr.io/cadvisor/cadvisor:latest
    container_name: cadvisor
    restart: unless-stopped
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker:/var/lib/docker:ro
    networks: [monitoring-net]

networks:
  proxy-net: { external: true }
  monitoring-net: { external: true }
DCEOF

    docker compose -f "${dir}/docker-compose.yml" up -d \
        || log_warning "Monitoring stack may not have fully started — check: docker ps"
    state_service_installed "monitoring"
    log_success "Monitoring deployed (Kuma:3001, Grafana:3002, Prometheus:9090)"
}

monitoring_destroy() {
    local dir="${DOCKER_ROOT}/monitoring"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" down
    state_service_removed "monitoring"
}

monitoring_status() {
    if container_running "uptime-kuma" && container_running "grafana"; then echo "HEALTHY"
    elif container_exists "uptime-kuma"; then echo "UNHEALTHY"
    else echo "MISSING"; fi
}

monitoring_repair() {
    local dir="${DOCKER_ROOT}/monitoring"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" up -d --force-recreate
}

monitoring_credentials() {
    echo "Uptime Kuma: https://status.${DOMAIN} (create admin on first visit)"
    echo "Grafana: https://grafana.${DOMAIN}"
    echo "  Username: admin"
    echo "  Password: ${GRAFANA_ADMIN_PASS}"
}
