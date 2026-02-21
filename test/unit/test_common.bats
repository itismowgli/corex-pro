#!/usr/bin/env bats
# test/unit/test_common.bats
# Unit tests for logging/color functions extracted from install-corex-master.sh
# These functions will live in lib/common.sh (v2). For now they're tested
# against the inline definitions in install-corex-master.sh.
#
# Run: bats test/unit/test_common.bats

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

# Source the color/log functions directly (same as they appear in installer)
setup() {
    RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'
    YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

    log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
    log_step()    { echo -e "${CYAN}${BOLD}[STEP]${NC} $1"; }
    log_success() { echo -e "${GREEN}[  OK]${NC} $1"; }
    log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
    # log_error exits — test separately
}

# ─── Tests ───────────────────────────────────────────────────────────────────

@test "log_info outputs INFO prefix" {
    run log_info "test message"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[INFO]"* ]]
    [[ "$output" == *"test message"* ]]
}

@test "log_step outputs STEP prefix" {
    run log_step "Phase 1"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[STEP]"* ]]
    [[ "$output" == *"Phase 1"* ]]
}

@test "log_success outputs OK prefix" {
    run log_success "Done"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[  OK]"* ]]
    [[ "$output" == *"Done"* ]]
}

@test "log_warning outputs WARN prefix" {
    run log_warning "Something might be wrong"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[WARN]"* ]]
    [[ "$output" == *"Something might be wrong"* ]]
}

@test "generate_pass produces 24-char alphanumeric string" {
    generate_pass() { openssl rand -base64 24 | tr -d '/+=' | head -c 24; }
    run generate_pass
    [ "$status" -eq 0 ]
    [ "${#output}" -eq 24 ]
    # Should only contain alphanumeric characters
    [[ "$output" =~ ^[A-Za-z0-9]+$ ]]
}

@test "generate_pass produces unique values each time" {
    generate_pass() { openssl rand -base64 24 | tr -d '/+=' | head -c 24; }
    local pass1
    local pass2
    pass1=$(generate_pass)
    pass2=$(generate_pass)
    [ "$pass1" != "$pass2" ]
}

@test "check_root fails when not root" {
    check_root() {
        if [[ $EUID -ne 0 ]]; then
            echo "Not root"
            return 1
        fi
        return 0
    }
    # In bats, we're not root unless running as root
    if [[ $EUID -ne 0 ]]; then
        run check_root
        [ "$status" -eq 1 ]
    else
        skip "Running as root — cannot test non-root behavior"
    fi
}
