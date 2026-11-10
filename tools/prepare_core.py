import argparse
import hashlib
import json
import pathlib
import subprocess

CORE_COMMIT = '41204c92e98a8882d5c90a9876d8990f3b63e285'
PATCHES = [
    ('patches/radio.patch', '9148d2851a55439d3a0443b70a3832d58b0f548a1cd8780497c7dd935bfb00bd'),
    ('patches/ir_partner.patch', '09641a926267255724aeb726403fd3f07e64c27ef86e4b0b5127557a96e241da'),
    ('tools/timer_snapshot_history.patch', '1532c0d91cff33fae3ef4eb45d297099dbb3ff75816f68d4faf8b25d92e6e87e'),
]

def prepare(root, destination, variant):
    if variant not in ('legacy', 'promoted'):
        raise ValueError('Unknown core variant')
    destination = destination.resolve()
    if destination.exists():
        raise RuntimeError('Refusing to modify an existing core checkout: ' + str(destination))
    selected = PATCHES if variant == 'promoted' else PATCHES[:2]
    verified = {}
    for name, expected in selected:
        actual = hashlib.sha256((root / name).read_bytes()).hexdigest()
        if actual != expected:
            raise RuntimeError('Patch differs from the validated version: ' + name)
        verified[name] = actual
    subprocess.run(['git', 'clone', 'https://github.com/oreo-fox/tg18-emu', str(destination)], check=True)
    subprocess.run(['git', '-C', str(destination), 'checkout', '--detach', CORE_COMMIT], check=True)
    actual_commit = subprocess.check_output(['git', '-C', str(destination), 'rev-parse', 'HEAD'], text=True).strip()
    if actual_commit != CORE_COMMIT:
        raise RuntimeError('Unexpected core commit')
    for name, expected in selected:
        path = (root / name).resolve()
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise RuntimeError('Patch changed during preparation: ' + name)
        subprocess.run(['git', '-C', str(destination), 'apply', '--check', str(path)], check=True)
        subprocess.run(['git', '-C', str(destination), 'apply', str(path)], check=True)
    return {'variant': variant, 'core_commit': actual_commit, 'applied_patch_sha256': verified}

def main():
    parser = argparse.ArgumentParser(description='Prepare a fresh pinned core with validated patches; existing checkouts are never overwritten.')
    parser.add_argument('--variant', choices=['legacy', 'promoted'], default='promoted')
    parser.add_argument('--destination', default='upstream')
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parents[1]
    destination = pathlib.Path(args.destination)
    if not destination.is_absolute():
        destination = root / destination
    print(json.dumps(prepare(root, destination, args.variant), indent=2))

if __name__ == '__main__':
    main()
