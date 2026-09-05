import os
import pathlib
import subprocess
import shutil
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
STUBS = '''
docker() { return 0; }
chown() { :; }
state_service_installed() { :; }
state_service_removed() { :; }
log_info() { :; }
log_success() { :; }
log_warning() { :; }
'''


class ServiceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = pathlib.Path(self.temp.name)
        self.env = dict(os.environ, DOCKER_ROOT=str(self.base/'compose'), DATA_ROOT=str(self.base/'data'),
                        DOMAIN='example.com', SERVER_IP='192.168.1.10', TIMEZONE='UTC')

    def tearDown(self):
        self.temp.cleanup()

    def run_service(self, name, script):
        return subprocess.run(['bash', '-u', '-c', STUBS + '\nsource "$1/lib/services/$2.sh"\n' + script,
                               '_', str(ROOT), name], env=self.env, text=True, capture_output=True)

    def validate_compose(self, service):
        if shutil.which('docker'):
            check = subprocess.run(['docker', 'compose', '-f', str(self.base / f'compose/{service}/docker-compose.yml'), 'config', '--quiet'], capture_output=True, text=True)
            self.assertEqual(check.returncode, 0, check.stderr)

    def test_keeper_generates_private_stable_secrets_and_limited_compose(self):
        for _ in range(2):
            result = self.run_service('keeper', 'keeper_deploy')
            self.assertEqual(result.returncode, 0, result.stderr)
            file = self.base/'compose/keeper/.secrets.env'
            if _ == 0:
                original = file.read_bytes()
            else:
                self.assertEqual(file.read_bytes(), original)
            self.assertEqual(file.stat().st_mode & 0o777, 0o600)
        compose = (self.base/'compose/keeper/docker-compose.yml').read_text()
        self.validate_compose('keeper')
        self.assertIn('WORKER_CONCURRENCY: "2"', compose)
        self.assertIn('keeper-db:/var/lib/postgresql/data', compose)
        self.assertNotIn('ports:', compose)
        self.assertNotIn(original.decode().splitlines()[0].split('=', 1)[1], compose)
        self.assertIn('"307"', self.run_service('keeper', 'printf "%s" "$SERVICE_MONITORS"').stdout)

    def test_keeper_refuses_replacing_keys_for_existing_data(self):
        db = self.base/'data/keeper-db'
        db.mkdir(parents=True)
        (db/'PG_VERSION').write_text('17')
        self.assertNotEqual(self.run_service('keeper', 'keeper_deploy').returncode, 0)
        self.assertFalse((self.base/'compose/keeper/.secrets.env').exists())

    def test_portainer_cold_preserves_authentication_order(self):
        result = self.run_service('portainer', '''
state_get() { echo true; }
sso_label_for() { printf '      - "traefik.http.routers.portainer.middlewares=corex-lan@file,authelia@docker"'; }
portainer_deploy
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        compose = (self.base/'compose/portainer/docker-compose.yml').read_text()
        self.validate_compose('portainer')
        self.assertIn('middlewares=corex-lan@file,authelia@docker,portainer-cold"', compose)
        self.assertIn('sablier.enable=true', compose)
        self.assertIn('keepAliveInterval=30s', compose)
        self.assertEqual(compose.count('routers.portainer.middlewares='), 1)

    def test_portainer_remains_always_on_without_opt_in(self):
        result = self.run_service('portainer', 'portainer_deploy')
        self.assertEqual(result.returncode, 0, result.stderr)
        compose = (self.base/'compose/portainer/docker-compose.yml').read_text()
        self.assertIn('portainer/portainer-ce:2.45.0', compose)
        self.assertNotIn('portainer/portainer-ce:latest', compose)
        self.assertNotIn('sablier.enable=true', compose)

    def test_portainer_repair_recreates_once(self):
        result = self.run_service('portainer', '''
docker() { printf 'DOCKER %s\\n' "$*"; }
portainer_repair
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [line for line in result.stdout.splitlines() if line.startswith('DOCKER ')]
        self.assertEqual(len(calls), 1, result.stdout)
        self.assertIn('up -d --force-recreate', calls[0])

    def test_sablier_has_no_public_port_and_rejects_unlabelled_requests(self):
        result = self.run_service('sablier', 'sablier_deploy')
        self.assertEqual(result.returncode, 0, result.stderr)
        compose = (self.base/'compose/sablier/docker-compose.yml').read_text()
        self.validate_compose('sablier')
        self.assertNotIn('ports:', compose)
        self.assertIn('--provider.reject-unlabeled-requests=true', compose)
        self.assertIn('/var/run/docker.sock:/var/run/docker.sock', compose)

    def test_cold_rejects_background_services(self):
        result = subprocess.run(['bash', '-u', '-c', 'source "$1/lib/cold.sh"; cold_manage enable keeper', '_', str(ROOT)],
                                env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 2)


if __name__ == '__main__':
    unittest.main()
