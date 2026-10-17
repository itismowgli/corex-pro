#!/bin/bash
# Thermal budget and crash bookkeeping for Docker service updates.
#
# Pulling and extracting several images can heat this class of mini PC faster
# than the ten-second thermal guardian can shed unrelated load. Updates use a
# lower, proactive budget: refuse to begin at the warning threshold and pause
# the command tree as soon as it reaches that threshold, resuming only after
# there is real headroom again.

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

COREX_UPDATE_STATE_DIR="${COREX_UPDATE_STATE_DIR:-/var/lib/corex/update-in-progress}"
COREX_UPDATE_THERMAL_CONF="${COREX_UPDATE_THERMAL_CONF:-/etc/corex/thermal.conf}"
COREX_UPDATE_POLL_SEC="${COREX_UPDATE_POLL_SEC:-2}"
COREX_CPU_SYSFS_ROOT="${COREX_CPU_SYSFS_ROOT:-/sys/devices/system/cpu}"
COREX_UPDATE_CEILING_STATE="${COREX_UPDATE_CEILING_STATE:-/run/corex/update-cpu-ceiling.$$}"
COREX_UPDATE_LOCK="${COREX_UPDATE_LOCK:-/run/corex/update.lock}"

_update_load_limits() {
    local THERMAL_WARN_C=80 THERMAL_RECOVER_C=72 THERMAL_CLOCK_MIN_MHZ=1600
    if [[ -r "$COREX_UPDATE_THERMAL_CONF" ]]; then
        # shellcheck disable=SC1090
        source "$COREX_UPDATE_THERMAL_CONF"
    fi
    [[ "$THERMAL_WARN_C" =~ ^[0-9]+$ ]] || THERMAL_WARN_C=80
    [[ "$THERMAL_RECOVER_C" =~ ^[0-9]+$ ]] || THERMAL_RECOVER_C=72
    [[ "$THERMAL_CLOCK_MIN_MHZ" =~ ^[0-9]+$ ]] || THERMAL_CLOCK_MIN_MHZ=1600
    # Act before the general warning band. The incident crossed 77.5C and
    # reached 84C only 36 seconds later, so waiting for 80C spends the margin
    # this workload needs.
    UPDATE_MAX_TEMP_C="${COREX_UPDATE_MAX_TEMP_C:-$(( THERMAL_WARN_C - 2 ))}"
    [[ "$UPDATE_MAX_TEMP_C" =~ ^[0-9]+$ ]] \
        || UPDATE_MAX_TEMP_C=$(( THERMAL_WARN_C - 2 ))
    local default_resume="$THERMAL_RECOVER_C"
    (( default_resume > UPDATE_MAX_TEMP_C - 8 )) \
        && default_resume=$(( UPDATE_MAX_TEMP_C - 8 ))
    UPDATE_RESUME_TEMP_C="${COREX_UPDATE_RESUME_TEMP_C:-$default_resume}"
    UPDATE_CPU_MAX_MHZ="${COREX_UPDATE_CPU_MAX_MHZ:-$THERMAL_CLOCK_MIN_MHZ}"
    [[ "$UPDATE_RESUME_TEMP_C" =~ ^[0-9]+$ ]] || UPDATE_RESUME_TEMP_C="$default_resume"
    [[ "$UPDATE_CPU_MAX_MHZ" =~ ^[0-9]+$ ]] || UPDATE_CPU_MAX_MHZ=1600
    # A bad local override must not remove hysteresis and make a heavy pull
    # flap between running and stopped every sample.
    if (( UPDATE_RESUME_TEMP_C >= UPDATE_MAX_TEMP_C )); then
        UPDATE_RESUME_TEMP_C=$(( UPDATE_MAX_TEMP_C - 8 ))
    fi
}

