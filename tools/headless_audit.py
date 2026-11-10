import hashlib
import json
import pathlib
import re
import struct
import subprocess
import tempfile
import zlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
RUNNER = ROOT / 'upstream/target/release/tg18cli'
OUT = ROOT / 'audit-results'
OUT.mkdir(exist_ok=True)

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def chunks(path):
    data = path.read_bytes()
    if data[:8] != b'T18SNAP1':
        raise ValueError('snapshot magic')
    data = zlib.decompress(data[8:])
    result = {}
    pos = 0
    while pos < len(data):
        n = data[pos]
        pos += 1
        name = data[pos:pos+n].decode('ascii')
        pos += n
        size, = struct.unpack_from('<I', data, pos)
        pos += 4
        if name in result or pos + size > len(data):
            raise ValueError('snapshot chunk structure')
        result[name] = data[pos:pos+size]
        pos += size
    for name in ('info', 'cpu', 'machine', 'time', 'ram', 'sram', 'rtc', 'lcd'):
        if name not in result:
            raise ValueError('missing required chunk')
    return result

def normalized(data):
    result = dict(data)
    result['info'] = result['info'][:8]
    if 'extra' in result:
        blob = result['extra']
        width = 4 + 65536
        if len(blob) % width:
            raise ValueError('extra page size')
        pages = [blob[i:i+width] for i in range(0, len(blob), width)]
        result['extra'] = b''.join(sorted(pages, key=lambda p: struct.unpack_from('<I', p)[0]))
    return result

def differences(left, right):
    a, b = normalized(left), normalized(right)
    return [name for name in sorted(a.keys() | b.keys()) if a.get(name) != b.get(name)]

def metrics(data):
    executed, irqs = struct.unpack_from('<QQ', data['machine'])
    now, game_time = struct.unpack_from('<dd', data['time'])
    return {'executed': executed, 'irqs': irqs, 'now': now, 'game_time': game_time}

def run(rom, work, name, seconds, snapshot=None):
    target = pathlib.Path(work) / (name + '.snap')
    args = [str(RUNNER), str(rom), '--seconds', str(seconds), '--date', '2026-11-09 12:00', '--quiet', '--screenshot', str(pathlib.Path(work) / (name + '.png')), '--snapshot-out', str(target)]
    if snapshot is not None:
        args += ['--snapshot-in', str(snapshot)]
    proc = subprocess.run(args, cwd=work, capture_output=True, text=True, timeout=120)
    match = re.search(r'=== result: (.*?) after ', proc.stdout)
    outcome = match.group(1) if match else None
    if proc.returncode != 0 or outcome != 'Limit' or 'fault:' in proc.stdout.lower():
        raise RuntimeError('headless execution failed')
    data = chunks(target)
    return target, data, {'outcome': outcome, 'exit_code': proc.returncode, **metrics(data)}

report = {
    'scope': 'Patched core CLI fresh boot, snapshot round trip and independent continuation only; not iOS FFI, notifications, Bluetooth or IR validation',
    'app_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
    'core_commit': subprocess.check_output(['git', '-C', 'upstream', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
    'patches': {str(p.relative_to(ROOT)): digest(p) for p in sorted((ROOT / 'patches').glob('*.patch'))},
    'normalization': ['info capture timestamp excluded; ROM code hash retained', 'extra memory pages sorted by address'],
    'runs': []
}
roms = sorted((ROOT / 'firmware').glob('*.bin'))
for rom in roms:
    row = {'firmware': rom.name, 'sha256': digest(rom), 'passed': False}
    try:
        with tempfile.TemporaryDirectory(prefix='tamaios-audit-') as work:
            initial_path, initial, initial_metrics = run(rom, work, 'boot', 10)
            initial_hash = digest(initial_path)
            _, restored, restored_metrics = run(rom, work, 'restore-zero', 0, initial_path)
            _, continued_a, a_metrics = run(rom, work, 'continue-a', 1, initial_path)
            _, continued_b, b_metrics = run(rom, work, 'continue-b', 1, initial_path)
            roundtrip_diff = differences(initial, restored)
            repeat_diff = differences(continued_a, continued_b)
            checks = {
                'boot_progress': initial_metrics['executed'] > 0 and initial_metrics['now'] > 0,
                'zero_step_roundtrip': not roundtrip_diff,
                'continuation_progress': a_metrics['executed'] > initial_metrics['executed'] and a_metrics['now'] > initial_metrics['now'],
                'independent_resume_repeatability': not repeat_diff,
                'input_snapshot_unchanged': digest(initial_path) == initial_hash
            }
            row.update(checks=checks, roundtrip_differing_chunks=roundtrip_diff, repeatability_differing_chunks=repeat_diff, metrics={'boot': initial_metrics, 'restored': restored_metrics, 'continued_a': a_metrics, 'continued_b': b_metrics}, passed=all(checks.values()))
    except Exception as exc:
        row['error_type'] = type(exc).__name__
    report['runs'].append(row)
report['status'] = 'passed' if roms and all(r['passed'] for r in report['runs']) else 'failed'
if not roms:
    report['reason'] = 'No firmware/*.bin files; no tests executed.'
(OUT / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
raise SystemExit(0 if report['status'] == 'passed' else 1)
