#!/bin/bash
# lib/services/jellyfin.sh — CoreX Pro v2
# Jellyfin — Media Server for long-form video
#
# WHY THIS EXISTS AND WHAT IT DELIBERATELY DOES NOT DO
#
# The reason to run Jellyfin here is the library, not the transcoder. Nextcloud
# serves a video file correctly but has no notion of a library: no resume
# across devices, no per-person progress, no scrub preview, no playback speed.
# On a three hour lecture, resume is the whole feature.
#
# Transcoding is the part to avoid. This class of hardware trips at TjMax with
# no kernel log (gotcha #17), and a local build already reached 96.4C and shed
# twelve containers (gotcha #31). Compressing video on sixteen Zen 3 cores is
# the same shape of load. So the design target is Direct Play for everything:
# the server reads bytes off the disk and sends them, and the CPU stays near
# idle.
#
# That target is reachable because iPhone, iPad, Safari and Swiftfin all
# hardware-decode H.264 High at 1080p with AAC audio, which is what a screen
# recorder and a phone camera already produce. A library in that shape never
# transcodes at all.
#
# Two guards are here for when something does need converting anyway:
#
#   1. /dev/dri is passed through when the host has it, so the work lands on
#      the integrated GPU rather than on the cores. VA-API has to be switched
#      on in Dashboard > Playback once, because Jellyfin cannot detect it
#      safely and a wrong guess there is a crash loop, not a slow stream.
#   2. The CPU limit is a quarter of the machine. A runaway software transcode
#      then cannot take the box past the thermal guardian's shed band.
#
# NOT behind the shared login, and not in AUTHELIA_DEFAULT_PROTECT. Authelia
# answers an unauthenticated request with a browser redirect, and Swiftfin,
# Infuse and the Apple TV client cannot follow one, so protecting this router
# would break every native app while adding nothing: Jellyfin has its own
# accounts. The same reasoning already excludes Nextcloud and Vaultwarden
# (gotcha #44).
#
# The LAN allowlist is a different question and is wired up, because the first
# visit to a fresh install is an unauthenticated setup wizard that claims the
# server. Issuing its certificate publishes the hostname to the Certificate
# Transparency logs (gotcha #28), so "nobody knows the name" stops being true
# within minutes of deploying. Keep it off the internet until an administrator
# exists:
#
#   sudo corex manage lan-only add jellyfin && sudo corex manage repair jellyfin
#   (claim the server from home, then)
#   sudo corex manage lan-only remove jellyfin && sudo corex manage repair jellyfin
#
# NOT on host networking. DLNA discovery wants it and CoreX forbids it for
# everything but Time Machine (NOT-TO-DO #5). Clients reach the server by
# hostname instead, which works identically on the LAN and over Tailscale.

# ── Metadata ──────────────────────────────────────────────────────────────────
SERVICE_NAME="jellyfin"
SERVICE_LABEL="Jellyfin — Media Server (replaces Plex / Netflix)"
SERVICE_CATEGORY="productivity"
SERVICE_REQUIRED=false
SERVICE_NEEDS_DOMAIN=true
SERVICE_NEEDS_EMAIL=false
SERVICE_RAM_MB=1024
SERVICE_DISK_GB=10
SERVICE_DESCRIPTION="Watch your own video library on any phone, tablet or TV. Remembers where you stopped, per person. Reads files in place, so nothing is copied or moved."

# Uptime Kuma check, seeded by lib/kuma.sh so it is recreated on a fresh
# install rather than living only in Kuma's database. Tab separated:
# name, url, accepted status codes. The name is the key, so changing it
# creates a second monitor and orphans the first.
#
# /health answers without a session. The web root redirects, so a monitor on
# it reports the redirect rather than whether the server is actually serving.
SERVICE_MONITORS="Jellyfin	https://jellyfin.${DOMAIN:-}/health	[\"200-299\"]"

# ── Private Helpers ───────────────────────────────────────────────────────────

# The uid the container runs as.
#
# Jellyfin reads the Nextcloud data directory, which is 0770 www-data:www-data,
# so nothing outside uid or gid 33 can even traverse into it. Running as 33:33
# is what makes a read-only mount of that tree readable without giving the
# container root. Config and cache are chowned to match.
_JELLYFIN_UID=33
_JELLYFIN_GID=33

# Supplementary groups for /dev/dri.
#
# Read from the host rather than hardcoded: render is 993 here and 104 on a
# Debian box, and a wrong number is not an error, it is a device the container
# can see and cannot open, which surfaces later as a transcode that fails with
# no reason given.
#
# Emits the whole block including its own key, and nothing at all when the host
# has neither group. Two reasons, and the second is the one that bit.
#
# A bare "group_add:" with no entries under it is a null where compose wants a
# sequence, so the key cannot be written unconditionally.
#
# And command substitution strips every trailing newline, so a helper that ends
# with one cannot be followed by another key on the next heredoc line: the
# newline is gone by the time it is interpolated and the next key lands on the
# end of the last entry. That produced `- "44"    volumes:` on one line, which
# compose rejected with a parser error pointing at a line number rather than at
# the cause. The fix is for every block to be complete on its own and for the
# heredoc to give it a line of its own, so an empty block leaves a blank line
# rather than eating the key after it.
_jellyfin_gpu_groups() {
    local g entries=""
    for g in render video; do
        local gid
        gid=$(getent group "$g" 2>/dev/null | cut -d: -f3)
        [[ -n "$gid" ]] && entries+="      - \"${gid}\"\n"
    done
    [[ -z "$entries" ]] && return 0
    printf '    group_add:\n%b' "${entries%\\n}"
}

