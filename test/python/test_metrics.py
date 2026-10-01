import importlib
import pathlib
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / 'agent'))
metrics = importlib.import_module('corex_metrics')


class MetricsTests(unittest.TestCase):
    def setUp(self):
        self.old_sizes = metrics._sizes.copy()

    def tearDown(self):
        metrics._sizes.update(self.old_sizes)

    def test_first_scan_starts_even_just_after_boot(self):
        metrics._sizes.update(at=0, rows=[], running=False)
        with patch.object(metrics.time, 'monotonic', return_value=10), patch.object(metrics.threading, 'Thread') as thread:
            metrics.service_sizes()
        thread.return_value.start.assert_called_once()

    def test_thread_start_failure_allows_retry(self):
        metrics._sizes.update(at=0, rows=[], running=False)
        with patch.object(metrics.threading, 'Thread') as thread:
            thread.return_value.start.side_effect = RuntimeError('no threads')
            metrics.service_sizes()
        self.assertFalse(metrics._sizes['running'])

    def test_failed_scan_preserves_previous_result_and_releases_worker(self):
        metrics._sizes.update(rows=[{'name': 'photos', 'bytes': 123}], running=True)
        with patch.object(metrics.os, 'listdir', side_effect=OSError('disk offline')):
            metrics._compute_sizes()
        self.assertEqual(metrics._sizes['rows'], [{'name': 'photos', 'bytes': 123}])
        self.assertFalse(metrics._sizes['running'])

    def test_unexpected_failure_releases_worker(self):
        metrics._sizes['running'] = True
        with patch.object(metrics.os, 'listdir', side_effect=RuntimeError('collector failed')):
            with self.assertRaises(RuntimeError):
                metrics._compute_sizes()
        self.assertFalse(metrics._sizes['running'])

    def test_sizes_sorted_and_invalid_output_ignored(self):
        with tempfile.TemporaryDirectory() as base:
            for name in ('small', 'large', 'bad'):
                pathlib.Path(base, 'service-data', name).mkdir(parents=True)
            def run(argv, **kwargs):
                return 0, {'small': '10\tx', 'large': '50\tx', 'bad': 'invalid'}[pathlib.Path(argv[-1]).name]
            with patch.object(metrics, 'DATA_ROOT', base), patch.object(metrics, '_run', side_effect=run):
                metrics._compute_sizes()
        self.assertEqual([r['bytes'] for r in metrics._sizes['rows']], [50, 10])

    def test_vitals_does_not_run_storage_accounting(self):
        from contextlib import ExitStack
        with ExitStack() as stack:
            for name in ('meminfo', 'thermal_state', 'disks', 'series', 'watchdog_findings',
                         'kuma_monitors', 'smart', 'dpkg_clean', 'wake_on_lan', 'maintenance', 'uptime_seconds'):
                stack.enter_context(patch.object(metrics, name, return_value={}))
            stack.enter_context(patch.object(metrics, 'cpu_temp', return_value=(None, 'none')))
            df = stack.enter_context(patch.object(metrics, 'docker_df'))
            purge = stack.enter_context(patch.object(metrics, 'docker_purgeable'))
            sizes = stack.enter_context(patch.object(metrics, 'service_sizes'))
            result = metrics.collect(want_sizes=False)
        df.assert_not_called()
        purge.assert_not_called()
        sizes.assert_not_called()
        self.assertIsNone(result['docker'])
        self.assertIsNone(result['purgeable'])


if __name__ == '__main__':
    unittest.main()


