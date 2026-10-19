#!/usr/bin/env bats
# The README is what people read first, and it is the file a release forgets.
# It said v3.13.0 on the badge and v3.25.1 in its history while v3.56.0 shipped.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    VERSION=$(sed -n -E 's/^COREX_VERSION="([0-9.]+)"/\1/p' "${REPO_ROOT}/corex.sh")
}

@test "README version badge matches corex.sh" {
    [ -n "$VERSION" ]
    grep -q "CoreX_Pro-v${VERSION}-blue" "${REPO_ROOT}/README.md"
}

@test "README version history names the current release" {
    grep -q "The current release is v${VERSION}\." "${REPO_ROOT}/README.md"
}

@test "lib/state.sh, CLAUDE.md and the changelog agree on the version" {
    grep -q "^_COREX_VERSION=\"${VERSION}\"" "${REPO_ROOT}/lib/state.sh"
    grep -q "^\*\*Current version:\*\* v${VERSION}$" "${REPO_ROOT}/CLAUDE.md"
    grep -q "^## \[v${VERSION}\]" "${REPO_ROOT}/CHANGELOG.md"
}

@test "every manage command in the help text is documented in the README" {
    local cmd missing=""
    while IFS= read -r cmd; do
        grep -qE "corex-manage\.sh ${cmd}( |\$)|corex manage ${cmd}( |\$)" "${REPO_ROOT}/README.md" \
            || missing+=" ${cmd}"
    done < <(sed -n '/^Commands:/,/^Examples:/p' "${REPO_ROOT}/corex-manage.sh" \
                | sed -n -E 's/^  ([a-z][a-z-]+).*/\1/p')
    [ -z "$missing" ] || { echo "not in README:${missing}"; false; }
}
