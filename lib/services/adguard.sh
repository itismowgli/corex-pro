#!/bin/bash
# lib/services/adguard.sh — CoreX Pro v2
# AdGuard Home — DNS Server & Ad Blocker
#
# CRITICAL NOTES:
#   - FIRST RUN: wizard listens on port 3000 inside container
#   - AFTER SETUP: switches to port 80 inside container (or configured port)
#   - We detect which state we're in from AdGuardHome.yaml
#   - systemd-resolved MUST be disabled; resolv.conf locked with chattr +i
#   - After setup: add DNS rewrites *.domain → SERVER_IP in AdGuard UI

# ── Metadata ──────────────────────────────────────────────────────────────────
SERVICE_NAME="adguard"
SERVICE_LABEL="AdGuard Home — DNS & Ad Blocker"
SERVICE_CATEGORY="core"
SERVICE_REQUIRED=true
SERVICE_NEEDS_DOMAIN=false
SERVICE_NEEDS_EMAIL=false
SERVICE_RAM_MB=64
SERVICE_DISK_GB=1
# UFW rules this service opens, as full `ufw allow` specs. cmd_remove
# revokes them, because leaving a port open with nothing behind it is all
# of the exposure and none of the service.
SERVICE_FIREWALL_SPECS=("53" "3000/tcp" "5353/udp")
SERVICE_DESCRIPTION="Network-wide ad blocker and DNS server. Blocks ads on all devices. Required for local domain routing (*.yourdomain → server IP)."

# Uptime Kuma check, seeded by lib/kuma.sh so it is recreated on a fresh
# install rather than living only in Kuma's database. Tab separated:
# name, url, accepted status codes. The name is the key, so changing it
# creates a second monitor and orphans the first.
SERVICE_MONITORS="AdGuard Home	http://${SERVER_IP:-}:3000	[\"200-299\",\"302\"]"

# ── Functions ─────────────────────────────────────────────────────────────────

adguard_dirs() {
    mkdir -p "${DOCKER_ROOT}/adguard"
    mkdir -p "${DATA_ROOT}/adguard-work" "${DATA_ROOT}/adguard-conf"
}

adguard_firewall() {
    ufw allow 53    comment 'DNS (AdGuard Home, TCP+UDP)'    2>/dev/null || true
    ufw allow 3000/tcp comment 'AdGuard Home Setup UI'       2>/dev/null || true
    ufw allow 5353/udp comment 'mDNS (Avahi/Bonjour)'       2>/dev/null || true
}

