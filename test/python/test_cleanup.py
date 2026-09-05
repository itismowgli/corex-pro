import pathlib
import subprocess
import unittest

SOURCE = (pathlib.Path(__file__).resolve().parents[2] / 'corex-manage.sh').read_text()
FUNCTION = SOURCE[SOURCE.index('cmd_cleanup() {'):SOURCE.index('\n# ── repair (doctor)')]
# Execute only the function under test; never source the root-only entry point.
STUBS = '''
_cleanup_eligible() { echo '0 0 0 0 0'; }
_human() { echo "$1 B"; }
_reclaimed_from() { echo 0B; }
log_warning() { :; }
log_success() { :; }
docker() { echo "DOCKER $*"; }
journalctl() { echo HOST-COMMAND >&2; return 1; }
apt-get() { echo HOST-COMMAND >&2; return 1; }
find() { echo HOST-COMMAND >&2; return 1; }
du() { echo HOST-COMMAND >&2; return 1; }
'''


class CleanupTests(unittest.TestCase):
    def run_cleanup(self, *args):
        return subprocess.run(['bash', '-c', FUNCTION + STUBS + '\ncmd_cleanup "$@"', 'test', *args],
                              capture_output=True, text=True)

    def test_unknown_option_refuses_cleanup(self):
        result = self.run_cleanup('--dryrun')
        self.assertEqual(result.returncode, 2)
        self.assertIn('Unknown cleanup option', result.stderr)
        self.assertNotIn('DOCKER', result.stdout)

    def test_dry_run_combines_with_docker_only_in_either_order(self):
        for args in (('--dry-run', '--docker-only'), ('--docker-only', '--dry-run')):
            result = self.run_cleanup(*args)
            self.assertEqual(result.returncode, 0)
            self.assertIn('Nothing was changed', result.stdout)
            self.assertNotIn('DOCKER', result.stdout)
            self.assertNotIn('HOST-COMMAND', result.stderr)

    def test_docker_only_does_not_clean_host(self):
        result = self.run_cleanup('--docker-only')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Removing images', result.stdout)
        self.assertNotIn('Vacuuming', result.stdout)
        self.assertNotIn('HOST-COMMAND', result.stderr)


if __name__ == '__main__':
    unittest.main()
