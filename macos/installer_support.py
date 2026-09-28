"""Shared authorization database I/O and bundle manifests; importing performs no writes."""
import hashlib
import plistlib
import subprocess


class AuthorizationDB:
    def read(self, name):
        p = subprocess.run(["/usr/bin/security", "authorizationdb", "read", name], capture_output=True)
        if p.returncode:
            if p.stderr.strip() == b"NO (-60005)":
                return None
            raise RuntimeError(f"Cannot read {name}: {p.stderr.decode(errors='replace')}")
        return plistlib.loads(p.stdout)

    def write(self, name, value):
        subprocess.run(["/usr/bin/security", "authorizationdb", "write", name],
                       input=plistlib.dumps(value), check=True, capture_output=True)

    def remove(self, name):
        subprocess.run(["/usr/bin/security", "authorizationdb", "remove", name], check=True, capture_output=True)


def manifest(bundle):
    result = {}
    for p in sorted(bundle.rglob("*")):
        if p.is_symlink():
            raise RuntimeError("Bundle must not contain symlinks")
        if p.is_file():
            result[str(p.relative_to(bundle))] = hashlib.sha256(p.read_bytes()).hexdigest()
    if not result:
        raise RuntimeError("Empty bundle")
    return result
