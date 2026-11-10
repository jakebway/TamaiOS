import hashlib
import json
import os
import pathlib
import subprocess
import tempfile

root = pathlib.Path.cwd()
out = root / 'partner-results'
out.mkdir(exist_ok=True)
report = {'commit': os.environ['GITHUB_SHA'], 'passed': False, 'scope': 'Partner reply, scene-release policy and audio-buffer replays; no firmware homecoming, save success, worker concurrency, energy measurement or phone lifecycle claim'}
log = []
def command(args):
    p = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
    log.extend(p.stdout.splitlines())
    if p.returncode:
        raise RuntimeError('command failed: ' + str(p.returncode))
def method(marker='    fileprivate func radioAnswer('):
    text = (root / 'ios/TamaiOS/Core/IRLink.swift').read_text()
    start = text.index(marker)
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
def audio_buffer_replay(work):
    def extract(text, marker):
        start = text.index(marker)
        end = text.index('{', start) + 1
        depth = 1
        while depth and end < len(text):
            depth += (text[end] == '{') - (text[end] == '}')
            end += 1
        if depth: raise ValueError('audio source extraction failed')
        return text[start:end]
    audio = (root / 'ios/TamaiOS/Core/Audio.swift').read_text()
    policies = (root / 'ios/TamaiOS/Core/CareEventPolicy.swift').read_text()
    actual = '\n'.join(extract(audio, marker) for marker in ['    private func setForegroundAudible(', '    private func pull(', '    func push(', '    var queued:'])
    fixture = r'''import Foundation
import os
'''+extract(policies, 'struct ForegroundPlaybackPolicy {')+r'''
final class AudioOut {
 static let rate = 44100.0
 let cap = 88200
 let ring = UnsafeMutablePointer<Float>.allocate(capacity: 88200)
 let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
 var head = 0, count = 0, underruns = 0
 var priming = true, muted = false, foregroundAudible = false
 var minFill = 0.0, maxFill = 1.0
 init() { ring.initialize(repeating: 0, count: cap); lock.initialize(to: os_unfair_lock()) }
 deinit { ring.deinitialize(count: cap); ring.deallocate(); lock.deinitialize(count: 1); lock.deallocate() }
 func transition(_ active: Bool) { setForegroundAudible(active) }
 func enqueue(_ samples: [Int16]) { samples.withUnsafeBufferPointer { b in if let p = b.baseAddress { push(p, b.count) } } }
 func render(_ n: Int) -> [Float] {
  var out = [Float](repeating: 9, count: n)
  out.withUnsafeMutableBufferPointer { pull($0.baseAddress!, n) }
  return out
 }
'''+actual+r'''
}
let replay = AudioOut()
let wave: [Int16] = [-32768,-16384,0,16384,32767]
let expected = wave.map { Float($0) / 32768.0 }
var checks = 0
func check(_ ok: Bool, _ message: String) { checks += 1; if !ok { fatalError("AUDIO BUFFER FAIL: " + message) } }
check(replay.queued == 0, "initially empty")
replay.transition(true); replay.enqueue(wave)
check(replay.queued == wave.count, "foreground samples queued")
check(replay.render(wave.count) == expected, "foreground conversion and playback preserved")
replay.enqueue(wave); replay.transition(false)
check(replay.queued == 0, "background transition clears queue")
let storage = Array(UnsafeBufferPointer(start: replay.ring, count: replay.cap))
for _ in 0..<200 { replay.enqueue(wave) }
check(replay.queued == 0, "background samples never accumulate")
check(Array(UnsafeBufferPointer(start: replay.ring, count: replay.cap)) == storage, "background push never writes sample storage")
check(replay.render(8) == [Float](repeating: 0, count: 8), "background renders silence")
replay.transition(true)
check(replay.render(8) == [Float](repeating: 0, count: 8), "no old beep after foreground return")
replay.enqueue(wave)
check(replay.render(wave.count) == expected, "new foreground audio resumes")
replay.muted = true; replay.enqueue(wave)
check(replay.render(wave.count) == [Float](repeating: 0, count: wave.count), "foreground mute remains effective")
replay.muted = false
wave.withUnsafeBufferPointer { replay.push($0.baseAddress!, 0) }
check(replay.queued == 0, "zero-length push remains harmless")
for _ in 0..<10 {
 replay.transition(false); replay.enqueue(wave)
 check(replay.queued == 0, "repeated background transition stays empty")
 check(replay.render(wave.count) == [Float](repeating: 0, count: wave.count), "repeated background remains silent")
 replay.transition(true); replay.enqueue(wave)
 check(replay.render(wave.count) == expected, "repeated foreground playback recovers")
}
print("AUDIO BUFFER CHECKS PASSED: " + String(checks))
print("Scope: actual buffer methods with synthetic samples and native locks; not AVAudioEngine lifecycle, notification delivery, energy measurement or a thread-race proof")
'''
    source = pathlib.Path(work) / 'audio-buffer.swift'
    binary = pathlib.Path(work) / 'audio-buffer'
    source.write_text(fixture)
    command(['swiftc', '-swift-version', '5', str(source), '-o', str(binary)])
    p = subprocess.run([str(binary)], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
    return {'exit_code': p.returncode, 'output': p.stdout.splitlines(), 'source_sha256': hashlib.sha256(audio.encode()).hexdigest(), 'scope': 'Source-extracted buffer replay only; no battery saving or iOS background-execution guarantee'}
try:
    with tempfile.TemporaryDirectory() as work:
        report['source_mode'] = 'tracked-source'
        report['app_source_tree_sha256'] = hashlib.sha256(json.dumps({str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((root / 'ios/TamaiOS').rglob('*.swift'))}, sort_keys=True).encode()).hexdigest()
        report['current'] = replay(work, 'after', method())
        watch = method('    func watch(')
        assert watch.index('guard !active, !starting') < watch.index('let room =') < watch.index('quietUntil = 0')
        assert 'ToyScreen.isRoom(chain: ToyScreen.chain(core: h), deviceID: deviceID)' in watch
        worker = watch.index('run(emu: emu, me: me, partner: partner, mode: mode, role: role)')
        assert watch.index('starting = false', worker) > worker
        binary = pathlib.Path(work) / 'scene-release'
        command(['swiftc', '-swift-version', '5', 'ios/TamaiOS/Core/SceneReleasePolicy.swift', 'tools/scene_release_audit.swift', '-o', str(binary)])
        p = subprocess.run([str(binary)], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
        report['scene_release'] = {'exit_code': p.returncode, 'output': p.stdout.splitlines(), 'scope': 'Actual release policy with synthetic observations plus source-placement assertions; not a firmware, save-completion or concurrency test'}
        report['audio_buffer'] = audio_buffer_replay(work)
        report['passed'] = report['current']['exit_code'] == 0 and p.returncode == 0 and report['audio_buffer']['exit_code'] == 0
except Exception as exc:
    report['error'] = type(exc).__name__ + ': ' + str(exc)
report['log_tail'] = log[-30:]
(out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
raise SystemExit(0 if report['passed'] else 1)
