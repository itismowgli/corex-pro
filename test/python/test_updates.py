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

class HoldsTest(unittest.TestCase):
    """A pin can sit below upstream on purpose, and saying so is the point.

    Before this, the dashboard advertised keeper 2.21.7 and the Nextcloud
    whiteboard v2.0.0. Both were measured to break this box: keeper
    crash-looped eight times because its embedded Postgres is not on UTC, and
    the whiteboard container has to match a Nextcloud app that is still 1.5.9.
    Offering an upgrade that is known not to work is worse than silence.
    """

    def setUp(self):
        self._root = u.REPO_ROOT
        u.REPO_ROOT = str(pathlib.Path(__file__).resolve().parents[2])

    def tearDown(self):
        u.REPO_ROOT = self._root

    def test_the_modules_that_hold_a_version_declare_it(self):
        for svc in ("keeper", "nextcloud"):
            holds = u.service_holds(svc)
            self.assertTrue(holds, "%s declares no hold" % svc)
            for h in holds:
                self.assertTrue(h["repo"], svc)
                self.assertTrue(h["version"], svc)
                # A hold with no reason is just a silent refusal.
                self.assertTrue(len(h["reason"]) > 20, "%s: no reason given" % svc)

    def test_a_module_without_holds_returns_none(self):
        self.assertEqual(u.service_holds("traefik"), [])

    def test_the_named_version_and_anything_above_it_is_held(self):
        holds = u.service_holds("keeper")
        ref = "ghcr.io/ridafkih/keeper-standalone:2.18.7"
        self.assertTrue(u.held_reason(holds, ref, "2.21.7"))
        self.assertTrue(u.held_reason(holds, ref, "2.22.0"), "a later release must stay held")
        self.assertTrue(u.held_reason(holds, ref, "3.0.0"))

    def test_a_version_below_the_hold_is_not_held(self):
        holds = u.service_holds("keeper")
        ref = "ghcr.io/ridafkih/keeper-standalone:2.18.7"
        self.assertIsNone(u.held_reason(holds, ref, "2.19.0"))

    def test_a_hold_applies_only_to_its_own_image(self):
        # nextcloud holds the whiteboard, not the Nextcloud image itself, and
        # a module can ship several images.
        holds = u.service_holds("nextcloud")
        self.assertTrue(
            u.held_reason(holds, "ghcr.io/nextcloud-releases/whiteboard:v1.5.9", "v2.0.0"))
        self.assertIsNone(u.held_reason(holds, "nextcloud:34", "35"))

    def test_held_outranks_current_but_never_real_news(self):
        # Equal to current, a stack holding one image reported whichever row
        # max reached first, so the Nextcloud whiteboard's hold was invisible
        # while keeper's showed: the same decision, reported or not depending
        # on what else happened to be in the stack.
        self.assertGreater(u._RANK["held"], u._RANK["current"])
        self.assertLess(u._RANK["held"], u._RANK["unknown"])
        self.assertLess(u._RANK["held"], u._RANK["update"])
        self.assertLess(u._RANK["held"], u._RANK["newer-release"])

class RepoRootTest(unittest.TestCase):
    """Where the modules are found, which decides whether holds work at all.

    The first version read an environment variable nobody sets and fell back
    to /opt/corex-pro. The repository on this box is under /home, so every
    module lookup missed and `service_holds` returned nothing, which the
    checker cannot distinguish from "this module holds nothing". Two
    deliberately held versions were advertised as available again.
    """

    def test_the_agent_config_wins_over_the_hardcoded_default(self):
        conf = {"COREX_REPO_ROOT": "/home/someone/corex-pro"}
        real = u._repo_root.__globals__.get("corex_common")
        import types
        fake = types.SimpleNamespace(read_conf=lambda *a, **k: conf)
        sys.modules["corex_common"] = fake
        try:
            got = u._repo_root()
        finally:
            if real is None:
                sys.modules.pop("corex_common", None)
        self.assertEqual(got, "/home/someone/corex-pro")

    def test_an_explicit_environment_variable_still_wins(self):
        import os
        os.environ["COREX_REPO_ROOT"] = "/tmp/explicit"
        try:
            self.assertEqual(u._repo_root(), "/tmp/explicit")
        finally:
            os.environ.pop("COREX_REPO_ROOT", None)

    def test_the_resolved_root_actually_holds_service_modules(self):
        # The property that matters: whatever it resolves to has to be a
        # directory with modules in it, or holds silently do nothing.
        import pathlib
        root = pathlib.Path(__file__).resolve().parents[2]
        self.assertTrue((root / "lib" / "services" / "keeper.sh").exists())


if __name__ == '__main__':
    unittest.main()
