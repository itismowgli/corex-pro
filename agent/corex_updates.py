"""Whether each installed service actually has an update waiting.

The Services tab used to offer an Update button on every card whether or not
anything had changed, which is what made it read as a control panel rather
than something that tells you the state of the box. Answering the question
properly is harder than it looks, and the previous attempt got it wrong in two
specific ways that are easy to repeat.

It read `docker compose config --images | head -1`. A service module is not one
image: monitoring ships five and ai ships three. One current image at the top
of the list returned early and skipped the rest, and the image at the top was
usually node-exporter, which almost never changes. Every image in the stack is
checked here.

And it compared a local `RepoDigest` against an entry from `docker manifest
inspect`, which are different digests by construction: the first is the digest
of the multi-architecture index the tag pointed at, the second is a
per-platform manifest inside it. They never match, so everything looked stale.
This asks the registry for the digest of the same thing the local image
records, using the index media types in the Accept header.

There is a third failure mode that no digest comparison can see. A tag can
stop moving: upstream starts a new release line under a new name and leaves the
old tag frozen, and `docker pull` saying "Image is up to date" is then true and
useless. `louislam/uptime-kuma:latest` sat ten months behind that way while
every update run reported success. So where the registry will say when a tag
was last built, that date is read too, and a tag nobody has rebuilt in six
months is reported as its own state rather than as current.

Nothing here pulls anything. It is HEAD requests against a registry, cached for
a day, computed on a background thread.
"""

import json
import os
import re
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

CACHE = "/var/lib/corex/updates.json"
DOCKER_ROOT = os.environ.get("COREX_DOCKER_ROOT", "/mnt/corex-data/docker-configs")

# A day. The question being answered changes when upstream publishes, which is
# not something a dashboard poll needs to see within the hour, and every check
# is a network round trip per image.
TTL = 24 * 3600

# Long enough for a slow registry, short enough that a dozen images cannot
# hold the refresh thread for minutes.
HTTP_TIMEOUT = 15

# A tag nobody has rebuilt in this long has most likely been abandoned rather
# than perfected. Six months is past every sane release cadence for a
# container that tracks a name rather than a version.
STALE_TAG_DAYS = 180

INDEX_TYPES = ", ".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
])

_lock = threading.Lock()
_refreshing = {"now": False}


def _run(argv, timeout=30):
    try:
        p = subprocess.run(argv, capture_output=True, text=True,
                           timeout=timeout, check=False)
        return p.returncode, p.stdout
    except (OSError, subprocess.TimeoutExpired):
        return 1, ""


# ── Reference parsing ───────────────────────────────────────────────────────

def parse_ref(ref):
    """Split an image reference into registry host, repository and tag.

    Returns None for a reference pinned by digest: there is nothing to check,
    because a digest cannot move.
    """
    if "@" in ref:
        return None
    host, _, rest = ref.partition("/")
    if not rest or ("." not in host and ":" not in host and host != "localhost"):
        # No registry in the reference, so it is Docker Hub. A single-segment
        # name is an official image and lives under library/.
        host, rest = "registry-1.docker.io", ref
        if "/" not in rest.split(":")[0]:
            rest = "library/" + rest
    elif host in ("docker.io", "index.docker.io"):
        host = "registry-1.docker.io"
        if "/" not in rest.split(":")[0]:
            rest = "library/" + rest

    repo, sep, tag = rest.rpartition(":")
    if not sep or "/" in tag:
        repo, tag = rest, "latest"
    return {"host": host, "repo": repo, "tag": tag}


# ── Registry ────────────────────────────────────────────────────────────────

_tokens = {}


