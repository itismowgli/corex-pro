#!/bin/bash
# Small allowlist: a web page being idle does not mean its service is idle.
cold_enabled() {
    declare -f state_get >/dev/null && [[ "$(state_get "cold_$1" 2>/dev/null)" == true ]]
}

cold_manage() {
    local action="${1:-status}" service="${2:-portainer}"
    case "$action" in
        status)
            if cold_enabled portainer; then
                echo "Portainer: wake on HTTPS access; stop after 15 minutes idle."
            else
                echo "Portainer: always running. Enable: corex manage cold enable portainer"
            fi
            echo "AI: models unload after 2 minutes idle; one loaded model and one inference at a time."
            echo "Calendar sync, Nextcloud, mail, workflows, backups and infrastructure remain running."
            return 0 ;;
        enable|disable) ;;
        *) echo "Usage: corex manage cold <status|enable|disable> [portainer]" >&2; return 2 ;;
    esac
    [[ "$service" == portainer ]] || {
        echo "Only Portainer supports container sleep. Other services may do scheduled or background work." >&2; return 2;
    }
    [[ -f "${DOCKER_ROOT}/portainer/docker-compose.yml" ]] || {
        echo "Install Portainer and finish its admin setup first." >&2; return 1;
    }
    source "${SCRIPT_DIR}/lib/services/portainer.sh"
    if [[ "$action" == enable ]]; then
        [[ -n "${DOMAIN:-}" ]] || { echo "Wake-on-access requires a configured HTTPS domain." >&2; return 1; }
        # Confirm a running Traefik with the stopped-container routing support.
        local version
        version=$(docker exec traefik traefik version 2>/dev/null | awk '/^Version:/ {print $2}')
        [[ "$version" =~ ^3\.([0-9]+)\. ]] && (( ${BASH_REMATCH[1]} >= 6 )) || {
            echo "Cold mode needs running Traefik 3.6 or newer in the 3.x line." >&2; return 1;
        }
        source "${SCRIPT_DIR}/lib/services/sablier.sh"
        sablier_deploy || return 1
        state_set cold_portainer true || return 1
        source "${SCRIPT_DIR}/lib/services/traefik.sh"
        traefik_repair || { state_set cold_portainer false; return 1; }
        portainer_deploy || { state_set cold_portainer false; return 1; }
        echo "Portainer wakes at https://portainer.${DOMAIN}; direct port 9443 does not wake it."
    else
        # Recreate a running backend without the middleware before removing
        # the intent. Leave Sablier installed so disabling is reversible.
        state_set cold_portainer false || return 1
        portainer_deploy || return 1
        echo "Portainer is always running again."
    fi
}
