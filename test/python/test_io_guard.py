"""corex-io-guard: what counts as a stuck disk, and which disks are watched.

The detection runs against /sys, so it can only ever be exercised live on the
state the box happens to be in, and the state worth testing is the one it is
not in (the same reasoning as test_memory.py). These drive it from fixtures,
including the exact shape of the 2026-10-27 hang: the volume above the disk
with 22 requests in flight and frozen counters, the disk itself reporting none.
"""

import importlib.util
import os
import pathlib
import tempfile
import unittest

SRC = pathlib.Path(__file__).resolve().parents[2] / "agent" / "corex-io-guard.py"


def load(sys_block=None):
    if sys_block:
        os.environ["IO_GUARD_SYS_BLOCK"] = sys_block
    spec = importlib.util.spec_from_file_location("io_guard", SRC)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    os.environ.pop("IO_GUARD_SYS_BLOCK", None)
    return mod


g = load()


class Conf(unittest.TestCase):
    def test_defaults(self):
        c = g.parse_conf("")
        self.assertEqual(c, {"enabled": True, "action": "reboot", "stall_sec": 120,
                             "boot_grace_sec": 600, "devices": "auto"})

    def test_values_and_quotes(self):
        c = g.parse_conf('IO_GUARD_ENABLED=false\nIO_GUARD_ACTION="alert"\n'
                         'IO_GUARD_STALL_SEC=300  # five minutes\nIO_GUARD_DEVICES="dm-0 nvme0n1"\n')
        self.assertFalse(c["enabled"])
        self.assertEqual(c["action"], "alert")
        self.assertEqual(c["stall_sec"], 300)
        self.assertEqual(c["devices"], ["dm-0", "nvme0n1"])

    def test_out_of_range_is_clamped(self):
        # A five second limit would reboot on any slow write. The floor is
        # what stops a typo from turning into a reboot loop.
        self.assertEqual(g.parse_conf("IO_GUARD_STALL_SEC=5")["stall_sec"], 30)
        self.assertEqual(g.parse_conf("IO_GUARD_BOOT_GRACE_SEC=0")["boot_grace_sec"], 120)

    def test_power_cycle_is_an_action(self):
        self.assertEqual(g.parse_conf("IO_GUARD_ACTION=power-cycle")["action"], "power-cycle")

    def test_bad_values_fall_back(self):
        c = g.parse_conf("IO_GUARD_ACTION=format\nIO_GUARD_STALL_SEC=soon\n"
                         "IO_GUARD_DEVICES=../../etc\n")
        self.assertEqual(c["action"], "reboot")
        self.assertEqual(c["stall_sec"], 120)
        self.assertEqual(c["devices"], "auto")


class Detection(unittest.TestCase):
    def test_the_real_hang(self):
        d = g.Detector()
        frozen = (1473238, 22)          # dm-0 on 2026-10-27
        self.assertEqual(d.sample("dm-0", frozen, 0), 0)
        self.assertEqual(d.sample("dm-0", frozen, 5), 0)
        self.assertEqual(d.sample("dm-0", frozen, 65), 60)
        self.assertEqual(d.sample("dm-0", frozen, 125), 120)

    def test_disk_below_the_volume_reports_nothing(self):
        # The disk itself showed 0 in flight, which is why the volume above it
        # has to be watched too: on its own this looks idle.
        d = g.Detector()
        for t in range(0, 300, 5):
            self.assertEqual(d.sample("nvme0n1", (1237317, 0), t), 0)

    def test_a_busy_disk_is_not_stuck(self):
        d = g.Detector()
        for t in range(0, 600, 5):
            self.assertEqual(d.sample("dm-0", (1000 + t, 30), t), 0)

    def test_progress_resets_the_clock(self):
        d = g.Detector()
        d.sample("dm-0", (10, 5), 0)
        d.sample("dm-0", (10, 5), 100)
        self.assertEqual(d.sample("dm-0", (11, 5), 105), 0)
        self.assertEqual(d.sample("dm-0", (11, 5), 110), 0)
        self.assertEqual(d.sample("dm-0", (11, 5), 150), 40)

    def test_a_vanished_device_is_not_stuck(self):
        d = g.Detector()
        d.sample("sdb", (5, 2), 0)
        self.assertEqual(d.sample("sdb", None, 500), 0)

    def test_stat_fields(self):
        with tempfile.TemporaryDirectory() as root:
            os.makedirs(os.path.join(root, "dm-0"))
            # reads 196659, writes 1276579, in flight 22, discards 7, flushes 3
            line = "196659 0 0 0 1276579 0 0 0 22 0 0 7 0 0 0 3 0\n"
            with open(os.path.join(root, "dm-0", "stat"), "w") as fh:
                fh.write(line)
            m = load(root)
            self.assertEqual(m.read_stat("dm-0"), (196659 + 1276579 + 7 + 3, 22))
            self.assertIsNone(m.read_stat("nvme9n9"))


