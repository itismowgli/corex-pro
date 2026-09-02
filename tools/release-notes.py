#!/usr/bin/env python3
"""Print one version's CHANGELOG section, for use as a GitHub release body.

    python3 tools/release-notes.py v3.12.0 > /tmp/notes.md
    gh release create v3.12.0 --title v3.12.0 --notes-file /tmp/notes.md

Release convention for this repo:
  - tag and title are both exactly vX.Y.Z, nothing else. Titles had drifted
    through three styles ("CoreX Pro v3.1.0 - Resilience", "v3.4.0 - credentials
    ...", "2.0.0") which makes the release list unreadable.
  - the body is this version's CHANGELOG section verbatim, so the changelog
    stays the single source of truth.

It refuses rather than warns, because a release body cannot be quietly fixed
later: it is what people receive in notifications and read in the archive. Two
things it will not publish, both from the project's own rules in CLAUDE.md:
em and en dashes, and anything identifying real infrastructure.
"""

import re
import sys

FORBIDDEN_CHARS = "—–“”‘’"

# Patterns that mean a real host, account or credential has reached the notes.
FORBIDDEN_PATTERNS = [
    (r"[0-9]{8,10}:[A-Za-z0-9_-]{30,}", "a Telegram bot token"),
    (r"\b(?:\d{1,3}\.){3}\d{1,3}\b", "an IP address"),
    (r"(?i)\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b", "an email address"),
    (r"(?i)(pass(word)?|secret|token|api[_-]?key)\s*[=:]\s*\S{8,}", "a credential"),
]


def extract(changelog, version):
    m = re.search(r"^## \[%s\][^\n]*\n(.*?)(?=^## \[|\Z)" % re.escape(version),
                  changelog, re.S | re.M)
    if not m:
        raise SystemExit("no CHANGELOG section for %s" % version)
    return m.group(1).strip()


def check(body, version):
    found = {c: body.count(c) for c in FORBIDDEN_CHARS if c in body}
    if found:
        raise SystemExit(
            "%s notes contain characters the project rules forbid: %r\n"
            "Fix them in CHANGELOG.md, not here." % (version, found))
    for pattern, what in FORBIDDEN_PATTERNS:
        hit = re.search(pattern, body)
        if hit:
            raise SystemExit(
                "%s notes look like they contain %s (%r). Refusing to publish."
                % (version, what, hit.group(0)[:40]))


def main(argv):
    if len(argv) != 1 or not re.fullmatch(r"v\d+\.\d+\.\d+", argv[0]):
        raise SystemExit("usage: release-notes.py vX.Y.Z")
    version = argv[0]
    with open("CHANGELOG.md", encoding="utf-8") as fh:
        body = extract(fh.read(), version)
    check(body, version)
    print(body)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