# Docker layer extraction happens in dockerd/containerd, outside the Compose
# client's process tree. A client SIGSTOP prevents it submitting the next
# operation but cannot stop daemon work already accepted. Cap every CPU policy
# for the complete update window so that daemon-side work is bounded too.
# Each original value is recorded and restored exactly, rather than restoring
# a guessed machine default or an operator's configured power ceiling.
update_cpu_ceiling_begin() {
    _update_load_limits
    local cap_khz=$(( UPDATE_CPU_MAX_MHZ * 1000 )) path canonical current changed=0 seen="|"
    mkdir -p "$(dirname "$COREX_UPDATE_CEILING_STATE")" 2>/dev/null || true
    : > "$COREX_UPDATE_CEILING_STATE" || {
        log_warning "Update CPU ceiling state cannot be recorded; continuing with thermal pause only"
        return 0
    }
    for path in "$COREX_CPU_SYSFS_ROOT"/cpu*/cpufreq/scaling_max_freq; do
        [[ -r "$path" && -w "$path" ]] || continue
        # cpu*/cpufreq commonly links several CPUs to one policy. Recording
        # the second alias after writing the first records the capped value as
        # its "original", so a later restore can end at the cap permanently.
        # Resolve and touch each policy exactly once.
        canonical=$(readlink -f "$path" 2>/dev/null \
            || realpath "$path" 2>/dev/null \
            || echo "$path")
        [[ "$seen" == *"|${canonical}|"* ]] && continue
        seen+="${canonical}|"
        current=$(cat "$canonical" 2>/dev/null || echo "")
        [[ "$current" =~ ^[0-9]+$ ]] || continue
        printf '%s\t%s\n' "$canonical" "$current" >> "$COREX_UPDATE_CEILING_STATE"
        if (( current > cap_khz )); then
            if printf '%s\n' "$cap_khz" > "$canonical" 2>/dev/null; then
                changed=$((changed + 1))
            fi
        fi
    done
    if (( changed > 0 )); then
        log_info "Update CPU ceiling set to ${UPDATE_CPU_MAX_MHZ} MHz on ${changed} policy file(s)"
    else
        log_warning "CPU frequency controls unavailable; continuing with serialized pulls and thermal pause"
    fi
    return 0
}

update_cpu_ceiling_restore() {
    [[ -f "$COREX_UPDATE_CEILING_STATE" ]] || return 0
    local path original restored=0 canonical_root
    canonical_root=$(readlink -f "$COREX_CPU_SYSFS_ROOT" 2>/dev/null \
        || realpath "$COREX_CPU_SYSFS_ROOT" 2>/dev/null \
        || echo "$COREX_CPU_SYSFS_ROOT")
    while IFS=$'\t' read -r path original; do
        # Canonical Linux paths are usually cpu/cpufreq/policyN, while some
        # drivers expose a real cpuN/cpufreq directory. Both must remain
        # inside the selected sysfs root and end in the one file we change.
        case "$path" in
            "$canonical_root"/*/scaling_max_freq) ;;
            *) continue ;;
        esac
        [[ -w "$path" && "$original" =~ ^[0-9]+$ ]] || continue
        if printf '%s\n' "$original" > "$path" 2>/dev/null; then
            restored=$((restored + 1))
        fi
    done < "$COREX_UPDATE_CEILING_STATE"
    rm -f "$COREX_UPDATE_CEILING_STATE"
    (( restored > 0 )) && log_info "Restored the pre-update CPU ceiling on ${restored} policy file(s)"
    return 0
}

_update_lock_acquire() {
    mkdir -p "$(dirname "$COREX_UPDATE_LOCK")" 2>/dev/null || true
    command -v flock >/dev/null 2>&1 || {
        log_warning "flock is unavailable; refusing an update without serialization"
        return 1
    }
    if [[ "${COREX_UPDATE_LOCK_HELD:-false}" != "true" ]]; then
        exec 8> "$COREX_UPDATE_LOCK" || {
            log_warning "cannot open the global update lock"
            return 1
        }
    fi
    if ! flock -n 8; then
        log_warning "another CLI or dashboard update is already running"
        [[ "${COREX_UPDATE_LOCK_HELD:-false}" == "true" ]] || exec 8>&-
        return 1
    fi
    COREX_UPDATE_LOCK_HELD=true
    export COREX_UPDATE_LOCK_HELD
}

_update_lock_release() {
    [[ "${COREX_UPDATE_LOCK_HELD:-false}" == "true" ]] || return 0
    flock -u 8 2>/dev/null || true
    exec 8>&-
    COREX_UPDATE_LOCK_HELD=false
    export COREX_UPDATE_LOCK_HELD
}

# update-everything replaces itself with the freshly downloaded manager. Hold
# the same lock across that exec without applying a CPU ceiling to the light
# git fetch. The new `update --all` process inherits fd 8 and the exported flag,
# then applies the ceiling for the Docker work and releases both at the end.
update_locked_exec_run() {
    local label="$1"; shift
    update_thermal_preflight "$label" || return 1
    _update_lock_acquire || return 1
    trap '_update_lock_release' EXIT
    trap '_update_lock_release; exit 130' INT TERM HUP
    "$@"
    local rc=$?
    _update_lock_release
    trap - EXIT INT TERM HUP
    return "$rc"
}

update_session_run() {
    local label="$1"; shift
    update_thermal_preflight "$label" || return 1
    _update_lock_acquire || {
        log_warning "${label}: update lock unavailable"
        return 1
    }
    update_cpu_ceiling_begin

    trap 'update_cpu_ceiling_restore' EXIT
    trap 'update_cpu_ceiling_restore; exit 130' INT TERM HUP
    "$@"
    local rc=$?
    update_cpu_ceiling_restore
    _update_lock_release
    trap - EXIT INT TERM HUP
    return "$rc"
}

update_cpu_temp() {
    local t="" zone hottest=0 raw
    if command -v sensors >/dev/null 2>&1; then
        t=$(sensors 2>/dev/null \
            | sed -n -E 's/^(Tctl|Tdie|Package id 0):[[:space:]]*\+?([0-9.]+).*/\2/p' \
            | head -1)
        [[ -n "$t" ]] && { echo "${t%.*}"; return 0; }
    fi
    for zone in /sys/class/thermal/thermal_zone*/temp; do
        [[ -r "$zone" ]] || continue
        raw=$(cat "$zone" 2>/dev/null || echo 0)
        [[ "$raw" =~ ^[0-9]+$ ]] || continue
        t=$(( raw / 1000 ))
        (( t > hottest )) && hottest=$t
    done
    (( hottest > 0 )) && { echo "$hottest"; return 0; }
    return 1
}