def _bearer(host, repo):
    """A pull token for one repository, via the registry's own challenge.

    Asking /v2/ what it wants rather than hardcoding auth.docker.io means
    ghcr.io, lscr.io and quay.io work without a branch each.
    """
    key = (host, repo)
    cached = _tokens.get(key)
    if cached and cached[1] > time.time():
        return cached[0]

    realm = service = None
    try:
        req = urllib.request.Request("https://%s/v2/" % host, method="GET")
        urllib.request.urlopen(req, timeout=HTTP_TIMEOUT).close()
        return ""                                   # open registry, no token
    except urllib.error.HTTPError as exc:
        if exc.code != 401:
            return ""
        challenge = exc.headers.get("Www-Authenticate", "")
        realm = re.search(r'realm="([^"]+)"', challenge)
        service = re.search(r'service="([^"]+)"', challenge)
        realm = realm.group(1) if realm else None
        service = service.group(1) if service else None
    except (urllib.error.URLError, OSError):
        return None                                 # cannot reach it at all

    if not realm:
        return ""
    params = {"scope": "repository:%s:pull" % repo}
    if service:
        params["service"] = service
    url = realm + "?" + urllib.parse.urlencode(params)
    try:
        with urllib.request.urlopen(url, timeout=HTTP_TIMEOUT) as resp:
            body = json.loads(resp.read().decode("utf-8", "replace"))
    except (urllib.error.URLError, OSError, ValueError):
        return None
    token = body.get("token") or body.get("access_token") or ""
    # Registries hand out short-lived tokens; a minute of margin is plenty for
    # one refresh pass and keeps a stale token out of the next one.
    _tokens[key] = (token, time.time() + max(60, int(body.get("expires_in", 300))) - 60)
    return token


def remote_digest(host, repo, tag):
    """(digest, problem) for the tag as the registry reports it.

    The digest is the same kind a local image records in RepoDigests, which is
    the whole point: comparing an index digest against a per-platform manifest
    digest is a comparison that can never succeed.

    The problem is named rather than collapsed into a single failure, because
    "this repository does not exist" and "the registry did not answer" are
    different news. The first is how a locally built image looks, and
    reporting that as a lookup failure sent the reader to check their network.
    Docker Hub answers 401 rather than 404 for a name that is not there, so
    both codes mean the same thing here.
    """
    token = _bearer(host, repo)
    if token is None:
        return None, "unreachable"
    headers = {"Accept": INDEX_TYPES}
    if token:
        headers["Authorization"] = "Bearer " + token
    url = "https://%s/v2/%s/manifests/%s" % (host, repo, urllib.parse.quote(tag))
    try:
        req = urllib.request.Request(url, headers=headers, method="HEAD")
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            return resp.headers.get("Docker-Content-Digest"), None
    except urllib.error.HTTPError as exc:
        return None, "absent" if exc.code in (401, 403, 404) else "unreachable"
    except (urllib.error.URLError, OSError):
        return None, "unreachable"


# Tags that are names rather than versions, and so are expected to move.
MOVING_TAGS = {
    "latest", "stable", "release", "main", "master", "edge",
    "dev", "develop", "nightly", "rolling", "current",
}

# A full three-part version. A tag like v6.2.0 is meant never to be rebuilt,
# which is the entire reason for pinning it, so asking when it last moved and
# calling the answer stale was noise: it reported Cal.com's deliberately
# pinned v6.2.0 as a problem after 186 quiet days. Noise on a badge is worse
# than no badge, because it teaches the reader to ignore the next one.
PINNED_VERSION = re.compile(r"^v?\d+\.\d+\.\d+")


def tag_moves(tag):
    """Whether upstream is expected to rebuild this tag in place.

    A word, or a version with a part left off: nextcloud:34 and traefik:v3.6
    both follow a line and both move. A full version does not.
    """
    if tag.lower() in MOVING_TAGS:
        return True
    return not PINNED_VERSION.match(tag)


def tag_last_built(host, repo, tag):
    """When this tag was last pushed, in unix seconds, or None if unknowable.

    Only Docker Hub publishes this, and it is the answer to the question a
    digest cannot reach: whether the tag itself has been abandoned.
    """
    if host != "registry-1.docker.io":
        return None
    url = "https://hub.docker.com/v2/repositories/%s/tags/%s" % (
        repo, urllib.parse.quote(tag))
    try:
        with urllib.request.urlopen(url, timeout=HTTP_TIMEOUT) as resp:
            body = json.loads(resp.read().decode("utf-8", "replace"))
    except (urllib.error.URLError, OSError, ValueError):
        return None
    stamp = str(body.get("last_updated") or "")
    if not stamp:
        return None
    stamp = stamp.replace("Z", "+00:00")
    try:
        import datetime
        return int(datetime.datetime.fromisoformat(stamp).timestamp())
    except (ValueError, TypeError):
        return None


# ── Local state ─────────────────────────────────────────────────────────────