# Add the maintained CoreX filter baseline to an AdGuard configuration that
# has completed the first-run wizard.  The wizard enables only AdGuard's one
# default list; that is a useful start, but it leaves a lot of app telemetry,
# trackers and less common ad networks untouched.
#
# Multi PRO is HaGeZi's balanced, recommended list.  The full TIF security list
# needs at least 2 GB in AdGuard Home, so CoreX uses TIF Mini: it keeps the
# high-value phishing/malware coverage without turning DNS into the largest
# process on a small home server.  Existing lists, rewrites and user rules are
# preserved.  Fixed high IDs avoid AdGuard's built-in registry IDs; if an
# existing custom list already uses one, the next free ID is selected.
#
# AdGuard owns and periodically rewrites its YAML, so it must be stopped for
# the atomic replacement.  The caller is adguard_deploy(), which starts it
# again immediately through `docker compose up`.
_adguard_seed_filter_lists() {
    local yaml="$1"
    [[ -s "$yaml" ]] || return 0

    local pro_url="https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/pro.txt"
    local tif_url="https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/tif.mini.txt"
    local add_pro="yes" add_tif="yes"
    grep -Fq "$pro_url" "$yaml" && add_pro="no"
    grep -Fq "$tif_url" "$yaml" && add_tif="no"

    if [[ "$add_pro" == "no" && "$add_tif" == "no" ]]; then
        return 0
    fi

    # Refuse to guess at an unfamiliar schema.  This anchor has been stable
    # across AdGuard Home releases and keeps the new entries in `filters:`.
    if ! grep -q '^whitelist_filters:' "$yaml"; then
        log_warning "AdGuard filter lists were not changed: unfamiliar config schema"
        return 0
    fi

    local pro_id=900001 tif_id=900002
    while grep -Eq "^[[:space:]]+id: ${pro_id}$" "$yaml"; do
        pro_id=$((pro_id + 1))
    done
    [[ "$tif_id" -le "$pro_id" ]] && tif_id=$((pro_id + 1))
    while grep -Eq "^[[:space:]]+id: ${tif_id}$" "$yaml"; do
        tif_id=$((tif_id + 1))
    done

    local was_running="" tmp="${yaml}.corex.$$"
    if declare -f container_running >/dev/null 2>&1 && container_running adguard; then
        was_running="yes"
        docker stop adguard >/dev/null 2>&1 || {
            log_warning "AdGuard filter lists were not changed: could not stop AdGuard safely"
            return 0
        }
    fi

    # Keep one pre-change recovery copy, with the original permissions (the
    # YAML contains the administrator password hash).  `cp -p` also gives the
    # temporary file the right owner and mode before the atomic rename.
    [[ -e "${yaml}.corex-before-filters.bak" ]] \
        || cp -p "$yaml" "${yaml}.corex-before-filters.bak" 2>/dev/null \
        || true
    if ! cp -p "$yaml" "$tmp" 2>/dev/null; then
        [[ "$was_running" == "yes" ]] && docker start adguard >/dev/null 2>&1 || true
        log_warning "AdGuard filter lists were not changed: could not create a safe copy"
        return 0
    fi

    if ! awk \
        -v add_pro="$add_pro" -v pro_url="$pro_url" -v pro_id="$pro_id" \
        -v add_tif="$add_tif" -v tif_url="$tif_url" -v tif_id="$tif_id" '
        /^whitelist_filters:/ {
            if (add_pro == "yes") {
                print "  - enabled: true"
                print "    url: " pro_url
                print "    name: HaGeZi Multi PRO"
                print "    id: " pro_id
            }
            if (add_tif == "yes") {
                print "  - enabled: true"
                print "    url: " tif_url
                print "    name: HaGeZi Threat Intelligence Feeds Mini"
                print "    id: " tif_id
            }
        }
        { print }
    ' "$yaml" > "$tmp"; then
        rm -f "$tmp"
        [[ "$was_running" == "yes" ]] && docker start adguard >/dev/null 2>&1 || true
        log_warning "AdGuard filter lists were not changed: could not build the updated config"
        return 0
    fi

    if ! mv "$tmp" "$yaml"; then
        rm -f "$tmp"
        [[ "$was_running" == "yes" ]] && docker start adguard >/dev/null 2>&1 || true
        log_warning "AdGuard filter lists were not changed: could not replace the config"
        return 0
    fi

    log_success "AdGuard filter baseline enabled (HaGeZi Multi PRO + TIF Mini)"
}

