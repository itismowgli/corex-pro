#!/bin/bash
# One shared data filesystem for new installs; reuse labelled legacy layouts.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

_drive_partition_path() {
    case "$1" in
        *[0-9]) printf '%sp%s\n' "$1" "$2" ;;
        *) printf '%s%s\n' "$1" "$2" ;;
    esac
}

_drive_validate_target() {
    local target="$1" root_source parent mount ancestors mounts
    [[ -b "$target" ]] || { echo "Not a block device: $target" >&2; return 1; }
    [[ "$(lsblk -dn -o TYPE "$target")" == "disk" ]] || {
        echo "Select a whole data disk, not a partition or logical volume." >&2; return 1;
    }
    root_source=$(findmnt -nro SOURCE /) || return 1
    root_source="${root_source%%\[*}"
    # Includes the physical ancestors of an LVM/encrypted root filesystem.
    ancestors=$(lsblk -snpo NAME "$root_source") || return 1
    [[ -n "$ancestors" ]] || return 1
    while read -r parent; do
        [[ "$parent" == "$target" ]] && { echo "Refusing the operating-system disk." >&2; return 1; }
    done <<< "$ancestors"
    mounts=$(lsblk -nr -o MOUNTPOINTS "$target") || return 1
    while read -r mount; do
        case "$mount" in
            ''|"${MOUNT_POOL:-/mnt/corex-data}"|"${MOUNT_TM:-/mnt/timemachine}") ;;
            *) echo "Disk contains an unrelated mount ($mount); refusing." >&2; return 1 ;;
        esac
    done <<< "$mounts"
}

phase1_drive() {
    log_step "═══ PHASE 1: Data Drive Setup ═══"
    MOUNT_POOL="${MOUNT_POOL:-/mnt/corex-data}"
    MOUNT_TM="${MOUNT_TM:-/mnt/timemachine}"
    local command target name reuse confirm data_dev="" tm_dev="" dev label
    for command in lsblk findmnt blkid parted partprobe wipefs mkfs.ext4 udevadm tac; do
        command -v "$command" >/dev/null || {
            log_warning "Missing $command. Install parted, e2fsprogs and util-linux, then retry."; return 1;
        }
    done
    lsblk -d -o NAME,SIZE,MODEL,TRAN
    read -r -p "Data disk device (e.g. sda or nvme1n1): " name || return 1
    name="${name#/dev/}"
    [[ "$name" =~ ^[a-zA-Z0-9]+$ ]] || { log_warning "Invalid device name."; return 1; }
    target="/dev/$name"
    _drive_validate_target "$target" || return 1
    read -r -p "Reuse existing CoreX partitions without formatting? (Y/n): " reuse || return 1

    if [[ "$reuse" != "n" && "$reuse" != "N" ]]; then
        # Labels, not partition numbers: accepts both the old two-partition
        # layout and the new shared pool. Never relabel an unknown filesystem.
        while read -r dev; do
            label=$(blkid -s LABEL -o value "$dev" 2>/dev/null || true)
            case "$label" in
                COREX_DATA) [[ -z "$data_dev" ]] || return 1; data_dev="$dev" ;;
                TIMEMACHINE) [[ -z "$tm_dev" ]] || return 1; tm_dev="$dev" ;;
            esac
        done < <(lsblk -lnpo NAME "$target")
        [[ -n "$data_dev" ]] || { log_warning "No COREX_DATA filesystem on $target. Nothing changed."; return 1; }
    else
        local reserve="${COREX_SSD_RESERVE_PERCENT:-2}"
        [[ "$reserve" =~ ^[0-9]{1,2}$ ]] && (( 10#$reserve <= 20 )) || {
            log_warning "COREX_SSD_RESERVE_PERCENT must be from 0 to 20."; return 1;
        }
        log_warning "Formatting $target erases ALL its data. One shared pool will use $((100-10#$reserve))%; ${reserve}% remains unallocated."
        read -r -p "Type DESTROY-$name to confirm: " confirm || return 1
        [[ "$confirm" == "DESTROY-$name" ]] || { log_warning "Cancelled. Nothing changed."; return 1; }
        # Do not stop services, unmount or edit fstab until after confirmation.
        systemctl stop docker.service docker.socket 2>/dev/null || true
        while read -r dev; do
            if findmnt -rn -S "$dev" >/dev/null; then
                umount "$dev" || { log_warning "Cannot unmount $dev; formatting stopped."; return 1; }
            fi
        done < <(lsblk -lnpo NAME "$target" | tac)
        wipefs -a "$target" || return 1
        parted -s "$target" mklabel gpt || return 1
        parted -s -a optimal "$target" mkpart primary ext4 1MiB "$((100-10#$reserve))%" || return 1
        partprobe "$target" || return 1
        udevadm settle || return 1
        data_dev=$(_drive_partition_path "$target" 1)
        mkfs.ext4 -m 1 -L COREX_DATA "$data_dev" || return 1
    fi

    mkdir -p "$MOUNT_POOL" "$MOUNT_TM"
    # Refuse duplicate labels rather than booting from an arbitrary disk.
    local count
    for label in COREX_DATA ${tm_dev:+TIMEMACHINE}; do
        count=$(blkid -t "LABEL=$label" -o device | wc -l)
        [[ "$count" -eq 1 ]] || { log_warning "Duplicate or missing $label label; resolve before mounting."; return 1; }
    done
    if mountpoint -q "$MOUNT_POOL"; then
        [[ "$(findmnt -nro MAJ:MIN --mountpoint "$MOUNT_POOL")" == "$(lsblk -dnro MAJ:MIN "$data_dev")" ]] || return 1
    else
        mount "$data_dev" "$MOUNT_POOL" || return 1
    fi
    if [[ -n "$tm_dev" ]]; then
        if mountpoint -q "$MOUNT_TM"; then
            [[ "$(findmnt -nro MAJ:MIN --mountpoint "$MOUNT_TM")" == "$(lsblk -dnro MAJ:MIN "$tm_dev")" ]] || return 1
        else
            mount "$tm_dev" "$MOUNT_TM" || return 1
        fi
    fi

    # Keep a recovery copy and replace only exact CoreX mountpoint entries.
    cp -p /etc/fstab "/etc/fstab.corex.$(date +%s).bak" || return 1
    local tmp
    tmp=$(mktemp /etc/fstab.corex.XXXXXX) || return 1
    awk -v pool="$MOUNT_POOL" -v tm="$MOUNT_TM" '$2 != pool && $2 != tm' /etc/fstab > "$tmp"
    printf 'LABEL=COREX_DATA %s ext4 defaults,noatime,nofail 0 2\n' "$MOUNT_POOL" >> "$tmp"
    [[ -z "$tm_dev" ]] || printf 'LABEL=TIMEMACHINE %s ext4 defaults,noatime,nofail 0 2\n' "$MOUNT_TM" >> "$tmp"
    chmod 644 "$tmp"
    mv "$tmp" /etc/fstab || return 1
    systemctl daemon-reload || return 1
    source "$(dirname "${BASH_SOURCE[0]}")/disks.sh"
    disks_guard_docker || return 1
    if command -v docker >/dev/null; then
        systemctl start docker || return 1
    fi
    df -h "$MOUNT_POOL"
    log_success "Shared data pool mounted. Time Machine, if selected, uses a directory in this pool."
}
