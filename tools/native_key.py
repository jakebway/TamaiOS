"""Prints the key of the Rust sources. CI publishes the built library as release native-<key>;
iOXcode (which cannot run Rust on the phone) downloads the library with the same key."""
import hashlib, pathlib

root = pathlib.Path(__file__).resolve().parents[1]
files = []
for base in ("ffi", "patches"):
    for p in sorted((root / base).rglob("*")):
        if p.is_file() and "target" not in p.relative_to(root).parts:
            files.append(p)
for extra in ("tools/prepare_core.py", "tools/timer_snapshot_history.patch"):
    files.append(root / extra)
h = hashlib.sha256()
for p in sorted(set(files)):
    h.update(str(p.relative_to(root)).encode())
    h.update(p.read_bytes())
print(h.hexdigest()[:16])
