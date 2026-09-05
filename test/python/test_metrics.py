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
