"""Optional MacLock installation. No writes unless install/remove is invoked."""
import argparse
import copy
import json
import os
from pathlib import Path
import plistlib
import pwd
import re
import shutil
import subprocess
import sys
import time
import fcntl

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from installer_support import AuthorizationDB, manifest

ROOT = Path("/Library/Application Support/MacLock")
PLUGIN = Path("/Library/Security/SecurityAgentPlugins/MacLockAuthorization.bundle")
AGENT = Path("/Library/LaunchAgents/br.com.alexandrem.mac-lock.plist")
RIGHT = "br.com.alexandrem.mac-lock.operation"
SCREEN = "system.login.screensaver"
DEFINITION = {"class": "evaluate-mechanisms", "mechanisms": ["MacLockAuthorization:operation"],
              "tries": 1, "shared": False, "comment": "MacLock: active authenticated operation and confirmed guards only"}
BUILD = Path(__file__).resolve().parent.parent / "build"


def reference(value, add):
    result = copy.deepcopy(value)
    if result.get("class") != "rule" or result.get("k-of-n") != 1 or not isinstance(result.get("rule"), list):
        raise RuntimeError("Unsupported screensaver policy; refusing conversion")
    if not result["rule"] or not all(isinstance(x, str) for x in result["rule"]):
        raise RuntimeError("Unsupported screensaver alternatives")
    if add:
        if RIGHT in result["rule"]:
            raise RuntimeError("Native reference already present")
        result["rule"].insert(0, RIGHT)
    else:
        result["rule"] = [x for x in result["rule"] if x != RIGHT]
    if not result["rule"]:
        raise RuntimeError("Refusing an empty policy")
    return result


def update_reference(db, add):
    before = db.read(SCREEN)
    after = reference(before, add)
    if after == before:
        return
    if db.read(SCREEN) != before:
        raise RuntimeError("Policy changed during preparation")
    db.write(SCREEN, after)
    actual = db.read(SCREEN)
    strip = lambda x: {k: v for k, v in x.items() if k not in {"created", "modified"}}
    if strip(actual) != strip(after):
        raise RuntimeError("Policy read-back differs; preserve artifacts and inspect")


def verify(path, identifier):
    manifest(path)  # Reject symlinks.
    info = plistlib.loads((path / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != identifier:
        raise RuntimeError("Unexpected component identity")
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(path)], check=True)


def controller_requirement(app):
    verify(app, "local.opencode.custom")
    result = subprocess.run(["/usr/bin/codesign", "-d", "-r-", str(app)], check=True, capture_output=True, text=True)
    text = result.stdout + result.stderr
    requirement = next(line.removeprefix("designated => ") for line in text.splitlines() if line.startswith("designated => "))
    if 'identifier "local.opencode.custom"' not in requirement or "certificate leaf" not in requirement:
        raise RuntimeError("Expected the existing persistent Custom signing certificate, not a PID/ad-hoc identity")
    return requirement


def configuration(uid, requirement, persistent):
    return {"uid": uid, "controllerRequirement": requirement,
            **({"persistent": True} if persistent else {"experimentalUntil": time.time() + 600})}


def install(db, uid, app, experimental=False, persistent=False):
    if experimental == persistent:
        raise RuntimeError("Installation requires exactly one of --experimental-locked-use or --persistent-locked-use")
    if uid <= 0 or uid != int(os.environ.get("SUDO_UID", "-1")):
        raise RuntimeError("Install from sudo as the intended graphical-session user")
    user = pwd.getpwuid(uid)
    requirement = controller_requirement(app)
    verify(BUILD / "MacLock.app", "br.com.alexandrem.mac-lock")
    verify(BUILD / "MacLockAuthorization.bundle", "br.com.alexandrem.mac-lock.authorization")
    reference(db.read(SCREEN), True)
    if any(p.exists() or p.is_symlink() for p in (ROOT, PLUGIN, AGENT)) or db.read(RIGHT) is not None:
        raise RuntimeError("Existing native artifacts; refusing overwrite")
    ROOT.mkdir(mode=0o755)
    ROOT.chmod(0o755)
    receipt = {"uid": uid, "app": manifest(BUILD / "MacLock.app"), "plugin": manifest(BUILD / "MacLockAuthorization.bundle")}
    (ROOT / "receipt.json").write_text(json.dumps(receipt, indent=2))
    (ROOT / "receipt.json").chmod(0o600)
    # Partial installation is recoverable by remove. Never restore a policy snapshot.
    shutil.copytree(BUILD / "MacLock.app", ROOT / "MacLock.app")
    shutil.copytree(BUILD / "MacLockAuthorization.bundle", PLUGIN)
    (ROOT / "run").mkdir(mode=0o711)
    (ROOT / "run").chmod(0o711)
    os.chown(ROOT / "run", uid, user.pw_gid)
    config = configuration(uid, requirement, persistent)
    (ROOT / "config.plist").write_bytes(plistlib.dumps(config))
    (ROOT / "config.plist").chmod(0o644)
    (ROOT / "coordinator.lock").touch(mode=0o644)
    (ROOT / "coordinator.lock").chmod(0o644)
    for bundle in (ROOT / "MacLock.app", PLUGIN):
        for path in [bundle, *bundle.rglob("*")]:
            executable = path.parent.name == "MacOS"
            path.chmod(0o755 if path.is_dir() or executable else 0o644)
    verify(ROOT / "MacLock.app", "br.com.alexandrem.mac-lock")
    verify(PLUGIN, "br.com.alexandrem.mac-lock.authorization")
    if manifest(ROOT / "MacLock.app") != receipt["app"] or manifest(PLUGIN) != receipt["plugin"]:
        raise RuntimeError("Components changed while copying; preserve receipt and remove partial installation")
    # Proxy/helper starts the coordinator in the authorized backend's chain, never launchd.
    db.write(RIGHT, DEFINITION)
    if any(db.read(RIGHT).get(k) != v for k, v in DEFINITION.items()):
        raise RuntimeError("Native rule read-back differs; remove using the receipt")
    update_reference(db, True)
    print("Persistent locked use installed (explicit opt-in; 120-second leases)." if persistent else
          f"Experimental locked use installed; expires at {time.strftime('%Y-%m-%d %H:%M:%S %z', time.localtime(config['experimentalUntil']))}.")


