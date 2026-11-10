import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys

root = pathlib.Path.cwd()
kind = sys.argv[1]
variant = os.environ.get('TAMAIOS_TIMER_VARIANT', 'baseline')
out = root / 'integration-results'
out.mkdir(exist_ok=True)
report = {'group': kind, 'variant': variant, 'commit': os.environ['GITHUB_SHA'], 'passed': False, 'scope': 'Real FFI startup/isolation/snapshot only; synthetic unused-SRAM marker, no connection gameplay' if kind == 'ffi' else 'Unsigned iOS compilation only; no installation or phone lifecycle test'}
log = []
def run(args, timeout=300, cwd=None):
    try:
        proc = subprocess.run(args, cwd=cwd or root, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        text = exc.stdout or b''
        log.extend((text.decode(errors='replace') if isinstance(text, bytes) else text).splitlines())
        raise
    log.extend(proc.stdout.splitlines())
    if proc.returncode:
        raise RuntimeError('command failed with exit ' + str(proc.returncode))
try:
    if variant not in ['baseline', 'candidate']:
        raise ValueError('unknown timer variant')
    run(['git', 'clone', 'https://github.com/oreo-fox/tg18-emu', 'upstream'])
    run(['git', '-C', 'upstream', 'checkout', '41204c92e98a8882d5c90a9876d8990f3b63e285'])
    report['core_commit'] = subprocess.check_output(['git', '-C', 'upstream', 'rev-parse', 'HEAD'], text=True).strip()
    report['patches'] = {}
    for name in ['radio.patch', 'ir_partner.patch']:
        path = root / 'patches' / name
        report['patches'][name] = hashlib.sha256(path.read_bytes()).hexdigest()
        run(['git', '-C', 'upstream', 'apply', '../patches/' + name])
    if variant == 'candidate':
        candidate = root / 'tools/timer_snapshot_history.patch'
        run(['git', '-C', 'upstream', 'apply', '--check', str(candidate)])
        run(['git', '-C', 'upstream', 'apply', str(candidate)])
        report['candidate_patch_sha256'] = hashlib.sha256(candidate.read_bytes()).hexdigest()
    report['source_mode'] = 'tracked-source'
    report['app_source_tree_sha256'] = hashlib.sha256(json.dumps({str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((root / 'ios/TamaiOS').rglob('*.swift'))}, sort_keys=True).encode()).hexdigest()
    if kind == 'ffi':
        firmware = sorted((root / 'firmware').glob('*.bin'))
        report['firmware'] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in firmware}
        if not firmware:
            raise RuntimeError('no firmware available')
        os.environ['TAMAIOS_AUDIT_FIRMWARE'] = str(root / 'firmware')
        tests = root / 'ffi/tests'
        tests.mkdir(exist_ok=True)
        shutil.copyfile(root / 'tools/ffi_integration_audit.rs', tests / 'audit_ffi.rs')
        run(['cargo', 'test', '--release', '--manifest-path', 'ffi/Cargo.toml', '--test', 'audit_ffi', '--', '--nocapture', '--test-threads=1'], 600)
    elif kind == 'ios':
        run(['xcodebuild', '-version'])
        run(['rustup', 'target', 'add', 'aarch64-apple-ios'])
        os.environ['IPHONEOS_DEPLOYMENT_TARGET'] = '16.0'
        run(['cargo', 'build', '--release', '--manifest-path', 'ffi/Cargo.toml', '--target', 'aarch64-apple-ios'], 900)
        (root / 'ios/lib').mkdir(exist_ok=True)
        shutil.copyfile(root / 'ffi/target/aarch64-apple-ios/release/libtamaios.a', root / 'ios/lib/libtamaios.a')
        run(['brew', 'install', 'xcodegen'], 600)
        run(['python3', '-m', 'pip', 'install', '--user', '--break-system-packages', 'pillow'])
        run(['python3', 'tools/icon.py', 'ios/TamaiOS/Assets.xcassets/AppIcon.appiconset/icon.png'])
        (root / 'ios/TamaiOS/BundledFirmware').mkdir(exist_ok=True)
        (root / 'ios/TamaiOS/BundledAssets').mkdir(exist_ok=True)
        run(['xcodegen', 'generate'], cwd=root / 'ios')
        run(['xcodebuild', '-project', 'ios/TamaiOS.xcodeproj', '-scheme', 'TamaiOS', '-configuration', 'Release', '-sdk', 'iphoneos', '-destination', 'generic/platform=iOS', '-derivedDataPath', 'ios/build', 'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO', 'CODE_SIGN_IDENTITY=', 'build'], 1800)
        if not (root / 'ios/build/Build/Products/Release-iphoneos/TamaiOS.app').is_dir():
            raise RuntimeError('compiled app product missing')
    else:
        raise ValueError('unknown group')
    report['passed'] = True
except Exception as exc:
    report['error'] = type(exc).__name__ + ': ' + str(exc)
report['log_tail'] = log[-70:]
(out / (kind + '.json')).write_text(json.dumps(report, indent=2) + '\n')
(out / (kind + '.txt')).write_text('\n'.join(log) + '\n')
raise SystemExit(0 if report['passed'] else 1)