def service_images(service):
    """Every image the service's compose file names, not just the first one."""
    compose = os.path.join(DOCKER_ROOT, service, "docker-compose.yml")
    if not os.path.exists(compose):
        return []
    rc, out = _run(["docker", "compose", "-f", compose, "config", "--images"])
    if rc != 0:
        return []
    seen, images = set(), []
    for line in out.splitlines():
        line = line.strip()
        if not line or line in seen:
            continue
        seen.add(line)
        images.append(line)
    return images


def local_digests(ref):
    """The digests the local copy of this image records, if it is present."""
    rc, out = _run(["docker", "image", "inspect", ref,
                    "--format", "{{json .RepoDigests}}"], timeout=20)
    if rc != 0:
        return []
    try:
        entries = json.loads(out.strip() or "[]")
    except ValueError:
        return []
    return [e.split("@", 1)[1] for e in entries if "@" in e]


# ── The check ───────────────────────────────────────────────────────────────

def check_image(ref):
    """One image: current, an update waiting, a frozen tag, or unknown.

    "unknown" is a real answer and is reported as one. A registry that cannot
    be reached must not be presented as either good or bad news, and hiding
    the Update button on the strength of a failed lookup would take a working
    feature away over a network blip.
    """
    parsed = parse_ref(ref)
    if parsed is None:
        return {"image": ref, "state": "pinned",
                "note": "pinned to a digest, so it cannot move"}
    host, repo, tag = parsed["host"], parsed["repo"], parsed["tag"]

    local = local_digests(ref)
    if not local:
        return {"image": ref, "state": "unknown",
                "note": "not present locally, or built here rather than pulled"}
    # Recorded on every answer below, so a cached verdict can be checked
    # against the image it was made about without asking the registry again.
    _base = local[0]

    remote, problem = remote_digest(host, repo, tag)
    if problem == "absent":
        return {"image": ref, "state": "pinned", "local": _base,
                "note": "%s holds no %s, so this image is built here" % (host, repo)}
    if not remote:
        return {"image": ref, "state": "unknown",
                "note": "could not ask %s about %s" % (host, tag)}

    if remote not in local:
        return {"image": ref, "state": "update", "local": local[0],
                "note": "%s now points at %s" % (tag, remote[:19])}

    # Only worth asking about a tag that is meant to move.
    if tag_moves(tag):
        built = tag_last_built(host, repo, tag)
        if built:
            age_days = int((time.time() - built) / 86400)
            if age_days >= STALE_TAG_DAYS:
                return {"image": ref, "state": "stale-tag", "age_days": age_days,
                        "local": _base,
                        "note": ("%s is current but has not been rebuilt in %d days, "
                                 "so check whether upstream has moved to another tag"
                                 % (tag, age_days))}
    # "current" records it too, and that is the case that matters most: it is
    # the verdict that hides the Update button, so an image replaced underneath
    # it must not leave the button hidden on a stale claim.
    return {"image": ref, "state": "current", "local": _base,
            "note": "%s is current" % tag}


# The order matters: the worst news about any image in a stack is the news
# about the stack.
_RANK = {"update": 3, "stale-tag": 2, "unknown": 1, "current": 0, "pinned": 0}


def check_service(service):
    images = service_images(service)
    if not images:
        return {"service": service, "state": "unknown", "images": [],
                "note": "no compose file, or it names no images"}
    rows = [check_image(ref) for ref in images]
    worst = max(rows, key=lambda r: _RANK.get(r["state"], 0))
    moved = [r for r in rows if r["state"] == "update"]
    note = worst["note"]
    if len(moved) > 1:
        note = "%d of %d images have moved" % (len(moved), len(rows))
    elif worst["state"] == "current" and len(rows) > 1:
        # A module can ship five images, and naming one of them reads as
        # though the other four were not looked at.
        note = "all %d images are current" % len(rows)
    return {"service": service, "state": worst["state"], "images": rows,
            "note": note}


# ── Cache ───────────────────────────────────────────────────────────────────

def _read_cache():
    try:
        with open(CACHE, encoding="utf-8", errors="replace") as fh:
            doc = json.load(fh)
    except (OSError, ValueError):
        return {"checked_at": 0, "services": {}}
    if not isinstance(doc, dict):
        return {"checked_at": 0, "services": {}}
    doc.setdefault("checked_at", 0)
    doc.setdefault("services", {})
    return doc


