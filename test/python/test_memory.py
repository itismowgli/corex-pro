import pathlib
import subprocess
import tempfile
import unittest

SOURCE = (pathlib.Path(__file__).resolve().parents[2] / 'lib' / 'watchdog.sh').read_text()


def _extract(name):
    start = SOURCE.index('%s() {' % name)
    return SOURCE[start:SOURCE.index('\n}', start) + 2]


FUNCTIONS = _extract('_mem_stall_pct') + '\n' + _extract('check_memory')

STUBS = '''
push() { printf '%s|%s\\n' "$2" "$3"; }
top_mem() { echo "keeper 1285M, calcom 928M"; }
'''

# The numbers measured on the live box while the old check was alerting: 31.5GB
# of RAM with 25.9GB available, and 592MB of a 2GB swap parked and untouched.
QUIET = '''MemTotal:       32244964 kB
MemAvailable:   26574848 kB
SwapTotal:       2097148 kB
SwapFree:        1489460 kB
'''

TIGHT = QUIET.replace('MemAvailable:   26574848 kB', 'MemAvailable:    2000000 kB')

NO_STALL = 'some avg10=0.00 avg60=0.00 avg300=0.00 total=51281332\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=30203660\n'
STALLING = 'some avg10=41.02 avg60=37.55 avg300=12.00 total=51281332\nfull avg10=9.10 avg60=8.02 avg300=2.00 total=30203660\n'


class MemoryCheckTests(unittest.TestCase):
    def run_check(self, meminfo=QUIET, pressure=NO_STALL):
        with tempfile.TemporaryDirectory() as d:
            mi = pathlib.Path(d) / 'meminfo'
            mi.write_text(meminfo)
            env = 'WATCHDOG_MEMINFO=%s\n' % mi
            if pressure is None:
                env += 'WATCHDOG_PRESSURE_MEM=%s/absent\n' % d
            else:
                psi = pathlib.Path(d) / 'pressure'
                psi.write_text(pressure)
                env += 'WATCHDOG_PRESSURE_MEM=%s\n' % psi
            script = (env + 'WATCHDOG_MEM_AVAIL_PCT=15\nWATCHDOG_SWAP_USED_PCT=25\n'
                      'WATCHDOG_MEM_STALL_PCT=10\n' + STUBS + FUNCTIONS + '\ncheck_memory\n')
            r = subprocess.run(['bash', '-c', script], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            status, _, msg = r.stdout.strip().partition('|')
            return status, msg

    def test_swap_alone_is_not_an_alert(self):
        # 28% of swap in use, plenty of RAM free, nothing stalling. This is the
        # message that fired constantly and meant nothing.
        status, msg = self.run_check()
        self.assertEqual(status, 'up', msg)
        self.assertIn('swap at 28%', msg)
        self.assertNotIn('Swapping heavily', msg)

    def test_a_quiet_box_still_reports_both_numbers(self):
        _, msg = self.run_check()
        self.assertIn('18% used', msg)
        self.assertIn('Nothing is waiting on memory', msg)

    def test_stalling_is_an_alert_even_with_memory_apparently_free(self):
        status, msg = self.run_check(pressure=STALLING)
        self.assertEqual(status, 'down', msg)
        self.assertIn('blocked for 37% of the last minute', msg)
        self.assertIn('keeper', msg)

    def test_low_headroom_is_an_alert_on_its_own(self):
        status, msg = self.run_check(meminfo=TIGHT)
        self.assertEqual(status, 'down', msg)
        self.assertIn('only 6% free', msg)

    def test_swap_is_named_only_beside_a_real_finding(self):
        # Swap is 28% in both, so its presence in the text is what separates
        # corroborating detail from a trigger.
        _, quiet = self.run_check()
        self.assertNotIn('Swap is', quiet)
        _, real = self.run_check(pressure=STALLING)
        self.assertIn('Swap is 28% full as well', real)

    def test_a_kernel_without_psi_falls_back_to_headroom_and_does_not_crash(self):
        status, msg = self.run_check(pressure=None)
        self.assertEqual(status, 'up', msg)
        self.assertNotIn('waiting on memory', msg)
        status, msg = self.run_check(meminfo=TIGHT, pressure=None)
        self.assertEqual(status, 'down', msg)

    def test_a_box_with_no_swap_at_all_reports_zero_rather_than_dividing_by_it(self):
        none = QUIET.replace('SwapTotal:       2097148 kB', 'SwapTotal:             0 kB') \
                    .replace('SwapFree:        1489460 kB', 'SwapFree:              0 kB')
        status, msg = self.run_check(meminfo=none)
        self.assertEqual(status, 'up', msg)
        self.assertIn('swap at 0%', msg)


if __name__ == '__main__':
    unittest.main()
