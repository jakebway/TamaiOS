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
scopes = {'ir': 'IR context/model checks only', 'policy': 'Actual Swift policies; firmware semantics and iOS delivery unverified', 'transport': 'Actual TamaLink.answer method with synthetic replies; not firmware protocol validation'}
report = {'group': kind, 'commit': os.environ['GITHUB_SHA'], 'passed': False, 'scope': scopes.get(kind, 'unknown')}
log = []
def run(args, timeout=180):
    try:
        proc = subprocess.run(args, cwd=root, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        text = exc.stdout or b''
        log.extend((text.decode(errors='replace') if isinstance(text, bytes) else text).splitlines())
        raise
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
    elif kind in ['policy', 'transport']:
        run(['swiftc', '--version'])
        with tempfile.TemporaryDirectory() as work:
            dependency = pathlib.Path(work) / 'Dependency.swift'
            binary = pathlib.Path(work) / 'audit'
            if kind == 'policy':
                store = (root / 'ios/TamaiOS/Core/Store.swift').read_text()
                start = store.index('struct BundledVariant:')
                end = store.index('\nextension ToyStore', start)
                dependency.write_text('import Foundation\n' + store[start:end])
                files = [str(dependency), 'ios/TamaiOS/Core/CareEventPolicy.swift', 'tools/expanded_policy_audit.swift']
            else:
                source = (root / 'ios/TamaiOS/Tamatown/TamaLink.swift').read_text()
                start = source.index('    func answer(firstTimeout:')
                opening = source.index('{', start)
                depth = 1
                end = opening + 1
                while depth and end < len(source):
                    depth += (source[end] == '{') - (source[end] == '}')
                    end += 1
                if depth:
                    raise ValueError('answer extraction failed')
                method = source[start:end]
                dependency.write_text('import Foundation\nfinal class TransportReplay {\n enum LinkError: Error { case noAnswer }\n var input: [[UInt8]]\n init(_ input: [[UInt8]]) { self.input = input }\n func read() -> [UInt8]? { input.isEmpty ? nil : input.removeFirst() }\n func write(_ bytes: [UInt8]) throws {}\n func trace(_ text: String) {}\n' + method + '\n}\n')
                files = [str(dependency), 'tools/transport_replay_audit.swift']
            run(['swiftc', '-swift-version', '5', *files, '-o', str(binary)])
            run([str(binary)])
    else:
        raise ValueError('unknown test group')
    report['passed'] = True
except Exception as exc:
    report['error'] = str(exc)
report['log_tail'] = log[-60:]
(out / (kind + '.json')).write_text(json.dumps(report, indent=2) + '\n')
(out / (kind + '.txt')).write_text('\n'.join(log) + '\n')
raise SystemExit(0 if report['passed'] else 1)
