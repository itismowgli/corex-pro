#!/usr/bin/env python3
"""corex-io-guard: reboot the machine when its system disk stops answering.

THE FAILURE THIS EXISTS FOR

On 2026-10-27 the NVMe holding the root filesystem stopped completing
requests. The device-mapper volume above it held 22 requests in flight and the
disk itself reported none, with its counters frozen, so the I/O was lost
between the two and never came back. Everything that touched the disk then
waited forever: sudo, ps, docker, an SSH login. The load average climbed past
110 on an idle machine.

Nothing on the box could recover from that, and the reasons are the design:

  * The hardware watchdog never fired. systemd pets it from memory and does
    not need the disk, so PID 1 kept saying "alive" for hours.
  * hung_task_panic is off on purpose (the data disk is USB, and a slow
    backup is not a hang), so the kernel did nothing either.
  * The journal is on the disk that stopped, so nothing was written down.

So this is a daemon, not a timer: a timer starts a new process for every
check, and starting a process needs the disk. Everything it will ever need is
loaded and locked into memory at start, and the only things it reads while
running are sysfs and procfs, which are kernel memory.

WHAT COUNTS AS STUCK

A device with requests in flight whose completion counters have not moved for
IO_GUARD_STALL_SEC. In flight on its own is not enough, a busy disk always has
something in flight, and frozen counters on their own are not enough, an idle
disk completes nothing. Both together, for minutes, is a request that is never
coming back.

WHAT IT DOES

  reboot   tells Telegram, asks the kernel to sync and remount read-only, then
           reboots through /proc/sysrq-trigger, which needs no disk at all
  alert    tells Telegram once per stall and leaves the machine alone

It never acts during the first IO_GUARD_BOOT_GRACE_SEC of a boot, which is
what stops one bad disk turning into a reboot loop.
"""

import ctypes
import json
import os
import re
import signal
import socket
import ssl
import sys
import threading
import time
import urllib.parse
import urllib.request

# Imported up front for the same reason as everything else here: urllib
# encodes a hostname through this codec lazily, and a lazy import during a
# hang is a read from the disk that is not answering.
import encodings.idna  # noqa: F401

CONF = os.environ.get("IO_GUARD_CONF", "/etc/corex/io-guard.conf")
STATUS = os.environ.get("IO_GUARD_STATUS", "/run/corex/io-guard.json")
# The event log lives on the data disk when there is one, beside the blackbox
# log and for the same reason: the system disk is the one this is about.
EVENT_LOGS = tuple(filter(None, [os.environ.get("IO_GUARD_EVENT_LOG")])) or (
    "/mnt/corex-data/io-guard.log", "/var/lib/corex/io-guard.log")
# Overridable so a test instance can run the whole loop against fake counters
# without the ability to reboot anything.
SYSRQ = os.environ.get("IO_GUARD_SYSRQ", "/proc/sysrq-trigger")
SYS_BLOCK = os.environ.get("IO_GUARD_SYS_BLOCK", "/sys/block")
INTERVAL = 5

DEFAULTS = {
    "IO_GUARD_ENABLED": "true",
    "IO_GUARD_ACTION": "reboot",
    "IO_GUARD_STALL_SEC": "120",
    "IO_GUARD_BOOT_GRACE_SEC": "600",
    "IO_GUARD_DEVICES": "auto",
}
LIMITS = {"IO_GUARD_STALL_SEC": (30, 3600), "IO_GUARD_BOOT_GRACE_SEC": (120, 7200)}
DEVICE_RE = re.compile(r"^[a-z][a-z0-9-]{0,31}$")


# ── Configuration ────────────────────────────────────────────────────────────


