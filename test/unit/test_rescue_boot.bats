#!/usr/bin/env bats
# corex manage rescue-boot: what the rescue entry does, and where it sits.

refute() { if "$@"; then echo "expected failure: $*"; return 1; fi; }

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    source "${REPO_ROOT}/lib/rescue_boot.sh"
}

@test "the rescue entry looks for the system disk before it waits" {
    cfg="$(rescue_boot_grub_cfg D552-3A8B)"
    look=$(grep -n 'search .*--fs-uuid .*D552-3A8B' <<< "$cfg" | cut -d: -f1)
    wait=$(grep -n '^sleep ' <<< "$cfg" | cut -d: -f1)
    [ -n "$look" ]
    [ -n "$wait" ]
    # Booted first by mistake, it has to hand over at once, not sit for 45s.
    [ "$look" -lt "$wait" ]
}

@test "the rescue entry resets, it never powers off or drops to a prompt" {
    cfg="$(rescue_boot_grub_cfg D552-3A8B)"
    [ "$(tail -1 <<< "$cfg")" = "reboot" ]
    refute grep -qE '^(halt|exit)' <<< "$cfg"
    # The variable is GRUB's, so it must reach the file unexpanded.
    grep -qF 'chainloader ($sysesp)/EFI/ubuntu/shimx64.efi' <<< "$cfg"
}

@test "the rescue entry goes second, behind what the firmware boots now" {
    [ "$(rescue_boot_order '0002,0000,0003,0004,0005' '0001')" = "0002,0001,0000,0003,0004,0005" ]
    [ "$(rescue_boot_order '0002' '0001')" = "0002,0001" ]
    [ "$(rescue_boot_order '' '0001')" = "0001" ]
}

@test "setting the order twice does not list the rescue entry twice" {
    [ "$(rescue_boot_order '0001,0002,0000' '0001')" = "0002,0001,0000" ]
    [ "$(rescue_boot_order '0002,0001,0000' '0001')" = "0002,0001,0000" ]
}

@test "setup refuses the system disk and confirms before partitioning" {
    grep -q 'has to live on a different one' "${REPO_ROOT}/lib/rescue_boot.sh"
    grep -q 'Type yes to add the partition' "${REPO_ROOT}/lib/rescue_boot.sh"
    # Formats only what carries its own label.
    grep -q 'Not formatting it' "${REPO_ROOT}/lib/rescue_boot.sh"
}

@test "a missing rescue partition is reported as none, not as a path" {
    # readlink -f prints the path it was given when only the last part is
    # missing, which made setup skip the partitioning on a box with none.
    RESCUE_BY_LABEL="${BATS_TEST_TMPDIR}/by-partlabel"
    mkdir -p "$RESCUE_BY_LABEL"
    run _rescue_part
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "a rescue label that is not a block device does not count" {
    RESCUE_BY_LABEL="${BATS_TEST_TMPDIR}/by-partlabel"
    mkdir -p "$RESCUE_BY_LABEL"
    : > "${RESCUE_BY_LABEL}/${RESCUE_LABEL}"
    run _rescue_part
    [ -z "$output" ]
}
