"""Everything the dashboard needs to show the box at a glance, as data.

WHY THIS IS ON THE PRIVILEGED SIDE
    The dashboard container is `nobody` and sees its own filesystem, not the
    host's, so `df` in there measures the wrong thing entirely. The obvious
    fix, bind-mounting /mnt/corex-data, hands a web-facing container every
    service's data: Vaultwarden's vault, Immich's photos, and the Telegram bot
    token that sits in Uptime Kuma's notification config. So the agent reads
    it and returns numbers.

    Nothing here returns a credential. The Kuma reader takes monitor names and
    heartbeat states and never touches the `notification` table.

WHY THE HISTORY IS FREE
    /mnt/corex-data/blackbox.log already records temperature, load, memory,
    swap, throttle count and container count every twenty seconds, because it
    is the only evidence that survives an unclean shutdown (gotcha #16). That
    makes it a time series nobody had to collect: the graphs read it rather
    than adding a second sampler.

EVERY READER FAILS SOFT
    A dashboard that shows nothing because one disk did not answer is worse
    than one showing eight panels and a gap. Each collector returns its own
    piece or None, and the caller assembles whatever arrived.
"""

import datetime
from collections import deque
import json
import os
import re
import shutil
import sqlite3
import subprocess
import threading
import time

import corex_updates as cu_updates

BLACKBOX = "/mnt/corex-data/blackbox.log"
WATCHDOG_LOG = "/var/log/corex-watchdog.log"
THERMAL_CONF = "/etc/corex/thermal.conf"
THERMAL_SHED = "/var/lib/corex/thermal-shed.list"
KUMA_DB = "/mnt/corex-data/service-data/uptime-kuma/kuma.db"
DATA_ROOT = "/mnt/corex-data"

# Sampled every 20s, so 360 points is two hours, which is the window that
# actually answers "what happened just before it got hot".
SERIES_POINTS = 360


def _run(argv, timeout=20):
    try:
        p = subprocess.run(argv, capture_output=True, text=True,
                           timeout=timeout, check=False)
        return p.returncode, p.stdout
    except (OSError, subprocess.TimeoutExpired):
        return 1, ""


# ── Host vitals ─────────────────────────────────────────────────────────────

def cpu_temp():
    """Tctl if lm-sensors is present, else the hottest thermal zone.

    Without lm-sensors the most common hardware failure on this class of
    machine is invisible (gotcha #17), so the absence is reported rather than
    silently read as zero.
    """
    rc, out = _run(["sensors", "-u"], timeout=10)
    if rc == 0:
        m = re.search(r"^(?:Tctl|Tdie|Package id 0):\n\s+\S+:\s+([0-9.]+)",
                      out, re.M)
        if m:
            return float(m.group(1)), "sensors"
    best = None
    try:
        for name in os.listdir("/sys/class/thermal"):
            if not name.startswith("thermal_zone"):
                continue
            try:
                with open("/sys/class/thermal/%s/temp" % name) as fh:
                    v = int(fh.read().strip()) / 1000.0
            except (OSError, ValueError):
                continue
            if best is None or v > best:
                best = v
    except OSError:
        pass
    return (best, "thermal_zone") if best is not None else (None, "none")


def meminfo():
    out = {}
    try:
        with open("/proc/meminfo") as fh:
            for line in fh:
                k, _, v = line.partition(":")
                out[k.strip()] = int(v.split()[0])  # kB
    except (OSError, ValueError, IndexError):
        return None
    total = out.get("MemTotal", 0) // 1024
    avail = out.get("MemAvailable", 0) // 1024
    swt = out.get("SwapTotal", 0) // 1024
    swf = out.get("SwapFree", 0) // 1024
    return {
        "used_mb": total - avail, "total_mb": total,
        "swap_used_mb": swt - swf, "swap_total_mb": swt,
    }


def uptime_seconds():
    try:
        with open("/proc/uptime") as fh:
            return int(float(fh.read().split()[0]))
    except (OSError, ValueError, IndexError):
        return None