# Media mounts, all read-only.
#
# Read-only is not a nicety. Nextcloud tracks every file it owns in its own
# database, so a second process writing into that tree produces files the web
# UI cannot see and a scan that has to be run by hand to reconcile. Jellyfin
# only ever reads, and its own state lives in /config.
#
# The whole Nextcloud data directory is mounted at /media/nextcloud rather than
# one path per account, because accounts are created after this module is
# written. Libraries then point at /media/nextcloud/<account>/files/<folder>,
# and a new account needs no compose change.
_jellyfin_media_mounts() {
    local out=""
    if [[ -d "${DATA_ROOT}/nextcloud-html/data" ]]; then
        out+="      - ${DATA_ROOT}/nextcloud-html/data:/media/nextcloud:ro\n"
    fi
    out+="      - ${DATA_ROOT}/jellyfin-media:/media/library:ro"
    printf '%b' "$out"
}

# ── Functions ─────────────────────────────────────────────────────────────────

jellyfin_dirs() {
    mkdir -p "${DOCKER_ROOT}/jellyfin" \
             "${DATA_ROOT}/jellyfin/config" \
             "${DATA_ROOT}/jellyfin/cache" \
             "${DATA_ROOT}/jellyfin-media"
    chown -R "${_JELLYFIN_UID}:${_JELLYFIN_GID}" "${DATA_ROOT}/jellyfin"
    chown -R "${_JELLYFIN_UID}:${_JELLYFIN_GID}" "${DATA_ROOT}/jellyfin-media"
}

jellyfin_firewall() {
    : # Traefik serves it over HTTPS; nothing is published to the host
}

jellyfin_deploy() {
    jellyfin_dirs
    local dir="${DOCKER_ROOT}/jellyfin"

    local gpu_groups media_mounts dri_device="" sso_label=""
    gpu_groups="$(_jellyfin_gpu_groups)"
    media_mounts="$(_jellyfin_media_mounts)"
    # Guarded with declare -f so a module sourced without common.sh degrades to
    # no label rather than to command not found (gotcha #44). In practice this
    # only ever carries corex-lan@file, because jellyfin is deliberately absent
    # from AUTHELIA_DEFAULT_PROTECT.
    declare -f sso_label_for >/dev/null 2>&1 && sso_label="$(sso_label_for jellyfin)"
    # Only pass the device through when the host actually has one. Naming a
    # missing device in compose is a hard start failure, so a box with no
    # integrated GPU would otherwise refuse to run the service at all.
    [[ -e /dev/dri ]] && dri_device="    devices: [\"/dev/dri:/dev/dri\"]"

    cat > "${dir}/docker-compose.yml" << DCEOF
services:
  jellyfin:
    image: jellyfin/jellyfin:12.0
    container_name: jellyfin
    restart: unless-stopped
    user: "${_JELLYFIN_UID}:${_JELLYFIN_GID}"
${gpu_groups}
    volumes:
      - ${DATA_ROOT}/jellyfin/config:/config
      - ${DATA_ROOT}/jellyfin/cache:/cache
${media_mounts}
    environment:
      TZ: "${TIMEZONE}"
      JELLYFIN_PublishedServerUrl: "https://jellyfin.${DOMAIN}"
${dri_device}
    networks: [proxy-net]
    security_opt: ["no-new-privileges:true"]
    deploy:
      resources:
        limits:
          memory: 2g
          cpus: "4.0"
        reservations:
          memory: 256m
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.jellyfin.rule=Host(\`jellyfin.${DOMAIN}\`)"
      - "traefik.http.routers.jellyfin.entrypoints=websecure"
      - "traefik.http.routers.jellyfin.tls.certresolver=myresolver"
      - "traefik.http.services.jellyfin.loadbalancer.server.port=8096"
${sso_label}
networks:
  proxy-net: { external: true }
DCEOF

    docker compose -f "${dir}/docker-compose.yml" up -d \
        || log_warning "Jellyfin may not have started — check: docker logs jellyfin"
    state_service_installed "jellyfin"
    log_success "Jellyfin deployed (jellyfin.${DOMAIN})"
}

jellyfin_destroy() {
    local dir="${DOCKER_ROOT}/jellyfin"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" down
    state_service_removed "jellyfin"
}

jellyfin_status() {
    if container_running "jellyfin"; then echo "HEALTHY"
    elif container_exists "jellyfin"; then echo "UNHEALTHY"
    else echo "MISSING"; fi
}

jellyfin_repair() {
    # Regenerate the compose file before recreating, so a fix to the media
    # mounts, the GPU groups or the Traefik labels reaches an install that
    # already exists. Deploy is idempotent, which is what makes this safe
    # (gotcha #22).
    jellyfin_deploy
    local dir="${DOCKER_ROOT}/jellyfin"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" up -d --force-recreate
}

jellyfin_credentials() {
    echo "Jellyfin: https://jellyfin.${DOMAIN}"
    echo "  First visit runs the setup wizard. The account you create there is the"
    echo "  administrator, and the wizard is reachable by anyone until you finish it."
    echo "  Add libraries from: /media/nextcloud/<account>/files/<folder>"
    echo "  Give each extra person their own account under Dashboard > Users, and"
    echo "  untick the libraries they should not see."
    echo "  Leave hardware acceleration off unless something actually transcodes."
    echo "  iPhone and iPad: install Swiftfin, server address https://jellyfin.${DOMAIN}"
}
