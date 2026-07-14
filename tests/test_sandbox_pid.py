"""The check sandbox must isolate the PID namespace (2026-07-13 fix).

Hermetic: it inspects the argv that run-checks.py builds; it does not spawn
bwrap (which would not nest inside the review sandbox). The runtime isolation
was verified manually: host-visible PIDs dropped from 558 to 6 with --unshare-pid.
"""
import importlib.util
import os
import unittest
from pathlib import Path

BIN = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "bin")
_spec = importlib.util.spec_from_file_location("runchecks", os.path.join(BIN, "run-checks.py"))
rc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(rc)


class TestSandboxPid(unittest.TestCase):
    def test_unshare_pid_present(self):
        args = rc.sandbox_command(Path("/tmp/work"), "true", [])
        self.assertIn("--unshare-pid", args)

    def test_isolation_flags_not_regressed(self):
        args = rc.sandbox_command(Path("/tmp/work"), "true", [])
        for flag in ("--unshare-net", "--die-with-parent", "--proc", "--tmpfs"):
            self.assertIn(flag, args)

    def test_private_proc_accompanies_pid_unshare(self):
        # A private PID namespace needs a fresh /proc mount to reflect it.
        args = rc.sandbox_command(Path("/tmp/work"), "true", [])
        self.assertLess(args.index("--unshare-pid"), args.index("bash"))
        i = args.index("--proc")
        self.assertEqual(args[i + 1], "/proc")

    @staticmethod
    def _pairs(args, flag):
        """(src, dst) tuples for every `flag src dst` triple in argv."""
        return [
            (args[i + 1], args[i + 2])
            for i, a in enumerate(args)
            if a == flag and i + 2 < len(args)
        ]

    def test_declared_dep_bound_READ_ONLY(self):
        # bridge-fix review: assert the dep is preceded by --ro-bind, not just
        # present -- a regression flipping it to a writable --bind must fail.
        args = rc.sandbox_command(Path("/tmp/work"), "true", [Path("/opt/dep")])
        self.assertIn(("/opt/dep", "/opt/dep"), self._pairs(args, "--ro-bind"))
        self.assertNotIn(("/opt/dep", "/opt/dep"), self._pairs(args, "--bind"))

    def test_workroot_bound_writable_at_work(self):
        # The disposable checkout is (correctly) --bind at /work, never --ro-bind.
        args = rc.sandbox_command(Path("/tmp/work"), "true", [])
        self.assertIn(("/tmp/work", "/work"), self._pairs(args, "--bind"))
        self.assertNotIn(("/tmp/work", "/work"), self._pairs(args, "--ro-bind"))

    def test_system_paths_bound_read_only(self):
        args = rc.sandbox_command(Path("/tmp/work"), "true", [])
        ro = self._pairs(args, "--ro-bind")
        for p in ("/usr", "/bin", "/etc"):
            self.assertIn((p, p), ro)


if __name__ == "__main__":
    unittest.main()