def disks():
    """The two that matter: the OS disk and the data SSD.

    "Brains on System, muscle on SSD" is the whole storage design, so these are
    two separate answers and a single combined figure would hide the one that
    is filling.
    """
    out = []
    for path, label in (("/", "OS disk"), (DATA_ROOT, "Data SSD")):
        try:
            u = shutil.disk_usage(path)
        except OSError:
            continue
        out.append({
            "path": path, "label": label,
            "used_b": u.used, "total_b": u.total, "free_b": u.free,
            "pct": round(u.used * 100.0 / u.total, 1) if u.total else 0,
        })
    return out


def storage_layout():
    """Every disk in the box, what is on it, and what is not being used.

    `disks()` above answers "are the two filesystems CoreX writes to filling
    up", which is the operational question. This answers the different one the
    Storage page needs: what hardware is fitted, how it is divided, and which
    parts of it are doing nothing. Those are not the same, and the gap between
    them is where capacity hides: on the reference box a 400GB partition sat
    idle because Time Machine had moved elsewhere years earlier, and 240GB of
    the internal NVMe had never been handed out at all, neither of which any
    `df` output mentions.

    Sizes are bytes throughout. A filesystem always reports less than its
    partition, because formatting costs a few percent and ext4 reserves five
    more for root; that difference is returned rather than hidden, so the page
    can account for every byte instead of quietly losing some.
    """
    layout = {"disks": [], "lvm": None,
              "totals": {"raw_b": 0, "used_b": 0, "free_b": 0, "idle_b": 0}}

    # -b for bytes, -P for key="value" pairs: the raw format collapses empty
    # columns and shifts every later value one place left.
    rc, text = _run(["lsblk", "-b", "-P", "-o",
                     "NAME,KNAME,TYPE,SIZE,FSTYPE,LABEL,MOUNTPOINT,MODEL,TRAN,PKNAME"],
                    timeout=30)
    if rc != 0:
        return layout

    rows = []
    for line in text.splitlines():
        row = {}
        for m in re.finditer(r'(\w+)="([^"]*)"', line):
            row[m.group(1)] = m.group(2)
        if row:
            rows.append(row)

    def usage(mount):
        if not mount:
            return None
        try:
            u = shutil.disk_usage(mount)
        except OSError:
            return None
        return {"used_b": u.used, "total_b": u.total, "free_b": u.free,
                "pct": round(u.used * 100.0 / u.total, 1) if u.total else 0}

    by_disk = {}
    for row in rows:
        if row.get("TYPE") != "disk":
            continue
        by_disk[row["KNAME"]] = {
            "name": row["NAME"],
            "size_b": _int(row.get("SIZE")),
            "model": (row.get("MODEL") or "").strip() or None,
            # usb or nvme is the single most useful fact about a disk here,
            # because it is the difference between a good place for a database
            # and a bad one.
            "transport": (row.get("TRAN") or "").strip() or None,
            "parts": [],
            "unallocated_b": 0,
        }

    for row in rows:
        if row.get("TYPE") not in ("part", "lvm", "crypt"):
            continue
        parent = row.get("PKNAME") or ""
        disk = by_disk.get(parent)
        mount = row.get("MOUNTPOINT") or ""
        part = {
            "name": row["NAME"],
            "kind": row.get("TYPE"),
            "size_b": _int(row.get("SIZE")),
            "fstype": (row.get("FSTYPE") or "").strip() or None,
            "label": (row.get("LABEL") or "").strip() or None,
            "mount": mount or None,
            "usage": usage(mount),
        }
        if disk is not None:
            disk["parts"].append(part)
        else:
            # An LV sits on the volume group, not on a disk, so it has no
            # parent among the physical disks. It is still worth reporting.
            layout.setdefault("volumes", []).append(part)

    # Space on a disk that no partition covers. Not the same as free space in
    # a filesystem, and invisible to df, which is exactly why it goes unnoticed.
    for disk in by_disk.values():
        covered = sum(p["size_b"] for p in disk["parts"] if p["kind"] == "part")
        disk["unallocated_b"] = max(0, disk["size_b"] - covered)

    layout["disks"] = sorted(by_disk.values(), key=lambda d: d["name"])

    # Space in the volume group that no logical volume has claimed. This is
    # free capacity on the fastest disk in the machine and nothing else
    # reports it.
    rc, text = _run(["vgs", "--noheadings", "--nosuffix", "--units", "b",
                     "-o", "vg_name,vg_size,vg_free"], timeout=20)
    if rc == 0 and text.strip():
        f = text.split()
        if len(f) >= 3:
            layout["lvm"] = {"vg": f[0], "size_b": _int(f[1]), "free_b": _int(f[2])}

    # Totals, in the terms the page asks its question in.
    raw = sum(d["size_b"] for d in layout["disks"])
    used = free = 0
    for d in layout["disks"]:
        for p in d["parts"]:
            if p["usage"]:
                used += p["usage"]["used_b"]
                free += p["usage"]["free_b"]
    for v in layout.get("volumes", []):
        if v["usage"]:
            used += v["usage"]["used_b"]
            free += v["usage"]["free_b"]
    idle = sum(d["unallocated_b"] for d in layout["disks"])
    if layout["lvm"]:
        idle += layout["lvm"]["free_b"]
    layout["totals"] = {"raw_b": raw, "used_b": used, "free_b": free, "idle_b": idle}
    return layout


