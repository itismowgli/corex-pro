#!/bin/bash
# lib/services/timemachine.sh — CoreX Pro v2
# Time Machine — macOS Backup Server via high-performance SMB3
#
# CRITICAL NOTES:
#   - Uses host networking (required for SMB and mDNS/Bonjour discovery)
#   - CANNOT be behind Traefik (host networking incompatible with Docker networks)
#   - Env var is PASSWORD (not TM_PASSWORD) for mbentley/timemachine image
#   - Data stored on corex-data pool (not dedicated partition) for flexibility
#   - macOS discovers via Bonjour automatically; manual: smb://SERVER_IP/CoreX_Backup
#   - CoreX supplies the complete /etc/samba/smb.conf (CUSTOM_SMB_CONF=true), so it
#     must include the image's own fruit: settings, not only the CoreX tuning

# ── Metadata ──────────────────────────────────────────────────────────────────
SERVICE_NAME="timemachine"
SERVICE_LABEL="Time Machine — macOS Backup Server (High-Speed SMB3)"
SERVICE_CATEGORY="backup"
SERVICE_REQUIRED=false
SERVICE_NEEDS_DOMAIN=false
SERVICE_NEEDS_EMAIL=false
SERVICE_RAM_MB=256
SERVICE_DISK_GB=0
# UFW rules this service opens, as full `ufw allow` specs. cmd_remove
# revokes them, because leaving a port open with nothing behind it is all
# of the exposure and none of the service.
SERVICE_FIREWALL_SPECS=("from ${LAN_SUBNET:-192.168.0.0/16} to any port 445 proto tcp" "from ${LAN_SUBNET:-192.168.0.0/16} to any port 137:139 proto tcp" "5353/udp")
SERVICE_DESCRIPTION="macOS Time Machine backup server over high-performance SMB3. Multi-gigabit LAN transfers with multichannel support. Your Mac backs up automatically over Wi-Fi."

# ── Functions ─────────────────────────────────────────────────────────────────

timemachine_dirs() {
    mkdir -p "${DOCKER_ROOT}/timemachine"
    mkdir -p "${MOUNT_POOL}/timemachine-data"
    chown -R 1000:1000 "${MOUNT_POOL}/timemachine-data"
}

timemachine_firewall() {
    # SMB and NetBIOS — LAN only (restrict to local subnet)
    local lan_subnet="${SERVER_IP%.*}.0/24"
    ufw allow from "$lan_subnet" to any port 445 proto tcp   comment 'SMB (Time Machine)' 2>/dev/null || true
    ufw allow from "$lan_subnet" to any port 137:139 proto tcp comment 'NetBIOS (Time Machine)' 2>/dev/null || true
    ufw allow 5353/udp comment 'mDNS (Bonjour/Avahi discovery)' 2>/dev/null || true
}

