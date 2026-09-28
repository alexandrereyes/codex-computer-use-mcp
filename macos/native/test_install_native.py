import importlib.util
from pathlib import Path
import unittest
from unittest import mock
import os
import tempfile
import plistlib
import subprocess
import fcntl

spec = importlib.util.spec_from_file_location("native_install", Path(__file__).with_name("install-native.py"))
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class NativePolicyTest(unittest.TestCase):
    def test_remove_disables_then_pauses_and_stops_before_removing_files(self):
        for active in (False, True):
            with self.subTest(active=active), tempfile.TemporaryDirectory(dir=installer.BUILD, prefix="remove-contract-") as directory:
                root = Path(directory)
                (root / "receipt.json").write_text('{"uid":501}')
                (root / "config.plist").write_bytes(plistlib.dumps({"persistent": True}))
                (root / "coordinator.lock").touch()
                events, attempts = [], [0]
                real_stat, real_flock = Path.stat, fcntl.flock
                def stat(path, *args, **kwargs):
                    result = real_stat(path, *args, **kwargs)
                    if path in (root, root / "receipt.json"):
                        fields = list(result); fields[4] = 0
                        return os.stat_result(fields)  # Administrative ownership fixture, no chown/root.
                    return result
                def flock(fd, operation):
                    attempts[0] += 1
                    if attempts[0] == 1: raise BlockingIOError()
                    return real_flock(fd, operation)
                def run(args, **kwargs):
                    self.assertTrue(plistlib.loads((root / "config.plist").read_bytes())["disabled"])
                    step = "guards" if args[0] == "/usr/bin/pgrep" else args[-1]
                    events.append(step)
                    return subprocess.CompletedProcess(args, 1 if step == "guards" else 0,
                        stdout="ACTIVE\n" if active else ("IDLE\n" if step == "pause" else "STOPPING\n"))
                def remove_owned(db, receipt):
                    events.append("remove")
                    self.assertTrue((root / "coordinator.lock").exists())
                    with (root / "coordinator.lock").open("rb") as other:
                        with self.assertRaises(BlockingIOError): real_flock(other, fcntl.LOCK_EX | fcntl.LOCK_NB)
                with mock.patch.object(installer, "ROOT", root), mock.patch.object(Path, "stat", stat), \
                     mock.patch.object(installer.fcntl, "flock", flock), mock.patch.object(installer.subprocess, "run", side_effect=run), \
                     mock.patch.object(installer, "_remove_owned", side_effect=remove_owned):
                    if active:
                        with self.assertRaisesRegex(RuntimeError, "Cannot confirm IDLE"): installer.remove(None)
                        self.assertEqual(events, ["pause"])
                    else:
                        installer.remove(None)
                        self.assertEqual(events, ["pause", "guards", "shutdown", "remove"])

    def test_installation_requires_explicit_experimental_opt_in(self):
        with self.assertRaisesRegex(RuntimeError, "requires exactly one"):
            installer.install(None, 501, Path("unused"))

    def test_persistent_and_experimental_configuration(self):
        with mock.patch.object(installer.time, "time", return_value=1000):
            self.assertEqual(installer.configuration(501, "signed", False),
                             {"uid": 501, "controllerRequirement": "signed", "experimentalUntil": 1600})
            self.assertEqual(installer.configuration(501, "signed", True),
                             {"uid": 501, "controllerRequirement": "signed", "persistent": True})
        with self.assertRaisesRegex(RuntimeError, "requires exactly one"):
            installer.install(None, 501, Path("unused"), experimental=True, persistent=True)

    def test_experimental_opt_in_reaches_controller_preflight_before_writes(self):
        with mock.patch.dict(os.environ, {"SUDO_UID": str(os.getuid())}), \
             mock.patch.object(installer, "controller_requirement", side_effect=RuntimeError("controller preflight")) as check:
            with self.assertRaisesRegex(RuntimeError, "controller preflight"):
                installer.install(None, os.getuid(), Path("fixture"), experimental=True)
            check.assert_called_once_with(Path("fixture"))

    def test_reference_roundtrip_and_preservation_of_later_changes(self):
        existing = {"class": "rule", "k-of-n": 1, "rule": [
            "com.openai.sky.CUAService.AuthorizationPlugin.remote", "use-login-window-ui"], "comment": "original"}
        proposal = installer.reference(existing, True)
        self.assertEqual(proposal["rule"], [installer.RIGHT, *existing["rule"]])
        self.assertEqual(installer.reference(proposal, False), existing)
        proposal["rule"].append("later-rule")
        proposal["comment"] = "later change"
        removed = installer.reference(proposal, False)
        self.assertEqual(removed["rule"], [*existing["rule"], "later-rule"])
        self.assertEqual(removed["comment"], "later change")

    def test_no_policy_conversion_or_duplicate_insertion(self):
        with self.assertRaisesRegex(RuntimeError, "Unsupported"):
            installer.reference({"class": "user"}, True)
        with self.assertRaisesRegex(RuntimeError, "already present"):
            installer.reference({"class": "rule", "k-of-n": 1, "rule": [installer.RIGHT, "use-login-window-ui"]}, True)