# ── The time series, read from the blackbox ─────────────────────────────────

_SAMPLE = re.compile(
    r"^(?P<t>\S+) temp=(?P<temp>[0-9.]+)C load=(?P<l1>[0-9.]+)/[0-9.]+/[0-9.]+"
    r" mem=(?P<mu>\d+)/(?P<mt>\d+)MB swap=(?P<su>\d+)/\d+MB"
    r" throttle=(?P<thr>\S+) containers=(?P<c>\d+)")


def series(points=SERIES_POINTS, path=BLACKBOX):
    """The last N samples. Read from the tail rather than parsed whole.

    The file grows forever and is already thousands of lines; reading all of
    it on every dashboard poll would be the most expensive thing this process
    does.
    """
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as fh:
            # ~110 bytes a line, so this over-reads a little on purpose.
            back = min(size, points * 160)
            fh.seek(size - back)
            raw = fh.read().decode("utf-8", "replace")
    except (OSError, ValueError):
        return []

    out = []
    for line in raw.splitlines()[-points:]:
        m = _SAMPLE.match(line.strip())
        if not m:
            continue
        out.append({
            "t": m.group("t"),
            "temp": float(m.group("temp")),
            "load": float(m.group("l1")),
            "mem_used_mb": int(m.group("mu")),
            "mem_total_mb": int(m.group("mt")),
            "swap_used_mb": int(m.group("su")),
            "throttled": m.group("thr") not in ("-", "0"),
            "containers": int(m.group("c")),
        })
    return out


# ── Docker ──────────────────────────────────────────────────────────────────

def docker_df():
    """Image, container, volume and build-cache totals, and what is reclaimable.

    Reclaimable is the number worth surfacing: it is disk you can have back
    without deleting anything you use.
    """
    rc, out = _run(["docker", "system", "df", "--format", "{{json .}}"], timeout=40)
    if rc != 0:
        return None
    rows = {}
    for line in out.splitlines():
        try:
            d = json.loads(line)
        except ValueError:
            continue
        kind = (d.get("Type") or "").lower().replace(" ", "_")
        if not kind:
            continue
        rows[kind] = {
            "count": _int(d.get("TotalCount")),
            "active": _int(d.get("Active")),
            "size": d.get("Size", ""),
            "reclaimable": d.get("Reclaimable", ""),
            "size_b": _size_to_bytes(d.get("Size")),
            "reclaimable_b": _size_to_bytes(d.get("Reclaimable")),
        }
    return rows or None


# The cleanup policy, and the one place it is written down. It has to match
# `cmd_cleanup` in corex-manage.sh, because the whole point of this function
# is that the number the dashboard offers is the number the button delivers.
#
# There is no age limit on images, and that is deliberate rather than an
# oversight. `--filter until=168h` was measured on this hardware and excluded
# exactly the images that should have been removed: with the containerd image
# store, an unused 212-day-old image was absent from
# `docker image ls --filter until=168h`, so the filtered prune reclaimed 0B
# while the unfiltered one reclaimed 771MB. The safety the filter was supposed
# to add is already there without it, because `-a` only removes an image that
# no container references at all, stopped containers included: a disabled
# service keeps its image, and a removed one does not.
PURGE_CACHE_AGE_H = 72    # 3 days, and buildx does honour this one


