#!/bin/bash
# lib/disks.sh — make a disk swap or a disk addition survivable.
#
# Two problems, and the second is the dangerous one.
#
# The installer already labels its partitions TIMEMACHINE and COREX_DATA, but
# it writes fstab entries keyed on UUID. A UUID belongs to one filesystem, so
# replacing the SSD, or restoring its contents onto a new one, produces a
# device that will not mount no matter how correct its contents are. Mounting
# by label instead makes the disk's role a property of the disk.
#
# And nothing stopped Docker when that mount was missing. `nofail` lets the box
# boot without the data disk, which is right for a headless machine, but Docker
# then started anyway and every bind mount created an empty directory on the
# root filesystem. Nextcloud sees an empty data directory, Immich an empty
# library, and the databases see empty data directories and initialise fresh.
# The services come up looking new rather than looking broken, which is the
# worst way for this to fail. RequiresMountsFor turns that into Docker
# declining to start, with a reason.

DISK_DATA_LABEL="COREX_DATA"
DISK_TM_LABEL="TIMEMACHINE"
DISK_DATA_MOUNT="${MOUNT_POOL:-/mnt/corex-data}"
DISK_TM_MOUNT="${MOUNT_TM:-/mnt/timemachine}"

# The systemd unit name for a path, which is what RequiresMountsFor resolves
# to and what `systemctl status` wants to be asked about.
_disk_mount_unit() {
    systemd-escape -p --suffix=mount "$1" 2>/dev/null
}

# Rewrite the CoreX fstab lines to mount by label.
#
# Only ours: the root, boot and EFI entries are the installer's own and are
# left exactly as they are. Idempotent, and it refuses to act unless the label
# actually exists on a filesystem right now, because writing a LABEL= line for
# a label nothing carries is how you make a box that will not boot cleanly.
disks_fstab_use_labels() {
    local changed=0 mount label line
    for pair in "${DISK_DATA_MOUNT}:${DISK_DATA_LABEL}" "${DISK_TM_MOUNT}:${DISK_TM_LABEL}"; do
        mount="${pair%%:*}"; label="${pair##*:}"

        grep -qE "^[^#]*[[:space:]]${mount}[[:space:]]" /etc/fstab 2>/dev/null || continue
        if grep -qE "^LABEL=${label}[[:space:]]+${mount}[[:space:]]" /etc/fstab 2>/dev/null; then
            continue    # already done
        fi
        if ! blkid -L "$label" >/dev/null 2>&1; then
            log_warning "No filesystem is labelled ${label}; leaving its fstab entry on UUID."
            continue
        fi

        # Keep nofail. Without it a missing disk drops a headless box into
        # emergency mode with no SSH, which is a worse failure than the one
        # this is protecting against.
        line="LABEL=${label} ${mount} ext4 defaults,noatime,nofail 0 2"
        sed -i "\|[[:space:]]${mount}[[:space:]]|d" /etc/fstab
        echo "$line" >> /etc/fstab
        log_success "fstab: ${mount} now mounts by label ${label}."
        changed=1
    done
    [[ "$changed" == "1" ]] && systemctl daemon-reload 2>/dev/null || true
    return 0
}

# Docker must not start without the data disk.
disks_guard_docker() {
    local dir="/etc/systemd/system/docker.service.d"
    mkdir -p "$dir"
    local unit
    unit=$(_disk_mount_unit "$DISK_DATA_MOUNT")

    cat > "${dir}/99-corex-datadisk.conf" << EOF
[Unit]
# Every service bind-mounts out of ${DISK_DATA_MOUNT}. Started without it,
# Docker creates those paths as empty directories on the root filesystem and
# the databases initialise fresh, so the box comes up looking new instead of
# looking broken. Refusing to start is the recoverable failure.
RequiresMountsFor=${DISK_DATA_MOUNT}
EOF
    systemctl daemon-reload 2>/dev/null || true
    log_success "Docker now requires ${DISK_DATA_MOUNT} (${unit:-mount unit}) before it starts."
}

