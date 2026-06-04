#!/bin/bash
# CoreX Pro — Test Runner
# Usage: bash test/run-tests.sh [unit|smoke|syntax|all]
#
# Runs tests without touching the live server.
# All tests are safe to run locally or in the Docker test container.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

pass=0
fail=0
skip=0

log_section() { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }
log_pass()    { echo -e "${GREEN}[PASS]${NC} $1"; ((pass++)) || true; }
log_fail()    { echo -e "${RED}[FAIL]${NC} $1"; ((fail++)) || true; }
log_skip()    { echo -e "${YELLOW}[SKIP]${NC} $1"; ((skip++)) || true; }

# ─── Syntax Validation ────────────────────────────────────────────────────────

run_syntax_checks() {
    log_section "Syntax Validation (bash -n)"

    local scripts=(
        "corex.sh"
        "install-corex-master.sh"
        "nuke-corex.sh"
        "migrate-domain.sh"
    )

    # Add lib/ scripts if they exist (v2 modular structure)
    if [[ -d "${REPO_DIR}/lib" ]]; then
        while IFS= read -r -d '' f; do
            scripts+=("${f#${REPO_DIR}/}")
        done < <(find "${REPO_DIR}/lib" -name "*.sh" -print0)
    fi

    for script in "${scripts[@]}"; do
        local path="${REPO_DIR}/${script}"
        if [[ ! -f "$path" ]]; then
            log_skip "${script} (not yet created)"
            continue
        fi
        if bash -n "$path" 2>/dev/null; then
            log_pass "bash -n ${script}"
        else
            log_fail "bash -n ${script}"
            bash -n "$path" 2>&1 | sed 's/^/         /'
        fi
    done
}

run_shellcheck() {
    log_section "ShellCheck Static Analysis"

    if ! command -v shellcheck &>/dev/null; then
        log_skip "shellcheck not installed (apt install shellcheck)"
        return
    fi

    local scripts=(
        "corex.sh"
        "install-corex-master.sh"
        "nuke-corex.sh"
        "migrate-domain.sh"
    )

    for script in "${scripts[@]}"; do
        local path="${REPO_DIR}/${script}"
        if [[ ! -f "$path" ]]; then
            log_skip "${script} (not yet created)"
            continue
        fi
        # SC1090: Can't follow non-constant source — expected in modular scripts
        # SC2034: Variable appears unused — expected for SERVICE_* metadata vars
        if shellcheck -S warning -e SC1090,SC2034 "$path" 2>/dev/null; then
            log_pass "shellcheck ${script}"
        else
            log_fail "shellcheck ${script}"
            shellcheck -S warning -e SC1090,SC2034 "$path" 2>&1 | sed 's/^/         /'
        fi
    done
}

# ─── Unit Tests ───────────────────────────────────────────────────────────────

run_unit_tests() {
    log_section "Unit Tests (bats)"

    if ! command -v bats &>/dev/null; then
        log_skip "bats not installed (apt install bats)"
        return
    fi

    local unit_dir="${SCRIPT_DIR}/unit"
    if [[ ! -d "$unit_dir" ]] || [[ -z "$(ls "${unit_dir}"/*.bats 2>/dev/null)" ]]; then
        log_skip "No unit tests found in test/unit/"
        return
    fi

    if bats "${unit_dir}/" 2>&1; then
        log_pass "All unit tests passed"
    else
        log_fail "Unit tests failed"
    fi
}

# ─── Smoke Tests ──────────────────────────────────────────────────────────────

run_smoke_tests() {
    log_section "Smoke Tests (compose file generation)"

    if ! command -v bats &>/dev/null; then
        log_skip "bats not installed"
        return
    fi

    local smoke_dir="${SCRIPT_DIR}/smoke"
    if [[ ! -d "$smoke_dir" ]] || [[ -z "$(ls "${smoke_dir}"/*.bats 2>/dev/null)" ]]; then
        log_skip "No smoke tests found in test/smoke/"
        return
    fi

    if bats "${smoke_dir}/" 2>&1; then
        log_pass "All smoke tests passed"
    else
        log_fail "Smoke tests failed"
    fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    local mode="${1:-all}"

    echo -e "\n${CYAN}CoreX Pro Test Suite${NC}"
    echo -e "Repo: ${REPO_DIR}"
    echo -e "Mode: ${mode}\n"

    case "$mode" in
        syntax)
            run_syntax_checks
            run_shellcheck
            ;;
        unit)
            run_unit_tests
            ;;
        smoke)
            run_smoke_tests
            ;;
        all|*)
            run_syntax_checks
            run_shellcheck
            run_unit_tests
            run_smoke_tests
            ;;
    esac

    echo ""
    echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "Results: ${GREEN}${pass} passed${NC}  ${RED}${fail} failed${NC}  ${YELLOW}${skip} skipped${NC}"

    if [[ $fail -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