def _parse_docker_time(text):
    """Docker prints times three ways. Return epoch seconds, or None.

    `docker image ls` gives "2026-09-05 00:58:48 +0530 IST" and `buildx du`
    gives "2026-09-03 07:23:22.935347418 +0000 UTC": an optional fractional
    second and a trailing zone abbreviation that %z will not take.
    """
    if not text:
        return None
    parts = str(text).split()
    if len(parts) < 3:
        return None
    stamp = " ".join(parts[:3])          # date, time, numeric offset
    stamp = re.sub(r"\.\d+", "", stamp, count=1)
    try:
        return datetime.datetime.strptime(stamp, "%Y-%m-%d %H:%M:%S %z").timestamp()
    except ValueError:
        return None


def docker_purgeable(df=None):
    """What a cleanup will actually remove, and what its age limit holds back.

    `docker system df` reports everything unused with no notion of age, and
    `corex manage cleanup` will not touch build cache younger than three days.
    On a box that builds its own dashboard image those two numbers disagree
    completely: 3.7GB reported unused, 0B removable, because every byte of the
    cache was made yesterday. Offering the first number as a button is the
    bug, and it is why clicking it appeared to do nothing.

    So this returns the second number, plus what is being held back and when
    the oldest of it comes due, and the dashboard can say "809MB now, 2.9GB in
    28 hours" rather than promising 3.7GB and delivering none of it.
    """
    now = time.time()
    out = {
        "images_b": 0,
        "cache_b": 0, "cache_held_b": 0,
        "total_b": 0, "held_b": 0,
        "next_due_h": None,
        "cache_age_h": PURGE_CACHE_AGE_H,
    }

    # Images come from `docker system df`, which is the same source the rest
    # of the Storage tab reads and the only one that accounts for layers
    # shared between images. Summing `Size` over `docker image ls` instead
    # counts a shared base layer once per image that uses it: it made 771MB of
    # real reclaimable space read as 809MB here and 1.97GB elsewhere.
    rows = df if df is not None else docker_df()
    if rows:
        out["images_b"] = (rows.get("images") or {}).get("reclaimable_b", 0)

    # Build cache. `Reclaimable` is buildkit's own answer to "is anything
    # using this", so the age limit is the only thing left to apply.
    rc, text = _run(["docker", "buildx", "du", "--format", "json"], timeout=60)
    soonest = None
    if rc == 0:
        for line in text.splitlines():
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if not d.get("Reclaimable"):
                continue
            size = _size_to_bytes(d.get("Size"))
            made = _parse_docker_time(d.get("CreatedAt"))
            age_h = (now - made) / 3600 if made else PURGE_CACHE_AGE_H + 1
            if age_h >= PURGE_CACHE_AGE_H:
                out["cache_b"] += size
            else:
                out["cache_held_b"] += size
                due = PURGE_CACHE_AGE_H - age_h
                soonest = due if soonest is None else min(soonest, due)

    out["total_b"] = out["images_b"] + out["cache_b"]
    out["held_b"] = out["cache_held_b"]
    if soonest is not None and out["held_b"] > 0:
        out["next_due_h"] = round(soonest, 1)
    return out


_UNITS = {"b": 1, "kb": 10**3, "mb": 10**6, "gb": 10**9, "tb": 10**12,
          "kib": 1024, "mib": 1024**2, "gib": 1024**3, "tib": 1024**4}


def _size_to_bytes(text):
    """Docker prints "34.55GB" and "576.5MB (1%)". Both have to parse."""
    if not text:
        return 0
    m = re.match(r"\s*([0-9.]+)\s*([A-Za-z]+)", str(text))
    if not m:
        return 0
    try:
        return int(float(m.group(1)) * _UNITS.get(m.group(2).lower(), 1))
    except (ValueError, TypeError):
        return 0


def _int(v):
    try:
        return int(v)
    except (TypeError, ValueError):
        return 0


# ── Per-service disk use, cached because du is slow ─────────────────────────

_sizes = {"at": 0.0, "rows": [], "running": False}
_sizes_lock = threading.Lock()
SIZES_TTL = 900