# Point the host's own resolver at AdGuard, once AdGuard can answer.
#
# The public resolvers written during deploy are a bootstrap step: AdGuard is
# not running yet at that point, and a box with no working DNS cannot pull the
# image that would fix it. They were never meant to be the end state, and for a
# long time they were, which cost every install the LAN fast path from the box
# itself.
#
# What that looked like, measured on a live server. The host resolved its own
# hostnames to the Cloudflare edge, so a request to a service it is itself
# running went out to the internet and came back through the tunnel:
#
#   nextcloud.DOMAIN from the host   dns 5.03s   ttfb 6.60s
#   the same, pinned to the LAN IP   dns 0.00s   ttfb 0.04s
#   the container, direct                        ttfb 0.01s
#
# The 5.03s is a resolver timeout, paid on every request the box makes to
# itself. Uptime Kuma runs on the box, so its checks take that path too, and
# anything restricted to the LAN is answered 403 through the tunnel and can
# never pass its own monitor.
#
# Loopback rather than the LAN address, so it does not break when the LAN
# interface changes IP. No public fallback on purpose: glibc only falls through
# after a timeout, so a slow AdGuard would intermittently hand back the
# Cloudflare address and reintroduce the 6.6s path at random, which is far
# harder to diagnose than a clean failure. AdGuard is already the only resolver
# every other device in the house has.
_adguard_own_the_resolver() {
    # Only ever touch the host resolver when AdGuard is actually there to take
    # it over. Guarded with declare -f so a module sourced without common.sh
    # does nothing rather than dying on a missing command (gotcha #44), which
    # is also what keeps the readiness wait below out of the test suite: there
    # is no container to wait for, so there is nothing to wait.
    declare -f container_running >/dev/null 2>&1 || return 0
    container_running adguard || {
        log_warning "AdGuard is not running, so the host keeps its bootstrap DNS"
        return 0
    }

    # Wait for something to be listening on 53, then prove the end state
    # rather than the precondition. A resolv.conf pointing at a resolver that
    # does not answer is a box that cannot pull an image, including the image
    # that would repair AdGuard, so the switch is verified by a real lookup and
    # rolled back if that lookup fails.
    local up="" i
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        if ss -lnu 2>/dev/null | grep -q ':53 '; then up=yes; break; fi
        sleep 2
    done
    if [[ -z "$up" ]]; then
        log_warning "Nothing is listening on port 53 yet, so the host keeps public DNS"
        log_warning "  Re-run once AdGuard is up:  sudo corex manage repair adguard"
        return 0
    fi

    chattr -i /etc/resolv.conf 2>/dev/null || true
    cat > /etc/resolv.conf << 'RESOLVEOF'
# Managed by CoreX. Locked with chattr +i so systemd-resolved cannot take it.
#
# AdGuard is the resolver, on loopback rather than the LAN address so it does
# not depend on this machine keeping its IP. This is what lets the box reach
# its own services directly instead of resolving them to the public edge and
# going out and back through the tunnel.
#
# There is no public fallback on purpose. glibc only falls through after a
# timeout, so a slow AdGuard would intermittently return the public address and
# bring the slow path back at random, which is harder to diagnose than a clean
# failure.
#
# If AdGuard is down and you need DNS to repair it:
#   sudo chattr -i /etc/resolv.conf
#   echo "nameserver 1.1.1.1" | sudo tee /etc/resolv.conf
#   ... then once it is running again:
#   sudo corex manage repair adguard
nameserver 127.0.0.1
options timeout:2 attempts:2
RESOLVEOF
    chattr +i /etc/resolv.conf 2>/dev/null || true

    # Prove it before walking away. AdGuard can hold port 53 and still refuse
    # to resolve, during its first start or with no upstream configured, and
    # the cost of being wrong here is a box that cannot fetch anything.
    local resolved="" j
    for j in 1 2 3 4 5; do
        if getent hosts github.com >/dev/null 2>&1; then resolved=yes; break; fi
        sleep 2
    done
    if [[ -z "$resolved" ]]; then
        chattr -i /etc/resolv.conf 2>/dev/null || true
        printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /etc/resolv.conf 2>/dev/null || true
        chattr +i /etc/resolv.conf 2>/dev/null || true
        log_warning "AdGuard holds port 53 but did not resolve, so public DNS is back"
        log_warning "  Finish the AdGuard setup wizard, then: sudo corex manage repair adguard"
        return 0
    fi
    log_success "Host DNS now goes through AdGuard, so the box reaches its own services on the LAN"
}