class Devices(unittest.TestCase):
    def test_volumes_follow_down_to_the_disk(self):
        with tempfile.TemporaryDirectory() as root:
            def mk(*p):
                os.makedirs(os.path.join(root, *p), exist_ok=True)
            mk("nvme0n1", "nvme0n1p3")
            mk("dm-0", "slaves", "nvme0n1p3")
            mk("dm-1", "slaves", "nvme0n1p3")
            mk("sda", "sda1")
            m = load(root)
            self.assertEqual(m._disks_under("dm-0"), {"nvme0n1"})
            self.assertEqual(m._disks_under("dm-1"), {"nvme0n1"})
            self.assertEqual(m._disks_under("sda1"), {"sda"})


class PowerCycle(unittest.TestCase):
    """The power-off that hung. On 2026-11-07 and 2026-11-09 the guard asked
    for a power-off on a dead disk and the machine stayed down for days."""

    def run_cycle(self, rtc=True, reboot_type=True):
        with tempfile.TemporaryDirectory() as root:
            paths = {n: os.path.join(root, n) for n in ("sysrq", "rtc", "type")}
            for p in paths.values():
                open(p, "w").close()
            sysrq = os.open(paths["sysrq"], os.O_WRONLY | os.O_APPEND)
            rtc_fd = os.open(paths["rtc"], os.O_WRONLY | os.O_APPEND) if rtc else None
            type_fd = os.open(paths["type"], os.O_WRONLY) if reboot_type else None
            waits = []
            path = g.power_cycle(sysrq, rtc_fd, type_fd, sleep=waits.append)
            for fd in (sysrq, rtc_fd, type_fd):
                if fd is not None:
                    os.close(fd)
            out = {n: pathlib.Path(p).read_text() for n, p in paths.items()}
            return path, out, waits

    def test_a_poweroff_that_never_finishes_becomes_a_cold_reset(self):
        # sleep is faked, so the process is "still running" after the grace:
        # exactly what a power-off stuck in device shutdown looks like.
        path, out, waits = self.run_cycle()
        self.assertEqual(path, "cold-reset")
        self.assertEqual(out["sysrq"], "suob")
        self.assertEqual(out["type"], "pci")
        self.assertIn(g.POWEROFF_GRACE_SEC, waits)

    def test_the_alarm_goes_off_after_the_poweroff_has_had_its_time(self):
        # An alarm that fires while the machine is still shutting down wakes
        # nothing, and the machine then stays off for good.
        self.assertGreater(g.POWER_CYCLE_OFF_SEC, g.POWEROFF_GRACE_SEC + 60)
        _, out, _ = self.run_cycle()
        self.assertEqual(out["rtc"], "0+%d" % g.POWER_CYCLE_OFF_SEC)

    def test_no_alarm_means_a_reboot_and_no_poweroff(self):
        path, out, _ = self.run_cycle(rtc=False)
        self.assertEqual(path, "reboot")
        self.assertNotIn("o", out["sysrq"])

    def test_cold_reset_still_resets_without_the_type_knob(self):
        path, out, _ = self.run_cycle(reboot_type=False)
        self.assertEqual(path, "cold-reset")
        self.assertTrue(out["sysrq"].endswith("b"))


class Returned(unittest.TestCase):
    ACT = '{"at": "2026-11-09T17:30:10+0530", "device": "dm-0", "event": "power-cycle"}'
    START = '{"at": "2026-11-13T08:45:46+0530", "event": "start"}'

    def test_measured_to_now_when_this_is_the_first_start(self):
        now = g._parse_at("2026-11-09T17:36:10")
        ev, gap = g.pending_return([self.ACT], now)
        self.assertEqual((ev["event"], gap), ("power-cycle", 360))
        self.assertLessEqual(gap, g.SELF_RETURN_MAX_SEC)

    def test_an_old_log_is_measured_to_its_own_start_not_to_now(self):
        # The real log: an action, then one start 3.6 days later.
        ev, gap = g.pending_return([self.ACT, self.START], g._parse_at("2026-12-25T00:00:00"))
        self.assertEqual(gap, 314136)
        self.assertGreater(gap, g.SELF_RETURN_MAX_SEC)
        self.assertEqual(g.how_long(gap), "3.6 days")

    def test_reported_once(self):
        done = '{"after_sec": 314136, "at": "2026-11-13T11:00:00+0530", "event": "returned"}'
        self.assertIsNone(g.pending_return([self.ACT, self.START, done, self.START], 0))
        self.assertIsNone(g.pending_return([self.ACT, self.START, self.START], 0))

    def test_nothing_pending_and_garbage_lines(self):
        self.assertIsNone(g.pending_return([self.START, "not json", "[1]", ""], 0))


if __name__ == "__main__":
    unittest.main()