def service_sizes(refresh=False):
    """Bytes per service directory, recomputed at most every 15 minutes.

    `du` over a photo library is tens of seconds of disk, which is far too
    slow for a dashboard poll, so a stale answer is served while a fresh one
    is computed in the background. The first call returns nothing and the
    panel says so, rather than blocking the whole page on it.
    """
    with _sizes_lock:
        fresh = _sizes["at"] > 0 and time.monotonic() - _sizes["at"] < SIZES_TTL
        if fresh and not refresh:
            return _sizes["rows"]
        if _sizes["running"]:
            return _sizes["rows"]
        _sizes["running"] = True
    try:
        threading.Thread(target=_compute_sizes, daemon=True).start()
    except RuntimeError:
        with _sizes_lock:
            _sizes["running"] = False
    return _sizes["rows"]


def _compute_sizes():
    rows = []
    base = os.path.join(DATA_ROOT, "service-data")
    try:
        names = sorted(os.listdir(base))
        for name in names:
            path = os.path.join(base, name)
            if not os.path.isdir(path):
                continue
            rc, out = _run(["du", "-sb", path], timeout=120)
            if rc != 0:
                continue
            try:
                rows.append({"name": name, "bytes": int(out.split()[0])})
            except (ValueError, IndexError):
                continue
        rows.sort(key=lambda r: -r["bytes"])
        with _sizes_lock:
            _sizes["rows"] = rows
            _sizes["at"] = time.monotonic()
    except OSError:
        # Keep the last successful result when the data disk is unavailable.
        pass
    finally:
        # An unexpected failure must not permanently disable future scans.
        with _sizes_lock:
            _sizes["running"] = False


# ── Watchdog, thermal, Kuma ─────────────────────────────────────────────────

_WD = re.compile(r"^(?P<t>\S+) watchdog: (?P<body>.*)$")


def watchdog_findings(limit=25, path=WATCHDOG_LOG):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            lines = deque(fh, maxlen=400)
    except OSError:
        return []
    out = []
    for line in reversed(lines):
        m = _WD.match(line.strip())
        if not m:
            continue
        body = m.group("body")
        level = "down" if " DOWN" in body else ("up" if " UP" in body else "info")
        out.append({"t": m.group("t"), "level": level, "text": body})
        if len(out) >= limit:
            break
    return out