def remove(db):
    if ROOT.is_symlink() or (ROOT / "receipt.json").is_symlink() or ROOT.stat().st_uid != 0 or (ROOT / "receipt.json").stat().st_uid != 0:
        raise RuntimeError("Refusing untrusted native receipt/root")
    receipt = json.loads((ROOT / "receipt.json").read_text())
    config_path = ROOT / "config.plist"
    if config_path.exists():
        config = plistlib.loads(config_path.read_bytes())
        config["disabled"] = True  # Stop fresh starts before pausing/shutting down the incumbent.
        config_path.write_bytes(plistlib.dumps(config))
    with (ROOT / "coordinator.lock").open("a+b") as lock:  # Also permits rollback before partial install created the lock.
        executable = str(ROOT / "MacLock.app/Contents/MacOS/mac-lock")
        running = False
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            running = True
            pause = subprocess.run([executable, "pause"], capture_output=True, text=True, timeout=5)
            if pause.returncode or pause.stdout.strip() != "IDLE":
                raise RuntimeError("Cannot confirm IDLE; installation disabled for new calls. Retry remove after confirmed relock")
        guardian = subprocess.run(["/usr/bin/pgrep", "-f", re.escape(executable) + r" guardian$"], capture_output=True)
        if guardian.returncode != 1:
            raise RuntimeError("Guardian still running or process check failed; will not remove protection")
        if running:
            stopped = subprocess.run([executable, "shutdown"], capture_output=True, text=True, timeout=5)
            if stopped.returncode:
                raise RuntimeError("Coordinator shutdown not confirmed; preserving files")
            deadline = time.monotonic() + 3
            while True:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline: raise RuntimeError("Coordinator lock still held; preserving files")
                    time.sleep(0.05)
        _remove_owned(db, receipt)  # Hold the singleton lock through policy/file removal.


def _remove_owned(db, receipt):
    uid = receipt["uid"]
    service = f"gui/{uid}/br.com.alexandrem.mac-lock"
    present = subprocess.run(["/bin/launchctl", "print", service], capture_output=True)
    update_reference(db, False)
    current = db.read(RIGHT)
    if current is not None:
        if any(current.get(k) != v for k, v in DEFINITION.items()):
            raise RuntimeError("Native reference detached, but rule changed; preserving it")
        db.remove(RIGHT)
    if present.returncode == 0:
        subprocess.run(["/bin/launchctl", "bootout", service], check=True)
    for target, key in ((ROOT / "MacLock.app", "app"), (PLUGIN, "plugin")):
        if target.exists():
            if target.is_symlink() or manifest(target) != receipt[key]:
                raise RuntimeError("Detached, but installed component changed; preserving it")
            shutil.rmtree(target)
    AGENT.unlink(missing_ok=True)
    for name in ("control.sock", "authorization.sock", "native.log", "suppressed"):
        (ROOT / "run" / name).unlink(missing_ok=True)
    if (ROOT / "run").exists(): (ROOT / "run").rmdir()
    for name in ("config.plist", "coordinator.lock", "receipt.json"): (ROOT / name).unlink(missing_ok=True)
    ROOT.rmdir()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["preview", "install", "remove"])
    parser.add_argument("--controller-app", type=Path)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--experimental-locked-use", action="store_true", help="Opt in to a 10-minute experimental authorization window")
    mode.add_argument("--persistent-locked-use", action="store_true", help="Administrative opt-in without a global expiry; individual leases stay bounded")
    args = parser.parse_args()
    db = AuthorizationDB()
    if args.action == "preview":
        print(plistlib.dumps(reference(db.read(SCREEN), True)).decode(), end=""); return
    if os.geteuid() != 0: raise RuntimeError("Root required for native installation/removal")
    if args.action == "remove": remove(db)
    else:
        if not args.controller_app: raise RuntimeError("--controller-app is required")
        install(db, int(os.environ.get("SUDO_UID", "-1")), args.controller_app, args.experimental_locked_use, args.persistent_locked_use)


if __name__ == "__main__":
    try: main()
    except Exception as error:
        print(f"MacLock native installer: {error}. Preserve receipt; use remove for partial installation recovery.", file=sys.stderr)
        sys.exit(1)