adguard_deploy() {
    mkdir -p "${DOCKER_ROOT}/adguard"
    mkdir -p "${DATA_ROOT}/adguard-work" "${DATA_ROOT}/adguard-conf"
    local dir="${DOCKER_ROOT}/adguard"

    # Disable systemd-resolved which holds port 53
    systemctl disable --now systemd-resolved 2>/dev/null || true
    # The lock has to come off before the file can be replaced. A previous run
    # of this function set it (gotcha #7), so on every run after the first the
    # rm failed with EPERM and the file was left exactly as it was. Nothing
    # said so, because the failure was the last command in a function nobody
    # checked the status of.
    chattr -i /etc/resolv.conf 2>/dev/null || true
    rm -f /etc/resolv.conf 2>/dev/null || true
    printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /etc/resolv.conf 2>/dev/null \
        || log_warning "Could not rewrite /etc/resolv.conf"
    # Lock again so systemd-resolved cannot overwrite it on reboot.
    chattr +i /etc/resolv.conf 2>/dev/null || true

    # AdGuard moves its own admin port from 3000 to 80 once the setup wizard
    # has run, so the port has to be read from its config and never assumed.
    #
    # Reading it is fussier than it looks. `grep -A5 "http:"` used to be
    # enough and is not any more: current AdGuard writes pprof and a doh
    # routes list inside the http block first, so `address:` is eleven lines
    # down and the window missed it. The fallback was 3000, which produced a
    # `3000:3000` mapping against a container listening on 80, and the admin
    # panel simply stopped answering on the LAN. `corex manage lan-setup` was
    # fixed for this in v2.1.1; this copy was not.
    #
    # The address line is matched at its own indentation, two spaces, so it is
    # a direct child of http: and cannot be confused with bind_hosts or a
    # bootstrap entry elsewhere in the file.
    local ADGUARD_INTERNAL_PORT="3000"
    local yaml="${DATA_ROOT}/adguard-conf/AdGuardHome.yaml"
    if [[ -f "$yaml" ]]; then
        local CONFIGURED_PORT
        CONFIGURED_PORT=$(sed -n '/^http:/,/^[a-z_]/p' "$yaml" \
            | grep -m1 '^  address:' | grep -oE '[0-9]+$')
        if [[ -n "$CONFIGURED_PORT" ]]; then
            ADGUARD_INTERNAL_PORT="$CONFIGURED_PORT"
            log_info "AdGuard already configured, internal port is $ADGUARD_INTERNAL_PORT"
        else
            log_warning "Could not read the admin port from ${yaml}, assuming 3000"
        fi
        _adguard_seed_filter_lists "$yaml"
    else
        log_info "AdGuard first run, the wizard will listen on port 3000"
    fi

    # AdGuard gets a Traefik router so the shared login can be put in front
    # of it. It did not have one before: the admin panel was reached on
    # SERVER_IP:3000 and nothing else, which is fine on the LAN and means the
    # panel has only its own password when it is reached over the tunnel.
    #
    # Port 3000 stays published, and that is the point rather than an
    # oversight. AdGuard is the DNS, so auth.DOMAIN does not resolve on the
    # LAN while AdGuard is down: a login that needs DNS must never be the only
    # way to fix DNS.
    local sso_label=""
    declare -f sso_label_for >/dev/null 2>&1 && sso_label="$(sso_label_for adguard)"

    # No domain means no router. AdGuard is the one module that installs in
    # local-only mode, and a Host rule built from an empty domain is
    # `Host(`adguard.`)`, which Traefik rejects.
    local adguard_labels=""
    if [[ -n "${DOMAIN:-}" ]]; then
        adguard_labels="$(cat << ALEOF
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.adguard.rule=Host(\`adguard.${DOMAIN}\`)"
      - "traefik.http.routers.adguard.entrypoints=websecure"
      - "traefik.http.routers.adguard.tls.certresolver=myresolver"
      # The port inside the container, which AdGuard moves from 3000 to 80
      # once its setup wizard has run, so it is read from AdGuardHome.yaml
      # rather than hardcoded. No apostrophe in this comment on purpose: it is
      # a heredoc body inside a command substitution, and bash scans that for
      # quotes, so one apostrophe here is an unterminated string.
      # See CLAUDE.md "Heredoc markers convention".
      - "traefik.http.services.adguard.loadbalancer.server.port=${ADGUARD_INTERNAL_PORT}"
${sso_label}
ALEOF
)"
    fi

    cat > "${dir}/docker-compose.yml" << DCEOF
services:
  adguard:
    image: adguard/adguardhome:latest
    container_name: adguard
    restart: unless-stopped
    ports:
      - "53:53/tcp"
      - "53:53/udp"
      - "3000:${ADGUARD_INTERNAL_PORT}/tcp"
    volumes:
      - ${DATA_ROOT}/adguard-work:/opt/adguardhome/work
      - ${DATA_ROOT}/adguard-conf:/opt/adguardhome/conf
    networks: [proxy-net]
    deploy:
      resources:
        limits:
          # Compiling the two CoreX filter subscriptions can briefly need more
          # than the steady-state footprint.  The old 256 MB cap made that an
          # avoidable DNS outage during list updates.
          memory: 512m
          cpus: "0.5"
        reservations:
          memory: 64m
${adguard_labels}
networks:
  proxy-net: { external: true }
DCEOF

    docker compose -f "${dir}/docker-compose.yml" up -d \
        || log_warning "AdGuard may not have started — check: docker ps"

    # The public resolvers written above were only ever meant to last until
    # AdGuard was answering. Hand the box back to it now.
    _adguard_own_the_resolver

    state_service_installed "adguard"
    log_success "AdGuard Home deployed (DNS:53, Admin:3000)"
}

adguard_destroy() {
    local dir="${DOCKER_ROOT}/adguard"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" down
    state_service_removed "adguard"
}

adguard_status() {
    if container_running "adguard"; then echo "HEALTHY"
    elif container_exists "adguard"; then echo "UNHEALTHY"
    else echo "MISSING"; fi
}

adguard_repair() {
    # Regenerate the compose file first. Without this, repair recreated the
    # container from a compose file that could be months old, so CoreX fixes
    # to env vars, resource limits, security_opt, published ports or Traefik
    # labels never reached an existing install. adguard_deploy is idempotent
    # by design (see CLAUDE.md "Idempotency pattern"), so calling it here is
    # safe and is what makes `corex doctor` able to deliver fixes at all.
    adguard_deploy
    local dir="${DOCKER_ROOT}/adguard"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" up -d --force-recreate
}

adguard_credentials() {
    echo "AdGuard Home: http://${SERVER_IP}:3000 (set during wizard)"
}