def parse_conf(text):
    """KEY=VALUE lines into a validated dict. Bad values fall back to defaults."""
    raw = dict(DEFAULTS)
    for line in text.splitlines():
        m = re.match(r"^\s*(IO_GUARD_[A-Z_]+)\s*=\s*\"?([^\"#]*?)\"?\s*(#.*)?$", line)
        if m and m.group(1) in DEFAULTS:
            raw[m.group(1)] = m.group(2).strip()
    cfg = {
        "enabled": raw["IO_GUARD_ENABLED"].lower() in ("true", "yes", "1", "on"),
        "action": raw["IO_GUARD_ACTION"] if raw["IO_GUARD_ACTION"] in ("reboot", "alert") else "reboot",
    }
    for key, name in (("IO_GUARD_STALL_SEC", "stall_sec"), ("IO_GUARD_BOOT_GRACE_SEC", "boot_grace_sec")):
        lo, hi = LIMITS[key]
        try:
            val = int(raw[key])
        except ValueError:
            val = int(DEFAULTS[key])
        cfg[name] = max(lo, min(hi, val))
    devs = raw["IO_GUARD_DEVICES"].split()
    if devs == ["auto"] or not devs or not all(DEVICE_RE.match(d) for d in devs):
        cfg["devices"] = "auto"
    else:
        cfg["devices"] = devs
    return cfg


def read_conf():
    try:
        with open(CONF, encoding="utf-8", errors="replace") as fh:
            return parse_conf(fh.read())
    except OSError:
        return parse_conf("")


# ── Which devices to watch ───────────────────────────────────────────────────


def _block_of_partition(name):
    """nvme0n1p3 -> nvme0n1. A whole disk returns itself."""
    if os.path.isdir(os.path.join(SYS_BLOCK, name)):
        return name
    for disk in os.listdir(SYS_BLOCK):
        if os.path.isdir(os.path.join(SYS_BLOCK, disk, name)):
            return disk
    return name


def _disks_under(name, seen=None):
    """The physical disks a block device sits on, following device-mapper down."""
    seen = seen if seen is not None else set()
    if name in seen:
        return set()
    seen.add(name)
    slaves = os.path.join(SYS_BLOCK, _block_of_partition(name), "slaves")
    try:
        below = os.listdir(slaves)
    except OSError:
        below = []
    if not below:
        return {_block_of_partition(name)}
    out = set()
    for s in below:
        out |= _disks_under(s, seen)
    return out


def root_device():
    """The block device name holding /, e.g. dm-0."""
    with open("/proc/self/mountinfo", encoding="utf-8") as fh:
        for line in fh:
            parts = line.split()
            if len(parts) > 4 and parts[4] == "/":
                major_minor = parts[2]
                for dev in os.listdir(SYS_BLOCK):
                    try:
                        with open(os.path.join(SYS_BLOCK, dev, "dev")) as d:
                            if d.read().strip() == major_minor:
                                return dev
                    except OSError:
                        continue
                    # A partition: look one level down.
                    for sub in os.listdir(os.path.join(SYS_BLOCK, dev)):
                        p = os.path.join(SYS_BLOCK, dev, sub, "dev")
                        try:
                            with open(p) as d:
                                if d.read().strip() == major_minor:
                                    return dev
                        except OSError:
                            continue
    return None


def auto_devices():
    """Every block device on the physical disk that holds /.

    The volume above the disk is what showed the hang (requests in flight,
    nothing completing) while the disk itself reported nothing in flight, so
    the device-mapper volumes have to be watched, not only the disk. Other
    volumes on the same disk go with it: they hang together.
    """
    root = root_device()
    if not root:
        return []
    disks = _disks_under(root)
    watch = set(disks) | {root}
    for dev in os.listdir(SYS_BLOCK):
        if dev.startswith("dm-") and _disks_under(dev) & disks:
            watch.add(dev)
    return sorted(watch)


# ── Detection ────────────────────────────────────────────────────────────────


def read_stat(dev):
    """(completed, in_flight) for one device, or None if it is not there.

    completed sums reads, writes, discards and flushes, whichever this kernel
    reports, so any finished request of any kind counts as progress.
    """
    try:
        with open(os.path.join(SYS_BLOCK, dev, "stat")) as fh:
            f = [int(x) for x in fh.read().split()]
    except (OSError, ValueError):
        return None
    if len(f) < 9:
        return None
    completed = f[0] + f[4] + (f[11] if len(f) > 11 else 0) + (f[15] if len(f) > 15 else 0)
    return completed, f[8]


