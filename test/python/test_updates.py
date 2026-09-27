import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / 'agent'))

import corex_updates as u  # noqa: E402


class FakeRegistry:
    """Stands in for remote_digest so the probe is tested without the network.

    Records every tag asked for, because the cost of this check is the point:
    enumerating tags is not viable (ghcr holds over 20000 for immich-server
    and pages 1000 at a time), so the probe has to find the answer in a
    handful of requests or it is not worth having.
    """

    def __init__(self, present, unreachable=()):
        self.present = set(present)
        self.unreachable = set(unreachable)
        self.asked = []

    def __call__(self, host, repo, tag):
        self.asked.append(tag)
        if tag in self.unreachable:
            return None, 'unreachable'
        if tag in self.present:
            return 'sha256:' + tag, None
        return None, 'absent'


class NewerReleaseTest(unittest.TestCase):
    def setUp(self):
        self._real = u.remote_digest

    def tearDown(self):
        u.remote_digest = self._real

    def _run(self, tag, present, **kw):
        fake = FakeRegistry(present, **kw)
        u.remote_digest = fake
        return u.newer_release('ghcr.io', 'immich-app/immich-server', tag), fake

    def test_finds_the_newest_patch_on_a_later_minor(self):
        # The real case: the box was pinned to v3.1.0 while upstream had
        # published up to v3.2.2, and nothing anywhere said so.
        got, fake = self._run('v3.1.0', ['v3.2.0', 'v3.2.1', 'v3.2.2'])
        self.assertEqual(got, 'v3.2.2')
        # Cheap enough to run per image per day. Measured against the live
        # registry at six requests; the ceiling here is what stops a
        # regression turning this into an enumeration.
        self.assertLessEqual(len(fake.asked), 8, fake.asked)

    def test_climbs_a_major_before_settling(self):
        got, _ = self._run('v3.1.0', ['v4.0.0', 'v4.0.1'])
        self.assertEqual(got, 'v4.0.1')

    def test_already_newest_is_not_news(self):
        got, _ = self._run('v3.2.2', [])
        self.assertIsNone(got)

    def test_a_moving_tag_is_never_probed(self):
        for tag in ('latest', 'release', 'stable', '34', 'v3.6'):
            got, fake = self._run(tag, ['v99.0.0'])
            self.assertIsNone(got, tag)
            self.assertEqual(fake.asked, [], tag)

    def test_an_unreachable_registry_answers_nothing_not_a_guess(self):
        # A climb that stops half way is a wrong answer rather than a small
        # one, so it is not reported at all.
        got, _ = self._run('v3.1.0', ['v3.2.0'], unreachable=['v3.2.1'])
        self.assertIsNone(got)

    def test_a_tag_without_the_v_prefix_keeps_its_shape(self):
        got, _ = self._run('2.45.0', ['2.45.1'])
        self.assertEqual(got, '2.45.1')


class RankTest(unittest.TestCase):
    def test_a_newer_release_outranks_unknown_but_not_a_moved_tag(self):
        # The worst news about any image in a stack is the news about the
        # stack, so this ordering decides what a service reports.
        self.assertGreater(u._RANK['update'], u._RANK['stale-tag'])
        self.assertGreater(u._RANK['stale-tag'], u._RANK['newer-release'])
        self.assertGreater(u._RANK['newer-release'], u._RANK['unknown'])
        self.assertGreater(u._RANK['unknown'], u._RANK['current'])


if __name__ == '__main__':
    unittest.main()
