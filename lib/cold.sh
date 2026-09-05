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
            if cold_enabled grafana; then
                echo "Grafana: wake on HTTPS access; stop after 15 minutes idle."
            else
                echo "Grafana: always running. Enable: corex manage cold enable grafana"
            fi
            echo "AI: models unload after 2 minutes idle; one loaded model and one inference at a time."
            echo "Calendar sync, Nextcloud, mail, workflows, backups and infrastructure remain running."
            return 0 ;;
        enable|disable) ;;
        *) echo "Usage: corex manage cold <status|enable|disable> [portainer|grafana]" >&2; return 2 ;;
    esac
    local compose deploy_fn label url
    case "$service" in
        portainer)
            compose="${DOCKER_ROOT}/portainer/docker-compose.yml"
            deploy_fn=portainer_deploy
            label=Portainer
            url="https://portainer.${DOMAIN:-}"
            source "${SCRIPT_DIR}/lib/services/portainer.sh"
            ;;
        grafana)
            compose="${DOCKER_ROOT}/monitoring/docker-compose.yml"
            deploy_fn=monitoring_deploy
            label=Grafana
            url="https://grafana.${DOMAIN:-}"
            source "${SCRIPT_DIR}/lib/services/monitoring.sh"
            if declare -f state_component_is_enabled >/dev/null 2>&1; then
                state_component_is_enabled monitoring grafana || {
                    echo "Enable monitoring:grafana before enabling its cold mode." >&2; return 1;
                }
            fi
            ;;
        *)
            echo "Only Portainer and Grafana support container sleep. Other services do background work." >&2
            return 2
            ;;
    esac
    [[ -f "$compose" ]] || {
        echo "Install ${label} and finish its setup first." >&2; return 1;
    }
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
        state_set "cold_${service}" true || return 1
        source "${SCRIPT_DIR}/lib/services/traefik.sh"
        traefik_repair || { state_set "cold_${service}" false; return 1; }
        "$deploy_fn" || { state_set "cold_${service}" false; return 1; }
        echo "${label} wakes at ${url} and sleeps after 15 minutes idle."
    else
        # Recreate a running backend without the middleware before removing
        # the intent. Leave Sablier installed so disabling is reversible.
        state_set "cold_${service}" false || return 1
        "$deploy_fn" || return 1
        echo "${label} is always running again."
    fi
}