# Everything attached, what it is, and whether CoreX has a use for it.
disks_list() {
    echo ""
    echo -e "${CYAN}${BOLD}Disks${NC}"
    echo "──────────────────────────────────────────────────────────────"
    printf "  %-12s %-9s %-8s %-13s %-22s %s\n" DEVICE SIZE TYPE LABEL MOUNT ROLE
    local dev size tran fstype label mount role
    # The separator has to be a character IFS does not treat as whitespace.
    # With IFS=$'\t', bash collapses runs of tabs into one delimiter, so an
    # empty column (TRAN on a partition, LABEL on an unformatted disk) shifted
    # every later value one place left and the listing quietly reported the
    # mountpoint as the label. lsblk -r escapes real spaces as \x20, so
    # substituting the field separator is safe.
    while IFS='|' read -r dev size tran fstype label mount; do
        [[ -z "$dev" ]] && continue
        role="-"
        case "$label" in
            "$DISK_DATA_LABEL") role="CoreX data" ;;
            "$DISK_TM_LABEL")   role="Time Machine" ;;
        esac
        case "$mount" in
            /|/boot|/boot/efi) role="system" ;;
        esac
        [[ "$fstype" == "LVM2_member" ]] && role="system (LVM)"
        [[ "$fstype" == "swap" ]] && role="swap"
        # A whole disk carrying partitions is a container, not a spare.
        if [[ "$role" == "-" && -z "$fstype" && -z "$mount" ]]; then
            if lsblk -rno NAME "/dev/${dev}" 2>/dev/null | tail -n +2 | grep -q .; then
                role="partitioned"
            else
                role="SPARE, adoptable"
            fi
        fi
        [[ "$role" == "-" && -n "$fstype" && -z "$mount" ]] && role="unmounted"
        printf "  %-12s %-9s %-8s %-13s %-22s %s\n" \
            "$dev" "$size" "${tran:--}" "${label:--}" "${mount:--}" "$role"
    done < <(lsblk -rno NAME,SIZE,TRAN,FSTYPE,LABEL,MOUNTPOINT 2>/dev/null | tr ' ' '|')
    echo ""
    echo "  A disk labelled ${DISK_DATA_LABEL} is mounted at ${DISK_DATA_MOUNT} automatically,"
    echo "  whichever physical disk it is. Prepare a new one with:"
    echo -e "    ${CYAN}corex manage disk adopt /dev/sdX${NC}"
    echo ""
}

# Is the box in a state where a reboot would come back correctly?
disks_check() {
    local problems=0
    echo ""
    echo -e "${CYAN}${BOLD}Disk readiness${NC}"
    echo "──────────────────────────────────────────────────────────────"

    local dev
    for pair in "${DISK_DATA_MOUNT}:${DISK_DATA_LABEL}" "${DISK_TM_MOUNT}:${DISK_TM_LABEL}"; do
        local mount="${pair%%:*}" label="${pair##*:}"
        grep -qE "[[:space:]]${mount}[[:space:]]" /etc/fstab 2>/dev/null || continue

        if grep -qE "^LABEL=${label}[[:space:]]" /etc/fstab 2>/dev/null; then
            echo -e "  ${GREEN}ok${NC}    ${mount} mounts by label, so a replacement disk carrying"
            echo "        the label ${label} works with no further change"
        else
            echo -e "  ${YELLOW}warn${NC}  ${mount} still mounts by UUID. Replacing that disk would"
            echo "        leave it unmounted. Fix with: corex manage disk relabel"
            problems=$((problems + 1))
        fi

        dev=$(blkid -L "$label" 2>/dev/null || true)
        if [[ -n "$dev" ]]; then
            echo -e "  ${GREEN}ok${NC}    label ${label} is on ${dev}"
        else
            echo -e "  ${RED}fail${NC}  nothing carries the label ${label}"
            problems=$((problems + 1))
        fi

        if mountpoint -q "$mount"; then
            echo -e "  ${GREEN}ok${NC}    ${mount} is mounted"
        else
            echo -e "  ${RED}fail${NC}  ${mount} is NOT mounted"
            problems=$((problems + 1))
        fi
    done

    if [[ -f /etc/systemd/system/docker.service.d/99-corex-datadisk.conf ]]; then
        echo -e "  ${GREEN}ok${NC}    Docker will refuse to start without ${DISK_DATA_MOUNT},"
        echo "        so a missing disk cannot be mistaken for a fresh install"
    else
        echo -e "  ${YELLOW}warn${NC}  Docker would start without the data disk and create empty"
        echo "        directories in its place. Fix with: corex manage disk guard"
        problems=$((problems + 1))
    fi

    echo ""
    if [[ $problems -eq 0 ]]; then
        log_success "Disks are plug and play: swap the data SSD for one labelled ${DISK_DATA_LABEL} and it mounts itself."
    else
        log_warning "${problems} thing(s) to fix above."
    fi
    return 0
}

