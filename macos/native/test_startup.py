import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time
import unittest
import fcntl

BUILD = Path(__file__).resolve().parent.parent / "build"
FIXTURE = BUILD / "startup-fixture"


class StartupTest(unittest.TestCase):
    def setUp(self):
        # Installed npm paths can exceed sockaddr_un's 104-byte limit. Only the
        # fixture sockets use a short temporary root; production paths are fixed.
        self.temp = tempfile.TemporaryDirectory(prefix="ml-startup-")
        self.root = Path(self.temp.name)
        (self.root / "coordinator.lock").touch()
        self.env = {**os.environ, "ML_TEST_ROOT": str(self.root)}

    def starts(self):
        p = self.root / "starts"
        return p.read_text().splitlines() if p.exists() else []

    def client(self, mode="client"):
        subprocess.run([str(FIXTURE), mode], env=self.env, check=True, timeout=6)

    def tearDown(self):
        deadline = time.monotonic() + 2
        while self.starts() and time.monotonic() < deadline:
            try:
                with socket.socket(socket.AF_UNIX) as s:
                    s.settimeout(0.2); s.connect(str(self.root / "control.sock")); s.sendall(b"STOP\n")
                break
            except OSError:
                time.sleep(0.05)
        # Only processes created by this test fixture, never installed components.
        for pid in self.starts():
            try: os.kill(int(pid), signal.SIGTERM)
            except ProcessLookupError: pass
        self.temp.cleanup()

    def test_absent_start_verified_handshake_then_reuse(self):
        self.client(); self.client()
        self.assertEqual(len(self.starts()), 1)

    def test_concurrent_clients_share_one_inherited_flock(self):
        self.env["ML_TEST_DELAY"] = "1"
        clients = [subprocess.Popen([str(FIXTURE), "client"], env=self.env) for _ in range(2)]
        for client in clients: self.assertEqual(client.wait(timeout=6), 0)
        self.assertEqual(len(self.starts()), 1)

    def test_startup_failure_does_not_respawn_in_loop(self):
        self.env["ML_TEST_FAIL"] = "1"
        self.client("failure")
        self.assertEqual(len(self.starts()), 1)

    def test_pause_and_signed_shutdown_confirm_eof_and_release_flock(self):
        self.client()
        self.client("pause")
        self.client("shutdown")
        with (self.root / "coordinator.lock").open("rb") as lock:
            deadline = time.monotonic() + 2
            while True:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB); break
                except BlockingIOError:
                    if time.monotonic() >= deadline: raise
                    time.sleep(0.01)
        self.assertFalse((self.root / "control.sock").exists())

    def test_cancel_abandons_client_without_killing_shared_start(self):
        self.env["ML_TEST_DELAY"] = "1"
        client = subprocess.Popen([str(FIXTURE), "cancel"], env=self.env, stdin=subprocess.PIPE)
        deadline = time.monotonic() + 2
        while not self.starts() and time.monotonic() < deadline: time.sleep(0.01)
        client.stdin.close()
        self.assertEqual(client.wait(timeout=6), 0)
        self.client()
        self.assertEqual(len(self.starts()), 1)
