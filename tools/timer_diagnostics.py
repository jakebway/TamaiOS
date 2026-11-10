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
SUMMARY = ROOT / 'audit-results/summary.json'

def decode(path):
    raw = path.read_bytes()
    if raw[:8] != b'T18SNAP1':
        raise ValueError('snapshot magic')
    raw = zlib.decompress(raw[8:])
    chunks = {}
    pos = 0
    while pos < len(raw):
        size = raw[pos]
        pos += 1
        name = raw[pos:pos+size].decode('ascii')
        pos += size
        length, = struct.unpack_from('<I', raw, pos)
        pos += 4
        if name in chunks or pos + length > len(raw):
            raise ValueError('chunk structure')
        chunks[name] = raw[pos:pos+length]
        pos += length
    return chunks

def timers(chunks):
    blob = chunks['timers']
    width = struct.calcsize('<dQB')
    if len(blob) != 6 * width:
        raise ValueError('unexpected timer layout')
    regs_blob = chunks['regs']
    if len(regs_blob) % 8:
        raise ValueError('register layout')
    regs = dict(struct.iter_unpack('<II', regs_blob))
    result = []
    for index in range(6):
        start, periods_seen, pending = struct.unpack_from('<dQB', blob, index * width)
        base = 0xC0020000 + index * 0x20
        ctrl = regs.get(base, 0)
        result.append({'index': index, 'start': start, 'periods_seen': periods_seen, 'pending': bool(pending), 'ctrl': ctrl, 'running': bool(ctrl & 0x2000), 'irq_enabled': bool(ctrl & 0x4000), 'reload': regs.get(base + 8, 0) & 0xffff})
    return result

def run(rom, work, name, seconds, snapshot=None):
    target = pathlib.Path(work) / (name + '.snap')
    args = [str(RUNNER), str(rom), '--seconds', str(seconds), '--date', '2026-11-09 12:00', '--quiet', '--snapshot-out', str(target), '--screenshot', str(pathlib.Path(work) / (name + '.png'))]
    if snapshot is not None:
        args += ['--snapshot-in', str(snapshot)]
    proc = subprocess.run(args, cwd=work, text=True, capture_output=True, timeout=120)
    match = re.search(r'=== result: (.*?) after ', proc.stdout)
    if proc.returncode or not match or match.group(1) != 'Limit' or 'fault:' in proc.stdout.lower():
        raise RuntimeError('diagnostic execution failed')
    return target, decode(target)

def state_metrics(chunks):
    executed, irqs = struct.unpack_from('<QQ', chunks['machine'])
    now, game_time = struct.unpack_from('<dd', chunks['time'])
    return {'executed': executed, 'irqs': irqs, 'now': now, 'game_time': game_time}

base = subprocess.run(['python3', str(ROOT / 'tools/headless_audit.py')], cwd=ROOT)
report = json.loads(SUMMARY.read_text())
report['timer_diagnostics'] = {'scope': 'Additional independent diagnostic runs; fresh 11-second reference is not same-instance uninterrupted checkpoint equivalence', 'runs': []}
diagnostic_failed = False
for rom in sorted((ROOT / 'firmware').glob('*.bin')):
    row = {'firmware': rom.name, 'sha256': hashlib.sha256(rom.read_bytes()).hexdigest()}
    try:
        with tempfile.TemporaryDirectory(prefix='tamaios-timers-') as work:
            checkpoint_path, checkpoint = run(rom, work, 'checkpoint', 10)
            _, restored = run(rom, work, 'restored', 0, checkpoint_path)
            _, continued = run(rom, work, 'continued', 1, checkpoint_path)
            _, reference = run(rom, work, 'fresh-reference', 11)
            before, after = timers(checkpoint), timers(restored)
            row['restore_timer_changes'] = [{'index': a['index'], 'changed_fields': [key for key in a if a[key] != b[key]], 'before': a, 'after': b} for a, b in zip(before, after) if a != b]
            row['metrics'] = {name: state_metrics(data) for name, data in [('checkpoint', checkpoint), ('restored', restored), ('continued', continued), ('fresh_reference', reference)]}
            row['reference_comparison'] = {'cpu_equal': continued['cpu'] == reference['cpu'], 'ram_equal': continued['ram'] == reference['ram'], 'sram_equal': continued['sram'] == reference['sram'], 'timers_equal': continued['timers'] == reference['timers'], 'rtc_equal': continued['rtc'] == reference['rtc'], 'lcd_equal': continued['lcd'] == reference['lcd']}
            row['completed'] = True
    except Exception as exc:
        diagnostic_failed = True
        row.update(completed=False, error_type=type(exc).__name__)
    report['timer_diagnostics']['runs'].append(row)
report['timer_diagnostics']['completed'] = not diagnostic_failed
if diagnostic_failed:
    report['status'] = 'failed'
SUMMARY.write_text(json.dumps(report, indent=2) + '\n')
raise SystemExit(1 if base.returncode or diagnostic_failed else 0)
