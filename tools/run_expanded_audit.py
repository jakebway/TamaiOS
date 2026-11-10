import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

root = pathlib.Path.cwd()
kind = sys.argv[1]
out = root / 'expanded-results'
out.mkdir(exist_ok=True)
report = {'group': kind, 'commit': os.environ['GITHUB_SHA'], 'passed': False, 'scope': 'IR context/model checks only' if kind == 'ir' else 'Actual Swift notification policies only; firmware semantics and iOS delivery unverified'}
log = []
def run(args, timeout=180):
    proc = subprocess.run(args, cwd=root, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    log.extend(proc.stdout.splitlines())
    if proc.returncode:
        raise RuntimeError('command failed with exit ' + str(proc.returncode))
try:
    if kind == 'ir':
        run(['git', 'clone', 'https://github.com/oreo-fox/tg18-emu', 'upstream'])
        run(['git', '-C', 'upstream', 'checkout', '41204c92e98a8882d5c90a9876d8990f3b63e285'])
        for patch in ['radio.patch', 'ir_partner.patch']:
            run(['git', '-C', 'upstream', 'apply', '../patches/' + patch])
        tests = root / 'upstream/core/tests'
        tests.mkdir(exist_ok=True)
        shutil.copyfile(root / 'tools/expanded_ir_audit.rs', tests / 'tamaios_expanded_ir.rs')
        run(['cargo', 'test', '--locked', '--release', '--manifest-path', 'upstream/Cargo.toml', '-p', 'tg18-core', '--test', 'tamaios_expanded_ir', '--', '--nocapture', '--test-threads=1'], 300)
    elif kind == 'policy':
        store = (root / 'ios/TamaiOS/Core/Store.swift').read_text()
        start = store.index('struct BundledVariant:')
        end = store.index('\nextension ToyStore', start)
        with tempfile.TemporaryDirectory() as work:
            variant = pathlib.Path(work) / 'Variants.swift'
            variant.write_text('import Foundation\n' + store[start:end])
            binary = pathlib.Path(work) / 'policy-audit'
            run(['swiftc', str(variant), 'ios/TamaiOS/Core/CareEventPolicy.swift', 'tools/expanded_policy_audit.swift', '-o', str(binary)])
            run([str(binary)])
    else:
        raise ValueError('unknown test group')
    report['passed'] = True
except Exception as exc:
    report['error'] = str(exc)
report['log_tail'] = log[-35:]
(out / (kind + '.json')).write_text(json.dumps(report, indent=2) + '\n')
(out / (kind + '.txt')).write_text('\n'.join(log) + '\n')
raise SystemExit(0 if report['passed'] else 1)