update_thermal_preflight() {
    local label="${1:-update}" t
    _update_load_limits
    if ! t=$(update_cpu_temp) || [[ ! "$t" =~ ^[0-9]+$ ]] || (( t <= 0 )); then
        log_warning "${label}: CPU temperature is unavailable; refusing heavy Docker work"
        log_warning "Install/configure lm-sensors, then retry."
        return 1
    fi
    if (( t >= UPDATE_MAX_TEMP_C )); then
        log_warning "${label}: CPU is ${t}C, at or above the ${UPDATE_MAX_TEMP_C}C update limit"
        log_warning "Let the host cool to ${UPDATE_RESUME_TEMP_C}C before retrying."
        return 1
    fi
    log_info "${label}: thermal preflight passed at ${t}C (limit ${UPDATE_MAX_TEMP_C}C)"
    return 0
}

# Walk the child tree rather than signalling a process group. A shell function
# started in the background is not reliably its own process-group leader.
_update_signal_tree() {
    local root="$1" sig="$2" child
    if [[ "$sig" == "STOP" ]]; then
        kill -STOP "$root" 2>/dev/null || true
        for child in $(pgrep -P "$root" 2>/dev/null); do
            _update_signal_tree "$child" STOP
        done
    else
        for child in $(pgrep -P "$root" 2>/dev/null); do
            _update_signal_tree "$child" CONT
        done
        kill -CONT "$root" 2>/dev/null || true
    fi
}

update_run_governed() {
    local label="$1"; shift
    update_thermal_preflight "$label" || return 1

    "$@" &
    local pid=$! paused=false pauses=0 t rc
    while kill -0 "$pid" 2>/dev/null; do
        sleep "$COREX_UPDATE_POLL_SEC"
        kill -0 "$pid" 2>/dev/null || break
        t=$(update_cpu_temp 2>/dev/null || true)
        [[ "$t" =~ ^[0-9]+$ ]] || continue
        if [[ "$paused" == "false" ]] && (( t >= UPDATE_MAX_TEMP_C )); then
            _update_signal_tree "$pid" STOP
            paused=true
            pauses=$((pauses + 1))
            log_warning "${label}: paused at ${t}C; waiting for ${UPDATE_RESUME_TEMP_C}C"
        elif [[ "$paused" == "true" ]] && (( t <= UPDATE_RESUME_TEMP_C )); then
            _update_signal_tree "$pid" CONT
            paused=false
            log_info "${label}: resumed at ${t}C"
        fi
    done

    # Never leave a stopped child behind if the command exits or this function
    # is reused by a caller with unusual process behaviour.
    [[ "$paused" == "true" ]] && _update_signal_tree "$pid" CONT
    wait "$pid"
    rc=$?
    (( pauses > 0 )) && log_info "${label}: paused ${pauses} time(s) to stay inside the thermal budget"
    return "$rc"
}

update_mark_begin() {
    local svc="$1" tmp
    [[ "$svc" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || return 1
    mkdir -p "$COREX_UPDATE_STATE_DIR" || return 1
    tmp=$(mktemp "${COREX_UPDATE_STATE_DIR}/.${svc}.XXXXXX") || return 1
    printf '%s\t%s\n' "$svc" "$(date --iso-8601=seconds 2>/dev/null || date)" > "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "${COREX_UPDATE_STATE_DIR}/${svc}" || { rm -f "$tmp"; return 1; }
    sync -d "$COREX_UPDATE_STATE_DIR" 2>/dev/null || true
}

update_mark_done() {
    local svc="$1"
    [[ "$svc" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || return 1
    rm -f "${COREX_UPDATE_STATE_DIR}/${svc}"
    sync -d "$COREX_UPDATE_STATE_DIR" 2>/dev/null || true
}
