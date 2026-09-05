#!/bin/bash
# Opt-in wake-on-request controller. No public port or Traefik router.
SERVICE_NAME="sablier"
SERVICE_LABEL="Sablier — On-demand Services"
SERVICE_CATEGORY="core"
SERVICE_REQUIRED=false
# Infrastructure for `corex manage cold`; it is installed automatically when
# needed and should not appear in setup profiles or the custom-service list.
SERVICE_HIDDEN=true
SERVICE_NEEDS_DOMAIN=true
SERVICE_NEEDS_EMAIL=false
SERVICE_RAM_MB=64
SERVICE_DISK_GB=1
SERVICE_FIREWALL_SPECS=()
SERVICE_MONITORS=""
SERVICE_DESCRIPTION="Starts opted-in web services on access and stops them after idle time. Calendar sync and scheduled services remain running."
sablier_dirs() { mkdir -p "${DOCKER_ROOT}/sablier"; }
sablier_firewall() { :; }
sablier_deploy() {
    sablier_dirs
    cat > "${DOCKER_ROOT}/sablier/docker-compose.yml" <<'DCEOF'
services:
  sablier:
    image: sablierapp/sablier:1.17.0
    container_name: corex-sablier
    restart: unless-stopped
    command:
      - start
      - --provider.name=docker
      - --provider.reject-unlabeled-requests=true
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    networks: [proxy-net]
    security_opt: ["no-new-privileges:true"]
    logging:
      driver: json-file
      options: { max-size: "5m", max-file: "2" }
    deploy:
      resources:
        limits: { memory: 128m, cpus: "0.25" }
networks:
  proxy-net: { external: true }
DCEOF
    docker compose -f "${DOCKER_ROOT}/sablier/docker-compose.yml" up -d || return 1
    state_service_installed sablier
}
sablier_destroy() {
    if [[ "$(state_get cold_portainer 2>/dev/null)" == true ]] ||
       [[ "$(state_get cold_grafana 2>/dev/null)" == true ]]; then
        log_warning "Disable Portainer and Grafana cold mode before removing their wake controller."; return 1
    fi
    docker compose -f "${DOCKER_ROOT}/sablier/docker-compose.yml" down || return 1
    state_service_removed sablier
}
sablier_status() {
    if container_running corex-sablier; then echo HEALTHY
    elif container_exists corex-sablier; then echo UNHEALTHY
    else echo MISSING; fi
}
sablier_repair() { sablier_deploy; }
sablier_credentials() { echo "Sablier: internal wake controller; no public login."; }