class Detector:
    """Tracks, per device, how long requests have sat without completing."""

    def __init__(self):
        self.last = {}      # dev -> completed count at the last sample
        self.since = {}     # dev -> time the current stall began

    def sample(self, dev, stat, now):
        """Feed one reading. Returns seconds stalled (0 when not stalled)."""
        if stat is None:
            self.last.pop(dev, None)
            self.since.pop(dev, None)
            return 0
        completed, inflight = stat
        moved = self.last.get(dev) != completed
        self.last[dev] = completed
        if inflight == 0 or moved:
            self.since.pop(dev, None)
            return 0
        start = self.since.setdefault(dev, now)
        return now - start


# ── Acting without the disk ──────────────────────────────────────────────────


def _say(msg):
    """Write to the journal if it is listening, and never wait for it.

    stdout is a pipe into journald. When the system disk hangs, journald
    hangs, the pipe fills, and a blocking write would freeze this process
    exactly when it is needed. So stdout is non-blocking and a full pipe
    loses the line instead.
    """
    try:
        os.write(1, ("%s\n" % msg).encode("utf-8", "replace"))
    except (BlockingIOError, OSError):
        pass


def _in_thread(fn, timeout):
    """Run fn in a daemon thread and stop waiting for it after timeout.

    A thread blocked on a dead disk cannot be killed, but it can be abandoned,
    and a daemon thread does not keep the process alive.
    """
    t = threading.Thread(target=fn, daemon=True)
    t.start()
    t.join(timeout)


def record(event):
    event = dict(event, at=time.strftime("%Y-%m-%dT%H:%M:%S%z"))
    line = json.dumps(event, sort_keys=True) + "\n"

    def write():
        for path in EVENT_LOGS:
            if os.path.isdir(os.path.dirname(path)):
                try:
                    with open(path, "a", encoding="utf-8") as fh:
                        fh.write(line)
                    return
                except OSError:
                    continue
    _in_thread(write, 3)


class Telegram:
    """Credentials and a TLS context, both loaded while the disk still works.

    Building an SSL context reads the CA bundle from disk, so it is built once
    here. The send itself only needs the network, which survives the hang:
    DNS and the web pages were still answering when the disk had stopped.
    """

    def __init__(self):
        self.token, self.chat, self.ctx, self.fmt = "", "", None, None
        try:
            sys.path.insert(0, "/usr/local/lib/corex")
            import corex_common as cc
            self.token, self.chat = cc.telegram_creds()
            self.fmt = cc.message
        except Exception:                                   # noqa: BLE001
            pass
        try:
            self.ctx = ssl.create_default_context()
        except Exception:                                   # noqa: BLE001
            self.ctx = None

    def send(self, kind, headline, body, wait=8):
        if not (self.token and self.chat and self.ctx):
            return
        text = self.fmt(kind, headline, body) if self.fmt else "%s\n\n%s" % (headline, body)
        data = urllib.parse.urlencode({
            "chat_id": self.chat, "text": text,
            "parse_mode": "MarkdownV2" if self.fmt else "",
        }).encode()
        url = "https://api.telegram.org/bot%s/sendMessage" % self.token

        def post():
            try:
                urllib.request.urlopen(url, data=data, timeout=wait, context=self.ctx).close()
            except Exception:                               # noqa: BLE001
                pass
        _in_thread(post, wait + 1)


def reboot(sysrq_fd):
    """Sync, remount read-only, reboot. All three are kernel requests.

    The sync and the remount are queued work that may never finish on a dead
    disk, which is why each is followed by a fixed wait and not a check. They
    save whatever the other disks still have dirty. The reboot does not wait
    for anything.
    """
    for key, pause in ((b"s", 5), (b"u", 3), (b"b", 0)):
        try:
            os.write(sysrq_fd, key)
        except OSError as exc:
            _say("sysrq %s failed: %s" % (key.decode(), exc))
        if pause:
            time.sleep(pause)


# ── Main loop ────────────────────────────────────────────────────────────────


def uptime():
    with open("/proc/uptime") as fh:
        return float(fh.read().split()[0])


def write_status(status):
    os.makedirs(os.path.dirname(STATUS), exist_ok=True)
    tmp = STATUS + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(status, fh)
        os.replace(tmp, STATUS)
    except OSError:
        pass


