import hashlib
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
scopes = {'ir': 'IR context/model checks only', 'policy': 'Actual Swift policies, ownership predicate, and patched identity methods/observation guard with stub state holders; firmware semantics, UIKit concurrency and iOS delivery unverified', 'transport': 'Build-patched TamaLink.answer method with synthetic replies; not firmware protocol validation'}
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
def extract(source, marker):
    start = source.index(marker)
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth and end < len(source):
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    if depth:
        raise ValueError('source extraction failed')
    return source[start:end]
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
        patch = root / 'tamaios_changes.patch'
        if patch.exists():
            run(['git', 'apply', '--check', str(patch)])
            run(['git', 'apply', str(patch)])
            report['app_patch_sha256'] = hashlib.sha256(patch.read_bytes()).hexdigest()
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
                method = extract(source, '    func answer(firstTimeout:')
                dependency.write_text('import Foundation\nfinal class TransportReplay {\n enum LinkError: Error { case noAnswer }\n var input: [[UInt8]]\n init(_ input: [[UInt8]]) { self.input = input }\n func read() -> [UInt8]? { input.isEmpty ? nil : input.removeFirst() }\n func write(_ bytes: [UInt8]) throws {}\n func trace(_ text: String) {}\n' + method + '\n}\n')
                files = [str(dependency), 'tools/transport_replay_audit.swift']
            run(['swiftc', '-swift-version', '5', *files, '-o', str(binary)])
            run([str(binary)])
            if kind == 'policy':
                emulator = (root / 'ios/TamaiOS/Core/Emulator.swift').read_text()
                app = (root / 'ios/TamaiOS/App.swift').read_text()
                predicate = extract(emulator, '    var canReplaceDevice: Bool')
                load = extract(emulator, '    func load(_ toy: Toy,')
                assert load.index('guard canReplaceDevice') < load.index('loading = true') < load.index('unload()')
                assert 'guard Thread.isMainThread' in load
                play = extract(app, '    func play(_ toy: Toy)')
                assert play.index('guard emu.canReplaceDevice') < play.index('Prefs.d.set')
                for marker in ['    func remove(_ toy: Toy)', '    func restoreBackup(_ data: Data, into toy: Toy)', '    func reset(_ toy: Toy)', '    func resetCurrentDevice()']:
                    assert 'emu.canReplaceDevice' in extract(app, marker)
                log.append('OWNERSHIP SOURCE GUARDS: verified placement; not an integration test')
                dependency.write_text('import Foundation\nfinal class IRLink { static let shared = IRLink(); var busy = false }\nfinal class AppLink { static let shared = AppLink(); var busy = false; var openForDownload = false }\nfinal class OwnershipReplay { var loading = false; var linkBusy = false; var clockChanging = false; var appWaiting = false; var holdForApp = false\n' + predicate + '\n}\n')
                run(['swiftc', '-swift-version', '5', str(dependency), 'tools/operation_policy_audit.swift', '-o', str(binary)])
                run([str(binary)])
                live = (root / 'ios/TamaiOS/Core/LiveTamaName.swift').read_text()
                methods = '\n'.join(extract(live, marker) for marker in ['    enum Direct:', '    var verifiedName:', '    func observe(deviceID:', '    func applyDirect(', '    private func resolve()'])
                care = (root / 'ios/TamaiOS/Core/CareAlerts.swift').read_text()
                observation = extract(care, '    func observe(mask: Int, deviceID: String, name: String,')
                queue = '        DispatchQueue.main.async {'
                queue_start = observation.index(queue)
                assert not observation[observation.index('{') + 1:queue_start].strip()
                guard_prefix = observation[queue_start + len(queue):observation.index('            let previousIdentity')]
                assert 'guard AppModel.current?.emu.toy?.id == deviceID else {' in guard_prefix
                fixtures = r'''
final class MemoryPreferences {
    var values: [String: String] = [:]
    func string(forKey key: String) -> String? { values[key] }
    func set(_ value: String, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}
enum Prefs { static let d = MemoryPreferences() }
final class UIApplication {
    enum State { case active, inactive, background }
    static let shared = UIApplication()
    var applicationState = State.background
}
struct ReplayToy { let id: String }
final class ReplayEmulator { var toy: ReplayToy? = nil }
final class AppModel { static var current: AppModel? = nil; let emu = ReplayEmulator() }
final class LiveNameReplay {
    var name = "Your Tama", source = "", probeStatus = "", deviceID = "", signature = "", probeName = ""
    var stage = -1, character = -1, cycles = 0
    var identity: String? = nil
    var directName: String? = nil
    var scheduled: UUID? = nil
    var nextCheck: [String: Double] = [:]
    func beginCycle(key: String, delay: Double) { cycles += 1 }
'''
                handoff = r'''
final class CareHandoffReplay {
    var counters: [String: Int] = [:]
    var history: [String] = []
    func count(_ key: String) { counters[key, default: 0] += 1 }
    func record(_ value: String) { history.append(value) }
    func process(deviceID: String, action: () -> Void) {
'''
                checks = r'''
@main
struct LiveNameHandoffAudit {
    static var checks = 0
    static var failures: [String] = []
    static func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        checks += 1
        if !condition() { failures.append(label) }
    }
    static func main() {
        let devices = BundledVariant.all.map(\.filename)
        precondition(devices.count >= 2, "Two bundled devices required")
        let a = devices[0], b = devices[1]
        let live = LiveNameReplay()
        live.observe(deviceID: a, stage: 1, character: 4, signature: "abcd")
        live.applyDirect(.name("Mochi"), deviceID: a)
        let original = live.identity
        expect(original != nil && live.verifiedName == "Mochi" && live.name == "Mochi", "initial verified name")
        for (stage, character, signature) in [(-1, -1, ""), (1, -1, "abcd"), (1, 4, ""), (256, 4, "abcd")] {
            live.observe(deviceID: a, stage: stage, character: character, signature: signature)
            expect(live.identity == original, "same-device gap preserves identity")
            expect(live.name == "Mochi" && live.verifiedName == "Mochi", "same-device gap preserves name")
            expect(live.stage == 1 && live.character == 4 && live.signature == "abcd", "same-device gap preserves metadata")
        }
        live.applyDirect(.unknown, deviceID: a)
        expect(live.name == "Mochi" && live.verifiedName == "Mochi", "unknown direct read preserves verified name")
        live.scheduled = UUID()
        live.observe(deviceID: a, stage: 0, character: -1, signature: "")
        expect(live.identity == nil && live.verifiedName == nil, "stage zero clears live identity")
        expect(live.name == "Your Tama" && live.scheduled == nil, "stage zero clears display and pending probe token")

        let switched = LiveNameReplay()
        switched.observe(deviceID: a, stage: 1, character: 4, signature: "abcd")
        switched.applyDirect(.name("Mochi"), deviceID: a)
        Prefs.d.set("SavedB", forKey: "tamaName.v1." + b)
        switched.scheduled = UUID()
        switched.observe(deviceID: b, stage: -1, character: -1, signature: "")
        expect(switched.deviceID == b, "unknown new device becomes resolver owner")
        expect(switched.identity == nil && switched.verifiedName == nil && switched.directName == nil, "unknown new device clears prior live identity")
        expect(switched.name == "Your Tama" && switched.scheduled == nil, "unknown new device does not display previous name")
        expect(Prefs.d.string(forKey: "tamaName.v1." + a) == "Mochi", "switch retains saved old-device name")
        expect(Prefs.d.string(forKey: "tamaName.v1." + b) == "SavedB", "switch retains saved new-device name")
        switched.applyDirect(.name("WrongDevice"), deviceID: a)
        expect(switched.name == "Your Tama" && switched.verifiedName == nil, "old-device direct result rejected")
        switched.observe(deviceID: b, stage: 1, character: 2, signature: "beef")
        switched.applyDirect(.name("Nova"), deviceID: b)
        expect(switched.name == "Nova" && switched.verifiedName == "Nova", "new-device valid sample recovers name")
        expect(switched.identity == LiveNamePolicy.key(deviceID: b, stage: 1, character: 2, signature: "beef"), "new identity belongs to selected device")

        AppModel.current = AppModel()
        AppModel.current?.emu.toy = ReplayToy(id: b)
        let gate = CareHandoffReplay()
        var accepted = 0
        gate.process(deviceID: a) {
            accepted += 1
            switched.observe(deviceID: a, stage: 1, character: 4, signature: "abcd")
            switched.applyDirect(.name("WrongDevice"), deviceID: a)
        }
        expect(accepted == 0 && switched.name == "Nova" && switched.deviceID == b, "stale queued observation cannot mutate current resolver")
        expect(gate.counters["skipped: stale observation device"] == 1 && gate.history.count == 1, "stale rejection is diagnosed")
        gate.process(deviceID: b) { accepted += 1 }
        expect(accepted == 1, "selected-device observation accepted")
        AppModel.current?.emu.toy = nil
        gate.process(deviceID: b) { accepted += 1 }
        expect(accepted == 1, "observation rejected without selected toy")
        AppModel.current = nil
        gate.process(deviceID: b) { accepted += 1 }
        expect(accepted == 1, "observation rejected without app model")
        expect(gate.counters["skipped: stale observation device"] == 3, "all unavailable-device rejections counted")
        for failure in failures { print("HANDOFF FAIL: " + failure) }
        print("LIVE NAME HANDOFF CHECKS: \(checks - failures.count) passed; \(failures.count) failed")
        print("Scope: extracted patched identity methods and observation guard prefix, with in-memory preferences and synchronous state holders; not UIKit queue scheduling, FFI reads, probe callbacks or notification delivery")
        if !failures.isEmpty { exit(1) }
    }
}
'''
                dependency.write_text('import Foundation\n' + store[start:end] + fixtures + methods + '\n}\n' + handoff + guard_prefix + '\n        action()\n    }\n}\n' + checks)
                run(['swiftc', '-swift-version', '5', str(dependency), 'ios/TamaiOS/Core/CareEventPolicy.swift', '-o', str(binary)])
                run([str(binary)])
    else:
        raise ValueError('unknown test group')
    report['passed'] = True
except Exception as exc:
    report['error'] = type(exc).__name__ + ': ' + str(exc)
report['log_tail'] = log[-60:]
(out / (kind + '.json')).write_text(json.dumps(report, indent=2) + '\n')
(out / (kind + '.txt')).write_text('\n'.join(log) + '\n')
raise SystemExit(0 if report['passed'] else 1)