timemachine_deploy() {
    timemachine_dirs
    local dir="${DOCKER_ROOT}/timemachine"

    # ── Complete smb.conf ────────────────────────────────────────────────────
    # CUSTOM_SMB_CONF=true tells mbentley/timemachine "the operator supplies
    # the whole of /etc/samba/smb.conf", so the image generates nothing at all
    # and exits 1 if that exact path is not mounted. CoreX previously set the
    # flag while mounting a partial overlay at /etc/samba/smb-performance.conf,
    # a path the image never reads, so the container crash-looped indefinitely
    # with "you did not bind mount a config to /etc/samba/smb.conf". None of
    # the performance tuning below was ever in effect. See gotcha #29.
    #
    # The [global] block therefore has to reproduce what the image's own
    # entrypoint would have generated, not just the parts CoreX wants to
    # change. Anything omitted here is simply absent, including the fruit:
    # settings that make Time Machine work at all.
    local tm_share="CoreX_Backup" tm_user="timemachine"
    cat > "${dir}/smb.conf" << SMBEOF
[global]
   access based share enum = no
   hide unreadable = no
   inherit permissions = no
   load printers = no
   log file = /var/log/samba/log.%m
   logging = file
   max log size = 1000
   security = user
   server role = standalone server
   ntlm auth = no
   smb ports = 445
   workgroup = WORKGROUP
   vfs objects = fruit streams_xattr

# Apple extensions. Without fruit:aapl macOS does not offer the share as a
# Time Machine target, and without streams_xattr the sparsebundle metadata has
# nowhere to live.
   fruit:aapl = yes
   fruit:nfs_aces = no
   fruit:model = TimeCapsule8,119
   fruit:metadata = stream
   fruit:veto_appledouble = no
   fruit:posix_rename = yes
   fruit:zero_file_id = yes
   fruit:wipe_intentionally_left_blank_rfork = yes
   fruit:delete_empty_adfiles = yes

# SMB3 minimum, which also rules out SMB1 and SMB2. The image would otherwise
# default to SMB2.
   server min protocol = SMB3_00
   client min protocol = SMB3_00
   server multi channel support = yes

# Throughput. Note what is deliberately absent: SO_RCVBUF and SO_SNDBUF.
# Setting either disables Linux TCP buffer autotuning and pins the window at
# the value given, which on this box would override the 64MB buffers
# "corex manage network-tune" configures. Samba's own testparm warns about
# exactly this. TCP_NODELAY and IPTOS_LOWDELAY carry no such cost.
   socket options = TCP_NODELAY IPTOS_LOWDELAY
   max xmit = 8388608
   use sendfile = yes
   aio read size = 1
   aio write size = 1
   min receivefile size = 16384

# Let the client cache aggressively. A Time Machine share has exactly one
# writer, so contention is not a concern.
   oplocks = yes
   level2 oplocks = yes
   kernel oplocks = no
   strict locking = no
   log level = 1

[${tm_share}]
   path = /opt/${tm_user}
   inherit permissions = no
   read only = no
   valid users = ${tm_user}
   vfs objects = fruit streams_xattr
   fruit:time machine = yes
   fruit:time machine max size = 0
SMBEOF

    # The old overlay is dead weight and its filename implies it does
    # something. Remove it so nobody edits it expecting an effect.
    rm -f "${dir}/smb-performance.conf"

    cat > "${dir}/docker-compose.yml" << DCEOF
services:
  timemachine:
    image: mbentley/timemachine:smb
    container_name: timemachine
    restart: unless-stopped
    network_mode: host
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    environment:
      TM_USERNAME: timemachine
      PASSWORD: "${TM_PASSWORD}"
      TM_UID: "1000"
      TM_GID: "1000"
      SHARE_NAME: CoreX_Backup
      VOLUME_SIZE_LIMIT: "0"
      SET_PERMISSIONS: "false"
      CUSTOM_SMB_CONF: "true"
      SMB_INHERIT_PERMISSIONS: "no"
    volumes:
      - ${MOUNT_POOL}/timemachine-data:/opt/timemachine
      - ${DOCKER_ROOT}/timemachine/smb.conf:/etc/samba/smb.conf:ro
    deploy:
      resources:
        limits:
          memory: 512m
          cpus: "1.0"
        reservations:
          memory: 64m
volumes: {}
DCEOF

    docker compose -f "${dir}/docker-compose.yml" up -d \
        || log_warning "Time Machine may not have started — check: docker ps"
    state_service_installed "timemachine"
    log_success "Time Machine deployed (high-perf SMB3:445, smb://${SERVER_IP}/CoreX_Backup)"
}

timemachine_destroy() {
    local dir="${DOCKER_ROOT}/timemachine"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" down
    state_service_removed "timemachine"
}

timemachine_status() {
    if container_running "timemachine"; then echo "HEALTHY"
    elif container_exists "timemachine"; then echo "UNHEALTHY"
    else echo "MISSING"; fi
}

timemachine_repair() {
    # Regenerate the compose file first. Without this, repair recreated the
    # container from a compose file that could be months old, so CoreX fixes
    # to env vars, resource limits, security_opt, published ports or Traefik
    # labels never reached an existing install. timemachine_deploy is idempotent
    # by design (see CLAUDE.md "Idempotency pattern"), so calling it here is
    # safe and is what makes `corex doctor` able to deliver fixes at all.
    timemachine_deploy
    local dir="${DOCKER_ROOT}/timemachine"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" up -d --force-recreate
}

timemachine_credentials() {
    echo "Time Machine: smb://${SERVER_IP}/CoreX_Backup"
    echo "  Username: timemachine"
    echo "  Password: ${TM_PASSWORD}"
}