def main():
    # mlockall locks every mapping in full, so the default 8MB thread stack
    # becomes 8MB of RAM per thread. Nothing here recurses deeply.
    threading.stack_size(512 * 1024)
    try:
        os.set_blocking(1, False)
    except OSError:
        pass
    # MCL_CURRENT | MCL_FUTURE: nothing this process holds can be paged out
    # and read back from the disk that stopped.
    try:
        libc = ctypes.CDLL("libc.so.6", use_errno=True)
        locked = libc.mlockall(3) == 0
    except OSError:
        locked = False

    sysrq_fd = os.open(SYSRQ, os.O_WRONLY)
    tg = Telegram()
    host = socket.gethostname()
    state = {"cfg": read_conf()}
    state["devices"] = (auto_devices() if state["cfg"]["devices"] == "auto"
                        else state["cfg"]["devices"])

    wake = threading.Event()
    # corex-manage sends SIGHUP after a change, so a new setting shows on the
    # dashboard within one cycle instead of up to thirty seconds later.
    signal.signal(signal.SIGHUP, lambda *_: wake.set())

    def reload_loop():
        # Its own thread, because reading the config is a read from the system
        # disk and must never be what the detection loop waits on.
        while True:
            wake.wait(30)
            wake.clear()
            cfg = read_conf()
            devs = auto_devices() if cfg["devices"] == "auto" else cfg["devices"]
            state["cfg"], state["devices"] = cfg, devs

    threading.Thread(target=reload_loop, daemon=True).start()
    _say("watching %s, stall limit %ss, action %s, memory locked: %s" % (
        " ".join(state["devices"]) or "nothing", state["cfg"]["stall_sec"],
        state["cfg"]["action"], locked))
    record({"event": "start", "devices": state["devices"], "action": state["cfg"]["action"],
            "stall_sec": state["cfg"]["stall_sec"], "memory_locked": locked})

    det = Detector()
    alerted = set()
    rebooted_at = None
    while True:
        cfg, devs = state["cfg"], state["devices"]
        now = time.monotonic()
        up = uptime()
        worst_dev, worst = None, 0.0
        per = {}
        for dev in devs:
            stat = read_stat(dev)
            stalled = det.sample(dev, stat, now)
            per[dev] = {"in_flight": stat[1] if stat else None,
                        "stalled_sec": int(stalled), "present": stat is not None}
            if stalled > worst:
                worst_dev, worst = dev, stalled

        in_grace = up < cfg["boot_grace_sec"]
        verdict = "disabled" if not cfg["enabled"] else (
            "stuck" if worst >= cfg["stall_sec"] else
            "stalling" if worst > 0 else "ok")
        write_status({
            "at": int(time.time()), "enabled": cfg["enabled"], "action": cfg["action"],
            "stall_sec": cfg["stall_sec"], "boot_grace_sec": cfg["boot_grace_sec"],
            "devices_setting": cfg["devices"], "devices": per, "state": verdict,
            "in_boot_grace": in_grace, "uptime_sec": int(up), "memory_locked": locked,
        })

        # A reboot that did not happen (sysrq refused, say) must not turn into
        # a Telegram message every five seconds. One attempt per ten minutes.
        retry_ok = rebooted_at is None or now - rebooted_at > 600
        if verdict == "stuck" and not in_grace and retry_ok:
            detail = "%s has had %d requests waiting for %d seconds with none completing" % (
                worst_dev, per[worst_dev]["in_flight"], worst)
            if cfg["action"] == "reboot":
                _say("STUCK: %s, rebooting" % detail)
                record({"event": "reboot", "device": worst_dev, "stalled_sec": int(worst),
                        "in_flight": per[worst_dev]["in_flight"]})
                tg.send("fail", "%s: system disk stopped, restarting" % host,
                        "%s. Nothing that needs the disk can run, so the machine is "
                        "rebooting itself. Expect it back in about three minutes." % detail)
                rebooted_at = time.monotonic()
                reboot(sysrq_fd)
            elif worst_dev not in alerted:
                alerted.add(worst_dev)
                _say("STUCK: %s, alert only" % detail)
                record({"event": "alert", "device": worst_dev, "stalled_sec": int(worst),
                        "in_flight": per[worst_dev]["in_flight"]})
                tg.send("warn", "%s: system disk has stopped answering" % host,
                        "%s. Automatic restart is set to alert only, so it needs a power "
                        "cycle." % detail)
        elif verdict in ("ok", "disabled"):
            alerted.clear()

        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