def thermal_state():
    conf = {}
    try:
        with open(THERMAL_CONF, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, _, v = line.partition("=")
                    conf[k.strip()] = v.strip().strip("\"'")
    except OSError:
        pass
    shed = []
    try:
        with open(THERMAL_SHED, encoding="utf-8") as fh:
            shed = [l.strip() for l in fh if l.strip()]
    except OSError:
        pass
    return {
        "enabled": conf.get("THERMAL_ENABLED", "true").lower() != "false",
        "warn_c": _float(conf.get("THERMAL_WARN_C")),
        "shed_c": _float(conf.get("THERMAL_SHED_C")),
        "emergency_c": _float(conf.get("THERMAL_EMERGENCY_C")),
        "shed": shed,
    }


def _float(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def kuma_monitors(db_path=KUMA_DB, limit=40):
    """Monitor names and their latest heartbeat.

    Deliberately never reads the `notification` table: that is where the
    Telegram bot token lives, and this answer is rendered by a web-facing
    container.
    """
    if not os.path.exists(db_path):
        return []
    try:
        db = sqlite3.connect("file:%s?mode=ro" % db_path, uri=True, timeout=5)
    except sqlite3.Error:
        return []
    try:
        db.row_factory = sqlite3.Row
        rows = db.execute(
            "SELECT m.id, m.name, m.active, m.type,"
            "       h.status, h.time, h.msg, h.ping"
            "  FROM monitor m"
            "  LEFT JOIN heartbeat h ON h.id = ("
            "       SELECT id FROM heartbeat WHERE monitor_id = m.id"
            "        ORDER BY time DESC LIMIT 1)"
            " ORDER BY m.name LIMIT ?", (limit,)).fetchall()
    except sqlite3.Error:
        return []
    finally:
        db.close()

    # Kuma's status codes: 0 down, 1 up, 2 pending, 3 maintenance.
    names = {0: "down", 1: "up", 2: "pending", 3: "maintenance"}
    out = []
    for r in rows:
        out.append({
            "name": r["name"],
            "active": bool(r["active"]),
            "type": r["type"],
            "status": names.get(r["status"], "unknown"),
            "last_check": r["time"],
            "message": (r["msg"] or "")[:160],
            "ping_ms": r["ping"],
        })
    return out


# ── SMART and dpkg, the two that predict a bad morning ──────────────────────

def smart():
    out = []
    rc, listing = _run(["lsblk", "-dno", "NAME,TYPE"], timeout=15)
    devs = []
    for line in listing.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1] == "disk":
            devs.append("/dev/" + parts[0])
    for dev in devs:
        rc, text = _run(["smartctl", "-H", dev], timeout=25)
        verdict = "unknown"
        m = re.search(r"(?:overall-health self-assessment test result|SMART Health Status):\s*(\S+)",
                      text)
        if m:
            verdict = m.group(1)
        elif "Unknown USB bridge" in text or "Unsupported" in text:
            # A USB-attached SSD often will not pass SMART through its bridge.
            verdict = "not reported"
        out.append({"device": dev, "status": verdict})
    return out


def dpkg_clean():
    """Whether dpkg has half-configured packages.

    An unattended kernel upgrade interrupted by a thermal trip leaves systemd
    and libc unpacked but unconfigured, and every later boot re-breaks it
    (gotcha #18).
    """
    rc, out = _run(["dpkg", "-l"], timeout=30)
    if rc != 0:
        return None
    bad = [l.split()[1] for l in out.splitlines()
           if l[:2] in ("iF", "iU", "rU", "hU", "iH")]
    return {"clean": not bad, "packages": bad[:10]}


MAINT_STATE = "/var/lib/corex/maintenance.json"
MAINT_CONF = "/etc/corex/maintenance.conf"

# task -> how it reads on the page. The runner knows the same four names, so a
# task added there without a row here appears with its own name rather than
# disappearing.
MAINT_TASKS = [
    ("backup", "Backup",
     "A Restic snapshot of every service's data and compose file, then prune "
     "and a five percent read check."),
    ("cleanup", "Docker cleanup",
     "Removes images and build cache nothing is using. This is the disk that "
     "fills first, because Docker lives on it."),
    ("timemachine", "Time Machine check",
     "Confirms the share is being written to and the container is not "
     "restart-looping, which no HTTP check can see."),
    ("os-upgrade", "OS packages",
     "A supervised apt upgrade, including the kernel packages "
     "unattended-upgrades is told to leave alone. Off unless turned on."),
]


def maintenance():
    """The schedule and what each task last actually did.

    Two files, deliberately. The schedule says what is meant to happen and the
    history says what happened, and a page that shows only the first is the
    failure this module was written to avoid: it would report a backup as
    scheduled on a box whose repository does not exist.
    """
    conf = {}
    try:
        with open(MAINT_CONF, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                conf[k.strip()] = v.strip().strip("\"'")
    except OSError:
        pass

    history = {}
    try:
        with open(MAINT_STATE, encoding="utf-8", errors="replace") as fh:
            history = json.load(fh).get("tasks", {}) or {}
    except (OSError, ValueError, AttributeError):
        history = {}

    rc, _ = _run(["systemctl", "is-active", "--quiet", "corex-maintenance.timer"])
    installed = os.path.exists("/usr/local/bin/corex-maintenance.sh")
    enabled = conf.get("MAINTENANCE_ENABLED", "true") != "false"

    tasks = []
    for name, label, desc in MAINT_TASKS:
        key = name.upper().replace("-", "_")
        row = history.get(name) or {}
        try:
            interval = int(conf.get("MAINTENANCE_%s_INTERVAL_H" % key, 0) or 0)
        except ValueError:
            interval = 0
        try:
            hour = int(conf.get("MAINTENANCE_%s_HOUR" % key, 0) or 0)
        except ValueError:
            hour = 0
        last = int(row.get("last", 0) or 0)
        tasks.append({
            "name": name,
            "label": label,
            "description": desc,
            "enabled": conf.get("MAINTENANCE_%s_ENABLED" % key, "false") == "true",
            "interval_h": interval,
            "hour": hour,
            "last": last,
            "next": last + interval * 3600 if last and interval else 0,
            # "" when it has never run, which the page has to say plainly
            # rather than showing a green tick for a task that has never
            # happened.
            "state": str(row.get("state", "") or ""),
            "elapsed": int(row.get("elapsed", 0) or 0),
            "detail": str(row.get("detail", "") or ""),
            # A refusal to start is not a run and does not reset the clock, so
            # it is reported on its own. Newer than "last" means the last
            # thing that happened to this task was being declined.
            "deferred_at": int(row.get("deferred_at", 0) or 0),
            "deferred_detail": str(row.get("deferred_detail", "") or ""),
        })

    return {
        "installed": installed,
        "timer_active": rc == 0,
        "enabled": enabled,
        "tasks": tasks,
    }


_WOL_CACHE = {"at": 0.0, "value": []}
_WOL_TTL = 600


def wake_on_lan():
    """Which interface would answer a magic packet, and whether it is armed.

    Read here so the dashboard can be honest about the way back on. Powering
    the machine off from a web page that runs on that machine is only
    reasonable if the operator can see what will start it again, and the answer
    is not something CoreX can provide on its own: the packet has to come from
    another device, or the power has to be cut and restored at the plug.

    Needs root, which is why it lives on this side rather than in the
    container. "d" means disabled, "g" means a magic packet wakes it.
    """
    # Cached for ten minutes. This only changes when someone runs ethtool or
    # reboots, and the vitals stream asks for metrics every five seconds: a
    # subprocess per interface on that path would be pure waste.
    now = time.time()
    if now - _WOL_CACHE["at"] < _WOL_TTL:
        return _WOL_CACHE["value"]
    try:
        names = sorted(os.listdir("/sys/class/net"))
    except OSError:
        return []
    out = []
    for name in names:
        if name == "lo" or name.startswith(("docker", "br-", "veth", "tun")):
            continue
        rc, text = _run(["ethtool", name], timeout=10)
        if rc != 0:
            continue
        supports = current = ""
        for line in text.splitlines():
            line = line.strip()
            if line.startswith("Supports Wake-on:"):
                supports = line.split(":", 1)[1].strip()
            elif line.startswith("Wake-on:"):
                current = line.split(":", 1)[1].strip()
        if not supports:
            continue
        out.append({
            "interface": name,
            "supported": "g" in supports,
            "enabled": "g" in current,
            "modes": current,
        })
    _WOL_CACHE["at"], _WOL_CACHE["value"] = now, out
    return out


# ── Assembly ────────────────────────────────────────────────────────────────

def collect(want_sizes=True):
    temp, temp_src = cpu_temp()
    mem = meminfo() or {}
    try:
        load = list(os.getloadavg())
    except OSError:
        load = []
    thermal = thermal_state()

    state = "unknown"
    if temp is not None:
        warn = thermal.get("warn_c") or 80.0
        shed = thermal.get("shed_c") or 88.0
        state = "hot" if temp >= shed else "warn" if temp >= warn else "ok"

    if not want_sizes:
        # The stream consumes only these fields. Avoid reading log history,
        # SQLite, SMART and maintenance state on every live temperature tick.
        return {
            "at": int(time.time()),
            "cpu": {"temp_c": temp, "temp_source": temp_src, "temp_state": state,
                    "load": load, "cores": os.cpu_count()},
            "memory": mem,
            "docker": None, "purgeable": None,
        }

    # Read once and handed to both, because `docker system df` walks every
    # image and container and the two callers want the same answer anyway.
    # The vitals stream consumes CPU and memory only. Storage accounting can
    # take longer than its entire request deadline and must stay off this path.
    _df = docker_df() if want_sizes else None

    return {
        "at": int(time.time()),
        "cpu": {
            "temp_c": temp, "temp_source": temp_src, "temp_state": state,
            "load": load, "cores": os.cpu_count(),
        },
        "memory": mem,
        "uptime_s": uptime_seconds(),
        "disks": disks(),
        "storage": storage_layout() if want_sizes else None,
        "docker": _df,
        "purgeable": docker_purgeable(_df) if want_sizes else None,
        "service_sizes": service_sizes() if want_sizes else [],
        "series": series(),
        "watchdog": watchdog_findings(),
        "thermal": thermal,
        "monitors": kuma_monitors(),
        "smart": smart(),
        "dpkg": dpkg_clean(),
        "wol": wake_on_lan(),
        "maintenance": maintenance(),
        # Behind want_sizes for the same reason the `du` is: the vitals stream
        # asks for metrics every five seconds and neither of these changes on
        # that timescale. The cache is a file read; what is being avoided is
        # arming a background registry sweep from the fast path.
        "updates": cu_updates.updates() if want_sizes else None,
    }
