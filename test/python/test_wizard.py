import pathlib
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class WizardTests(unittest.TestCase):
    def bash(self, script, data=''):
        return subprocess.run(['bash', '-u', '-c', 'source "$1/lib/wizard.sh"\n' + script, '_', str(ROOT)],
                              input=data, capture_output=True, text=True, timeout=30)

    def test_invalid_menu_retries_without_arithmetic_evaluation(self):
        r = self.bash('_menu t p first One second Two', 'oops\n0\n99\n2\n')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), 'second')

    def test_eof_cancels_instead_of_looping_or_selecting_default(self):
        for command in ('_inputbox t p default', '_menu t p a A', '_checklist t p a A ON'):
            self.assertNotEqual(self.bash(command).returncode, 0)

    def test_checklist_enter_keeps_marked_defaults(self):
        r = self.bash('_checklist t p a A ON b B OFF c C ON', '\n')
        self.assertEqual(r.stdout.strip(), '"a" "c"')

    def test_checklist_rejects_bad_indexes(self):
        r = self.bash('_checklist t p a A ON b B OFF', 'x\n0\n3\n2\n')
        self.assertEqual(r.stdout.strip(), '"b"')

    def test_validation(self):
        for fn, good, bad in (
            ('validate_ip', ['192.168.001.008', '10.0.0.1'], ['10.0.0.256', '1.2.3.4.', '1.2.3']),
            ('validate_domain', ['my-home.example.com'], ['a..com', 'a.-b.com', 'a.b-.com']),
            ('validate_port', ['2222', '65535'], ['0', '65536', 'oops']),
        ):
            for value in good:
                self.assertEqual(self.bash(f'{fn} {value}').returncode, 0, value)
            for value in bad:
                self.assertNotEqual(self.bash(f'{fn} {value}').returncode, 0, value)

    def test_service_selection_survives_wizard_return(self):
        r = self.bash('''
_has_whiptail() { return 0; }
whiptail() { return 0; }
_msgbox() { :; }
_wizard_smtp() { :; }
_menu() {
    case "$1" in
        'Installation Mode') echo local-only ;;
        'Service Selection') echo minimal ;;
    esac
}
_inputbox() {
    case "$1" in
        'Server IP Address') echo 192.168.1.10 ;;
        'SSH Port') echo 2222 ;;
        *) echo UTC ;;
    esac
}
main() {
    local -a SELECTED_SERVICES=()
    run_wizard >/dev/null || return 1
    printf '%s\\n' "${SELECTED_SERVICES[@]}"
}
main
''')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('portainer', r.stdout.splitlines())
        self.assertIn('traefik', r.stdout.splitlines())

    def test_internal_services_are_not_offered_by_full_profile(self):
        r = self.bash('apply_profile full; printf "%s\\n" "${SELECTED_SERVICES[@]}"')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('keeper', r.stdout.splitlines())
        self.assertNotIn('sablier', r.stdout.splitlines())


if __name__ == '__main__':
    unittest.main()
