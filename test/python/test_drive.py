import pathlib
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class DriveTests(unittest.TestCase):
    def bash(self, script, data=''):
        return subprocess.run(['bash', '-u', '-c', 'source "$1/lib/drive.sh"\n' + script, '_', str(ROOT)],
                              input=data, capture_output=True, text=True, timeout=5)

    def test_partition_names_cover_sata_nvme_and_mmc(self):
        r = self.bash('_drive_partition_path /dev/sda 1; _drive_partition_path /dev/nvme1n1 1; _drive_partition_path /dev/mmcblk0 2')
        self.assertEqual(r.stdout.splitlines(), ['/dev/sda1', '/dev/nvme1n1p1', '/dev/mmcblk0p2'])

    def test_cancel_before_format_does_not_stop_or_touch_disks(self):
        # Every privileged command is mocked. Validation is tested separately
        # on Linux before deployment; this checks the confirmation boundary.
        r = self.bash('''
_drive_validate_target() { return 0; }
lsblk() { :; }
findmnt() { :; }
blkid() { :; }
parted() { echo MUTATION; return 1; }
partprobe() { echo MUTATION; return 1; }
wipefs() { echo MUTATION; return 1; }
mkfs.ext4() { echo MUTATION; return 1; }
udevadm() { echo MUTATION; return 1; }
tac() { :; }
systemctl() { echo MUTATION; return 1; }
phase1_drive
''', 'sda\nn\nCANCEL\n')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('Cancelled. Nothing changed.', r.stdout)
        self.assertNotIn('MUTATION', r.stdout)

    def test_reuse_unknown_labels_does_not_format_or_relabel(self):
        r = self.bash('''
_drive_validate_target() { return 0; }
lsblk() { echo /dev/sda1; }
findmnt() { :; }
blkid() { echo UNKNOWN; }
parted() { echo MUTATION; return 1; }
partprobe() { echo MUTATION; return 1; }
wipefs() { echo MUTATION; return 1; }
mkfs.ext4() { echo MUTATION; return 1; }
udevadm() { echo MUTATION; return 1; }
tac() { :; }
phase1_drive
''', 'sda\ny\n')
        self.assertNotEqual(r.returncode, 0)
        self.assertNotIn('MUTATION', r.stdout)
        self.assertIn('No COREX_DATA filesystem', r.stdout)


if __name__ == '__main__':
    unittest.main()
