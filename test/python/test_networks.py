import pathlib
import subprocess
import tempfile
import unittest

SOURCE = (pathlib.Path(__file__).resolve().parents[2] / 'corex-manage.sh').read_text()
FUNCTION = SOURCE[SOURCE.index('_check_docker_networks() {'):
                  SOURCE.index('\n}', SOURCE.index('_check_docker_networks() {')) + 2]

# docker is stubbed per-case: PRESENT lists the networks that exist, and the
# stub answers `network inspect` from it. Everything else is a logging shim
# that prints the level, so a test can tell a warning from a note.
STUBS = '''
log_step()    { echo "STEP $1"; }
log_success() { echo "OK $1"; }
log_warning() { echo "WARN $1"; }
log_info()    { echo "INFO $1"; }
docker() {
    [[ "$1 $2" == "network inspect" ]] || return 1
    case " ${PRESENT} " in *" $3 "*) ;; *) return 1 ;; esac
    [[ "${4:-}" == "--format" ]] && echo "one two "
    return 0
}
'''


class NetworkCheckTests(unittest.TestCase):
    def run_check(self, present, composes):
        """composes maps a service name to the networks its compose file names."""
        with tempfile.TemporaryDirectory() as root:
            for svc, nets in composes.items():
                d = pathlib.Path(root) / svc
                d.mkdir()
                body = "services:\n  x:\n    networks: [%s]\n" % ', '.join(nets)
                (d / 'docker-compose.yml').write_text(body)
            script = (
                'COREX_NETWORKS=(proxy-net backend-net monitoring-net ai-net)\n'
                'DOCKER_ROOT=%s\nPRESENT="%s"\n' % (root, present)
                + STUBS + FUNCTION + '\n_check_docker_networks\n'
            )
            return subprocess.run(['bash', '-c', script], capture_output=True, text=True)

    def test_every_network_present_is_reported_with_its_container_count(self):
        r = self.run_check('proxy-net backend-net monitoring-net ai-net', {})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.count('OK '), 4)
        self.assertIn('OK proxy-net: 2 container(s) connected', r.stdout)
        self.assertNotIn('WARN', r.stdout)

    def test_backend_net_is_checked_at_all(self):
        # It was created by the installer and named nowhere else for several
        # releases, so this asserts the one that went missing is covered.
        r = self.run_check('proxy-net backend-net monitoring-net ai-net', {})
        self.assertIn('backend-net', r.stdout)

    def test_a_missing_network_nothing_asks_for_is_not_a_warning(self):
        # The AI stack is uninstalled here, so ai-net is correctly absent.
        r = self.run_check('proxy-net backend-net monitoring-net',
                           {'nextcloud': ['proxy-net', 'backend-net']})
        self.assertIn('INFO ai-net: not present, and no installed service asks for it',
                      r.stdout)
        self.assertNotIn('WARN', r.stdout)

    def test_a_missing_network_a_service_expects_is_a_warning_that_names_it(self):
        r = self.run_check('proxy-net backend-net monitoring-net',
                           {'ollama': ['proxy-net', 'ai-net'],
                            'openwebui': ['proxy-net', 'ai-net'],
                            'nextcloud': ['proxy-net', 'backend-net']})
        self.assertIn('WARN ai-net: missing, and these services expect it', r.stdout)
        self.assertIn('ollama', r.stdout)
        self.assertIn('openwebui', r.stdout)
        # Naming a service that does not use the network sends the reader to
        # the wrong place, which is worse than naming none.
        line = [x for x in r.stdout.splitlines() if x.startswith('WARN ai-net')][0]
        self.assertNotIn('nextcloud', line)
        self.assertIn('docker network create ai-net', r.stdout)

    def test_no_compose_files_at_all_does_not_crash_or_warn(self):
        # A fresh box, or one whose data mount is not there yet. The glob
        # matches nothing and must not be read as a literal path.
        r = self.run_check('proxy-net', {})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.count('WARN'), 0)
        self.assertEqual(r.stdout.count('INFO'), 3)


if __name__ == '__main__':
    unittest.main()
