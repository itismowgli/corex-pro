#!/bin/bash
# lib/drive.sh — CoreX Pro v2
# Phase 1: External SSD partitioning and mounting.
# Extracted from install-corex-master.sh Phase 1.

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

phase1_drive() {
    log_step "═══ PHASE 1: Drive Setup (External SSD) ═══"

    echo ""
    lsblk -d -o NAME,SIZE,MODEL,TRAN | grep -v loop
    echo ""
    log_warning "Enter the EXTERNAL SSD device name (e.g. sda, sdb, nvme1n1)"
    log_warning "⚠ DO NOT enter your OS drive!"
    read -r -p "Device: " DRIVE_NAME || log_error "No device input provided."
    TARGET_DEV="/dev/${DRIVE_NAME}"

    [[ ! -b "$TARGET_DEV" ]] && log_error "Device $TARGET_DEV not found."

    log_info "Stopping Docker and clearing disk locks..."
    systemctl stop docker 2>/dev/null || true
    log_info "Unmounting any existing partitions..."
    for p in $(lsblk -ln -o NAME "$TARGET_DEV" | tail -n +2); do
        umount -l "/dev/$p" 2>/dev/null || true
    done

    # Clean old fstab entries
    sed -i "\|$MOUNT_TM|d" /etc/fstab
    sed -i "\|$MOUNT_POOL|d" /etc/fstab
    systemctl daemon-reload

    echo ""
    log_warning "Has this drive ALREADY been partitioned for CoreX?"
    read -r -p "Skip formatting and just mount existing partitions? (y/N): " SKIP_FORMAT \
        || SKIP_FORMAT="n"

    if [[ "$SKIP_FORMAT" == "y" || "$SKIP_FORMAT" == "Y" ]]; then
        log_info "Skipping format — mounting existing partitions..."
    else
        log_warning "⚠ ALL DATA ON $TARGET_DEV WILL BE DESTROYED"
        read -r -p "Type 'DESTROY' to confirm: " CONFIRM || CONFIRM="CANCEL"
        [[ "$CONFIRM" != "DESTROY" ]] && log_error "Aborted by user."

        log_info "Wiping drive signatures..."
        wipefs -a -f "$TARGET_DEV"

        log_info "Creating GPT partition table..."
        parted -s "$TARGET_DEV" mklabel gpt

        log_info "Partition 1: ${TM_SIZE} for Time Machine..."
        parted -s "$TARGET_DEV" mkpart primary ext4 0% "$TM_SIZE"

        log_info "Partition 2: remaining space for Data Pool..."
        parted -s "$TARGET_DEV" mkpart primary ext4 "$TM_SIZE" 100%

        sleep 2; partprobe "$TARGET_DEV"; sleep 3

        if [[ "$TARGET_DEV" == *nvme* ]]; then
            P1="${TARGET_DEV}p1"; P2="${TARGET_DEV}p2"
        else
            P1="${TARGET_DEV}1"; P2="${TARGET_DEV}2"
        fi

        log_info "Formatting partitions as ext4..."
        mkfs.ext4 -F -L TIMEMACHINE "$P1"
        mkfs.ext4 -F -L COREX_DATA "$P2"
    fi

    if [[ "$TARGET_DEV" == *nvme* ]]; then
        P1="${TARGET_DEV}p1"; P2="${TARGET_DEV}p2"
    else
        P1="${TARGET_DEV}1"; P2="${TARGET_DEV}2"
    fi

    mkdir -p "$MOUNT_TM" "$MOUNT_POOL"

    local U1 U2
    U1=$(blkid -s UUID -o value "$P1")
    U2=$(blkid -s UUID -o value "$P2")
    [[ -z "$U1" || -z "$U2" ]] && log_error "Could not read partition UUIDs."

    echo "UUID=$U1 $MOUNT_TM ext4 defaults,noatime,nofail 0 2" >> /etc/fstab
    echo "UUID=$U2 $MOUNT_POOL ext4 defaults,noatime,nofail 0 2" >> /etc/fstab
    mount -a

    mountpoint -q "$MOUNT_TM" && mountpoint -q "$MOUNT_POOL" \
        && log_success "Both partitions mounted." \
        || log_error "Mount failed. Check dmesg for errors."
    df -h "$MOUNT_TM" "$MOUNT_POOL"

    systemctl start docker 2>/dev/null || true
}