class MaintenanceDiscoveryTest(unittest.TestCase):
    """A task added to the runner has to appear on the page.

    The agent used to enumerate a hardcoded list while a comment above it
    claimed the opposite, so `updates` ran on a schedule for a whole release
    and the page showed four tasks with no sign of a fifth. The names now come
    from the config the runner writes.
    """

    def _conf(self, names):
        conf = {"MAINTENANCE_ENABLED": "true"}
        for n in names:
            key = n.upper().replace("-", "_")
            conf["MAINTENANCE_%s_ENABLED" % key] = "true"
            conf["MAINTENANCE_%s_INTERVAL_H" % key] = "24"
            conf["MAINTENANCE_%s_HOUR" % key] = "3"
        return conf

    def test_names_come_from_the_config_not_a_list(self):
        import re
        conf = self._conf(["backup", "updates", "os-upgrade", "brand-new"])
        found = set()
        for k in conf:
            m = re.match(r"^MAINTENANCE_([A-Z0-9_]+)_INTERVAL_H$", k)
            if m:
                found.add(m.group(1).lower().replace("_", "-"))
        # Including one the agent has no wording for at all.
        self.assertIn("brand-new", found)
        self.assertIn("updates", found)
        # The underscore-to-hyphen mapping has to survive the round trip, or
        # os-upgrade comes back as os_upgrade and matches no history row.
        self.assertIn("os-upgrade", found)

    def test_every_worded_task_is_one_the_runner_defines(self):
        import re
        # The other direction: wording for a task the runner does not have is
        # a row that can never appear, which is how a list goes stale unseen.
        import pathlib
        runner = (pathlib.Path(__file__).resolve().parents[2]
                  / "lib" / "maintenance.sh").read_text()
        import corex_metrics as cm
        # Only the task names out of the runner's array, so a failure names
        # the task rather than printing the whole file back at the reader.
        defined = set(re.findall(r'^\s*"([a-z0-9-]+)\|', runner, re.M))
        worded = {t[0] for t in cm.MAINT_TASKS}
        self.assertEqual(
            worded - defined, set(),
            "worded in the agent but not defined in the runner")


class NoSecondTaskListTest(unittest.TestCase):
    """Only the runner may enumerate the maintenance tasks.

    There were three copies: the agent's run allowlist, the dashboard's 404
    guard, and the reporter's wording. `updates` was added to the runner and
    to none of them, so it ran on schedule, then appeared on the page once the
    reporter was fixed, and Run now still answered "no such maintenance task"
    from the two nobody had thought of.
    """

    ROOT = pathlib.Path(__file__).resolve().parents[2]

    def test_the_agent_reads_the_config_rather_than_listing_tasks(self):
        src = (self.ROOT / "agent" / "corex-agent.py").read_text()
        self.assertIn("MAINTENANCE_", src,
                      "the agent must derive the task names from the runner's config")
        # The old shape: a literal tuple or list of the four original names.
        self.assertNotRegex(
            src, r'MAINT_TASKS\s*=\s*[\(\[]\s*"backup"',
            "the agent is enumerating tasks again")

    def test_the_dashboard_does_not_keep_its_own_task_list(self):
        src = (self.ROOT / "dashboard" / "main.go").read_text()
        self.assertNotRegex(
            src, r'maintenanceTasks\s*=\s*map\[string\]bool',
            "the dashboard is enumerating tasks again")
        # The elevation policy is a different thing and must stay: it says
        # what is dangerous, not what exists.
        self.assertIn("maintenanceNeedsElevation", src)
        self.assertIn('"os-upgrade": true', src)

    def test_every_runner_task_has_an_interval_so_it_can_be_discovered(self):
        # Discovery keys on MAINTENANCE_<KEY>_INTERVAL_H, so a task defined
        # without an interval would be invisible to both the page and the
        # run path.
        runner = (self.ROOT / "lib" / "maintenance.sh").read_text()
        import re
        rows = re.findall(r'^\s*"([a-z0-9-]+)\|[^"]*"', runner, re.M)
        self.assertGreaterEqual(len(rows), 5, rows)
        self.assertIn("updates", rows)
        for name in rows:
            self.assertRegex(runner, r'MAINTENANCE_\$\{key\}_INTERVAL_H|INTERVAL_H=\$\{interval\}',
                             "no interval is written for %s" % name)
