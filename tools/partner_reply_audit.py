import hashlib
import json
import os
import pathlib
import subprocess
import tempfile

root = pathlib.Path.cwd()
out = root / 'partner-results'
out.mkdir(exist_ok=True)
report = {'commit': os.environ['GITHUB_SHA'], 'passed': False, 'scope': 'Actual headless-partner radioAnswer method with synthetic replay; no firmware homecoming or save-completion claim'}
log = []
def command(args):
    p = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
    log.extend(p.stdout.splitlines())
    if p.returncode:
        raise RuntimeError('command failed: ' + str(p.returncode))
def method():
    text = (root / 'ios/TamaiOS/Core/IRLink.swift').read_text()
    start = text.index('    fileprivate func radioAnswer(')
    end = text.index('{', start) + 1
    depth = 1
    while depth and end < len(text):
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    if depth: raise ValueError('method extraction failed')
    return text[start:end]
prefix = '''import Foundation
final class Replay {
 var input: [[UInt8]]
 var writeAllowed = true
 init(_ input: [[UInt8]]) { self.input = input }
 func radioRead(_ p: OpaquePointer) -> [UInt8]? { input.isEmpty ? nil : input.removeFirst() }
 func radioWrite(_ p: OpaquePointer, _ bytes: [UInt8], _ audio: UnsafeMutablePointer<Int16>) -> Bool { writeAllowed }
 func tickAll(_ p: OpaquePointer, _ count: Int, _ audio: UnsafeMutablePointer<Int16>) {}
 func invoke(_ p: OpaquePointer, _ audio: UnsafeMutablePointer<Int16>) -> [UInt8]? { radioAnswer(p, audio, firstTicks: 0, idleTicks: 0) }
'''
suffix = '''
}
let cases: [(String, [[UInt8]], [UInt8]?, Bool)] = [
 ("valid", [[0xF0,0x0C,0,0],[0xF0,0x0D,3,0],[1,2,3],[0xF0,0x4D]], [1,2,3], true),
 ("split", [[0xF0,0x0D,3,0],[1],[2,3],[0xF0,0x4D]], [1,2,3], true),
 ("empty", [[0xF0,0x0D,0,0],[0xF0,0x4D]], [], true),
 ("finished ack", [[0xF0,0x0C,0,2]], [], true),
 ("ack timeout compatibility", [[0xF0,0x0C,0,0]], [], true),
 ("payload resembles ack", [[0xF0,0x0D,2,0],[0xF0,0x0C],[0xF0,0x4D]], [0xF0,0x0C], true),
 ("truncated", [[0xF0,0x0D,3,0],[1],[0xF0,0x4D]], nil, true),
 ("oversized", [[0xF0,0x0D,3,0],[1,2,3,4],[0xF0,0x4D]], nil, true),
 ("short header", [[0xF0,0x0D,3],[0xF0,0x4D]], nil, true),
 ("short ack", [[0xF0,0x0C,0]], nil, true),
 ("incomplete acknowledged timeout", [[0xF0,0x0C,0,0],[0xF0,0x0D,3,0],[1]], nil, true),
 ("missing", [], nil, true),
 ("failed data request write", [[0xF0,0x0C,0,0]], nil, false)
]
let handle = OpaquePointer(bitPattern: 1)!
let audio = UnsafeMutablePointer<Int16>.allocate(capacity: 1)
var failures = 0
for (name, input, expected, allowed) in cases {
 let replay = Replay(input)
 replay.writeAllowed = allowed
 let actual = replay.invoke(handle, audio)
 let passed = actual == expected
 print("PARTNER " + (passed ? "PASS: " : "FAIL: ") + name)
 if !passed { failures += 1 }
}
audio.deallocate()
print("PARTNER SUMMARY: " + String(cases.count - failures) + " passed; " + String(failures) + " failed")
exit(failures == 0 ? 0 : 1)
'''
def replay(work, name, implementation):
    source = pathlib.Path(work) / (name + '.swift')
    binary = pathlib.Path(work) / name
    source.write_text(prefix + implementation + suffix)
    command(['swiftc', '-swift-version', '5', str(source), '-o', str(binary)])
    p = subprocess.run([str(binary)], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
    return {'exit_code': p.returncode, 'output': p.stdout.splitlines()}
try:
    with tempfile.TemporaryDirectory() as work:
        report['before'] = replay(work, 'before', method())
        patch = root / 'tamaios_changes.patch'
        command(['git', 'apply', '--check', str(patch)])
        command(['git', 'apply', str(patch)])
        report['app_patch_sha256'] = hashlib.sha256(patch.read_bytes()).hexdigest()
        report['after'] = replay(work, 'after', method())
        report['passed'] = report['after']['exit_code'] == 0
except Exception as exc:
    report['error'] = type(exc).__name__ + ': ' + str(exc)
report['log_tail'] = log[-30:]
(out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
raise SystemExit(0 if report['passed'] else 1)