def _write_cache(doc):
    tmp = CACHE + ".tmp"
    try:
        os.makedirs(os.path.dirname(CACHE), exist_ok=True)
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(doc, fh, sort_keys=True)
        os.replace(tmp, CACHE)
        os.chmod(CACHE, 0o644)
    except OSError:
        pass


def _refresh(services):
    try:
        doc = {"checked_at": int(time.time()), "services": {}}
        for svc in services:
            doc["services"][svc] = check_service(svc)
        _write_cache(doc)
    finally:
        with _lock:
            _refreshing["now"] = False


def recheck(names):
    """Re-ask the registry about these services now, and store the answer.

    Called the moment an update finishes. Without it the cached answer stands
    for up to a day, so a service that was just updated keeps its "Update
    available" badge and keeps offering the button, which reads as the update
    having silently failed. The check itself was never wrong: run fresh
    against a service reporting an update, both digests matched exactly and
    the state came back current. It was only ever answering an older question.

    Synchronous on purpose, and cheap: one HEAD request per image against a
    registry the update has just finished pulling from, so the connection and
    the token are warm. A background refresh would race the dashboard's own
    reload and leave the badge wrong for exactly as long as anyone was still
    looking at it.
    """
    if isinstance(names, str):
        names = [names]
    names = [n for n in (names or []) if n]
    if not names:
        return {}
    doc = _read_cache()
    out = {}
    for svc in names:
        try:
            row = check_service(svc)
        except Exception:      # noqa: BLE001 - a lookup must never fail an update
            continue
        doc["services"][svc] = row
        out[svc] = row
    # checked_at describes the whole document, and most of it was not
    # re-read, so it is deliberately left alone. Moving it forward here would
    # claim every other service had just been checked too.
    _write_cache(doc)
    return out


STATE_JSON = "/etc/corex/state.json"


def installed_services():
    """The services state.json says are installed, so a removed one is not
    checked and a service that was never installed does not appear."""
    try:
        with open(STATE_JSON, encoding="utf-8", errors="replace") as fh:
            doc = json.load(fh)
    except (OSError, ValueError):
        return []
    out = []
    for name, row in (doc.get("services") or {}).items():
        if isinstance(row, dict) and row.get("installed"):
            out.append(name)
    return sorted(out)


def _answer_is_about_a_different_image(row):
    """Whether a cached verdict was made about an image that has since moved.

    The cache holds an answer for a day, and the only thing that can make an
    answer wrong before then is the local image changing. That happens whenever
    anything pulls: this tool, a repair, the scheduled maintenance, or someone
    at a shell. So the verdict records the digest it was made about, and a
    cheap local comparison catches all of those without a registry round trip.

    A stale "update" badge is the visible half of this. It reads as the update
    button having done nothing, which is exactly the complaint that produced
    this function.
    """
    for img in (row.get("images") or []):
        base = img.get("local")
        if not base:
            continue
        now = local_digests(img.get("image") or "")
        if now and base not in now:
            return True
    return False


def updates(services=None, refresh=False):
    """The cached answer, refreshing it in the background when it is old.

    Returned even while stale, with the age attached, so the page always has
    something to show. A dashboard poll must never wait on a dozen registry
    round trips.
    """
    if services is None:
        services = installed_services()
    doc = _read_cache()
    age = time.time() - doc["checked_at"]

    # An answer about an image that has since been replaced is not merely old,
    # it is about something else. Report those as unknown, which keeps the
    # Update button where it was rather than making a claim, and let the
    # background refresh settle it.
    moved = []
    for name, row in list(doc["services"].items()):
        if not isinstance(row, dict):
            continue
        try:
            if _answer_is_about_a_different_image(row):
                moved.append(name)
        except Exception:      # noqa: BLE001 - never fail a poll over this
            continue
    for name in moved:
        doc["services"][name] = {
            "service": name, "state": "unknown", "images": [],
            "note": "the local image changed since this was checked",
        }

    stale = refresh or age > TTL or bool(moved)
    if stale:
        with _lock:
            if not _refreshing["now"]:
                _refreshing["now"] = True
                threading.Thread(target=_refresh, args=(list(services),),
                                 daemon=True).start()
    return {
        "checked_at": int(doc["checked_at"]),
        "checking": _refreshing["now"],
        "services": doc["services"],
    }
