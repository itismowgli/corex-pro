#!/bin/bash
# CoreX Pro — Test Runner
# Usage: bash test/run-tests.sh [syntax|unit|smoke|go|frontend|e2e|all]
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
        "corex-manage.sh"
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
        "corex-manage.sh"
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

# Python regression tests use only the standard library and mocked host commands.
run_python_tests() {
    log_section "Python and cleanup regression tests"
    if ! command -v python3 &>/dev/null; then
        log_skip "python3 not installed"
        return
    fi
    if python3 -m unittest discover -s "${SCRIPT_DIR}/python" -v; then
        log_pass "Python regression tests passed"
    else
        log_fail "Python regression tests failed"
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

# An installed docker CLI is not a running daemon. Checking only `command -v
# docker` reported FAIL on a laptop with Docker Desktop stopped, which is an
# unavailable environment and not a broken build. A check that cannot run is
# skipped and says why; the same rule the ai-net note in network-check follows.
docker_usable() { command -v docker &>/dev/null && docker info &>/dev/null; }

# ─── Dashboard: Go ────────────────────────────────────────────────────────────
# Two things make this fail in ways that read as a broken build when they are
# a missing prerequisite, so both are handled rather than documented.
#
# main.go embeds web/dist with `go:embed all:web/dist`, and an embed of a
# directory that is not there is a SETUP failure: "pattern all:web/dist: no
# matching files found", printed before a single test runs. dist is a build
# artifact and is not in the repository, so it is built here when npm can.
#
# And the toolchain version is read from go.mod, never typed. golang:1.24
# refuses a module needing 1.25 with GOTOOLCHAIN=local, and a tag written by
# hand here goes stale the first time go.mod moves, which is the same defect
# as the "7 of 6" watchdog count and the network list that dropped backend-net.
run_go_tests() {
    log_section "Dashboard (go test)"

    local dash="${REPO_DIR}/dashboard"
    [[ -f "${dash}/go.mod" ]] || { log_skip "no dashboard/go.mod"; return; }

    if [[ ! -d "${dash}/web/dist" ]]; then
        if command -v npm &>/dev/null && [[ -d "${dash}/web/node_modules" ]]; then
            echo -e "${CYAN}[NOTE]${NC} Building web/dist first, because go:embed needs it"
            ( cd "${dash}/web" && npm run build >/dev/null 2>&1 ) \
                || { log_skip "web/dist could not be built, so go:embed has nothing to embed"; return; }
        else
            log_skip "web/dist absent and npm cannot build it: cd dashboard/web && npm ci && npm run build"
            return
        fi
    fi

    local want
    want=$(awk '/^go[[:space:]]+[0-9]/ {print $2; exit}' "${dash}/go.mod")
    [[ -n "$want" ]] || { log_skip "go.mod names no Go version"; return; }

    if command -v go &>/dev/null; then
        if ( cd "$dash" && go test ./... ); then
            log_pass "go test ./... (dashboard)"
        else
            log_fail "go test ./... (dashboard)"
        fi
        return
    fi

    if ! docker_usable; then
        log_skip "no local go, and no running docker to borrow one (go.mod wants ${want})"
        return
    fi
    # go.mod may say 1.25.0; the image tag is the major.minor of that.
    local tag="golang:${want%.*}-alpine"
    if docker run --rm -v "${dash}:/src" -w /src "$tag" go test ./...; then
        log_pass "go test ./... (dashboard, in ${tag})"
    else
        log_fail "go test ./... (dashboard, in ${tag})"
    fi
}

# ─── Dashboard: frontend ──────────────────────────────────────────────────────
# tsc, then vite, then four checks that each exist because of a bug they should
# have caught: logline, poll, responsive and render. See CLAUDE.md.
run_frontend_checks() {
    log_section "Dashboard frontend (tsc, vite, four checks)"

    local web="${REPO_DIR}/dashboard/web"
    [[ -f "${web}/package.json" ]] || { log_skip "no dashboard/web/package.json"; return; }
    command -v npm &>/dev/null || { log_skip "npm not installed"; return; }
    [[ -d "${web}/node_modules" ]] || { log_skip "node_modules absent: cd dashboard/web && npm ci"; return; }

    if ( cd "$web" && npm run build ); then
        log_pass "frontend build and checks"
    else
        log_fail "frontend build and checks"
    fi
}

# ─── Dashboard: login, end to end ─────────────────────────────────────────────
run_e2e_tests() {
    log_section "Dashboard login (end to end)"

    local script="${SCRIPT_DIR}/e2e/dashboard-auth.sh"
    [[ -x "$script" ]] || { log_skip "no test/e2e/dashboard-auth.sh"; return; }
    docker_usable || {
        log_skip "no running docker; on this box try: sudo bash test/run-tests.sh e2e"
        return
    }

    if bash "$script"; then
        log_pass "dashboard auth end to end"
    else
        log_fail "dashboard auth end to end"
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
            run_python_tests
            ;;
        smoke)
            run_smoke_tests
            ;;
        go)
            run_go_tests
            ;;
        frontend)
            run_frontend_checks
            ;;
        e2e)
            run_e2e_tests
            ;;
        all|*)
            run_syntax_checks
            run_shellcheck
            run_unit_tests
            run_python_tests
            run_smoke_tests
            run_go_tests
            run_frontend_checks
            run_e2e_tests
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