# Prepare a brand new disk to be a CoreX data disk. Destructive, and says so.
disks_adopt() {
    local dev="${1:-}"
    [[ -n "$dev" ]] || log_error "Usage: corex manage disk adopt /dev/sdX"
    [[ -b "$dev" ]] || log_error "${dev} is not a block device."

    # Refuse anything the running system depends on. Checking the mount table
    # is not enough: the root LV's physical volume has no mountpoint of its own.
    local sys_disk
    sys_disk=$(lsblk -no PKNAME "$(findmnt -no SOURCE / 2>/dev/null)" 2>/dev/null | head -1)
    [[ -n "$sys_disk" && "$dev" == *"$sys_disk"* ]] && log_error "${dev} holds the running system. Refusing."
    if lsblk -rno MOUNTPOINT "$dev" 2>/dev/null | grep -qE '^/'; then
        log_error "${dev} has mounted partitions. Unmount them first, deliberately."
    fi

    local size model
    size=$(lsblk -dno SIZE "$dev" 2>/dev/null | tr -d ' ')
    model=$(lsblk -dno MODEL "$dev" 2>/dev/null | sed 's/[[:space:]]*$//')

    echo ""
    log_warning "This ERASES ${dev} completely."
    echo "    Device: ${dev}  ${model:-unknown model}  ${size:-?}"
    echo "    It becomes a CoreX data disk labelled ${DISK_DATA_LABEL}."
    echo ""
    lsblk "$dev" 2>/dev/null || true
    echo ""
    if [[ ! -t 0 ]]; then
        log_error "Refusing to erase a disk without a terminal to confirm at."
    fi
    local answer
    read -r -p "  Type DESTROY to erase ${dev}: " answer
    [[ "$answer" == "DESTROY" ]] || { echo "  Aborted, nothing was changed."; return 1; }

    log_step "Partitioning ${dev}..."
    wipefs -a "$dev" >/dev/null 2>&1 || true
    parted -s "$dev" mklabel gpt || log_error "Could not write a partition table."
    parted -s "$dev" mkpart primary ext4 1MiB 100% || log_error "Could not create the partition."
    partprobe "$dev" 2>/dev/null || true
    sleep 2

    local part
    part="${dev}1"
    [[ "$dev" == *nvme* || "$dev" == *mmcblk* ]] && part="${dev}p1"
    [[ -b "$part" ]] || log_error "Expected ${part} to exist after partitioning."

    log_step "Formatting ${part} as ext4, labelled ${DISK_DATA_LABEL}..."
    mkfs.ext4 -F -L "$DISK_DATA_LABEL" "$part" >/dev/null || log_error "mkfs failed."

    log_success "${part} is ready and labelled ${DISK_DATA_LABEL}."
    echo ""
    echo "  It is not mounted yet, because ${DISK_DATA_MOUNT} is in use by the"
    echo "  current data disk. To swap:"
    echo "    1. sudo corex manage disable <every service>   (or power off)"
    echo "    2. copy the data across, or restore a backup onto it"
    echo "    3. remove the old disk, relabel this one if you cloned the old"
    echo "    4. reboot. It mounts itself, because the label is the role."
    echo ""
}

# Relabel whatever is mounted at the CoreX mountpoints, then switch fstab over.
# For a box installed before labels were used for mounting.
disks_relabel() {
    local src
    for pair in "${DISK_DATA_MOUNT}:${DISK_DATA_LABEL}" "${DISK_TM_MOUNT}:${DISK_TM_LABEL}"; do
        local mount="${pair%%:*}" label="${pair##*:}"
        mountpoint -q "$mount" || continue
        src=$(findmnt -no SOURCE "$mount" 2>/dev/null)
        [[ -n "$src" ]] || continue
        local current
        current=$(blkid -s LABEL -o value "$src" 2>/dev/null || true)
        if [[ "$current" != "$label" ]]; then
            log_info "Labelling ${src} as ${label} (was ${current:-none})..."
            e2label "$src" "$label" || log_warning "Could not label ${src}."
        fi
    done
    disks_fstab_use_labels
    disks_guard_docker
}
