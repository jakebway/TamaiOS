import ast
import hashlib
import json
import os
import pathlib
import subprocess
import sys

BASE = '700f7c85062508b851d53b2782bd23ff03262960'
PATCH_BLOB = '459ba2a75a3d2cc5947435d89a85149e6108e010'
BRANCH = 'audit/firmware-grounded-validation'
ROOT = pathlib.Path.cwd()
MANIFEST = 'docs/swift-source-consolidation.json'
SWIFT = {
    'ios/TamaiOS/App.swift', 'ios/TamaiOS/Core/Emulator.swift',
    'ios/TamaiOS/Core/IRLink.swift', 'ios/TamaiOS/Core/LiveTamaName.swift',
    'ios/TamaiOS/Core/CareAlerts.swift', 'ios/TamaiOS/Tamatown/TamaLink.swift',
}
RUNNERS = {'tools/run_expanded_audit.py', 'tools/run_integration_audit.py', 'tools/partner_reply_audit.py'}
CORE = ['patches/radio.patch', 'patches/ir_partner.patch', 'tools/timer_snapshot_history.patch', 'tools/prepare_core.py']
def git(*args):
    return subprocess.check_output(['git', *args], text=True).strip()
def require(ok, reason):
    if not ok: raise RuntimeError(reason)
def digest(path):
    return hashlib.sha256((ROOT / path).read_bytes()).hexdigest()
def swift_hashes():
    paths = git('ls-files', '--', 'ios/TamaiOS').splitlines()
    return {p: digest(p) for p in sorted(paths) if p.endswith('.swift')}
def verify():
    m = json.loads((ROOT / MANIFEST).read_text())
    require(not (ROOT / 'tamaios_changes.patch').exists(), 'Legacy Swift patch was reintroduced')
    require(swift_hashes() == m['expected_built_swift_sha256'], 'Swift bytes differ from the consolidation baseline')
    require({p: digest(p) for p in CORE} == m['unchanged_core_sha256'], 'Core preparation changed during consolidation')
    for p, expected in m['expected_built_swift_sha256'].items():
        actual = hashlib.sha256(subprocess.check_output(['git', 'show', 'HEAD:' + p])).hexdigest()
        require(actual == expected, 'Committed Swift bytes differ: ' + p)
def rewrite_runner(path, indent, driver, optional):
    p = ROOT / path
    text = p.read_text()
    inner = indent + ('    ' if optional else '')
    lines = [indent + "patch = root / 'tamaios_changes.patch'"]
    if optional: lines.append(indent + 'if patch.exists():')
    lines += [inner + driver + "(['git', 'apply', '--check', str(patch)])",
              inner + driver + "(['git', 'apply', str(patch)])",
              inner + "report['app_patch_sha256'] = hashlib.sha256(patch.read_bytes()).hexdigest()"]
    block = '\n'.join(lines) + '\n'
    require(text.count(block) == 1, 'Unexpected patch preparation in ' + path)
    replacement = indent + "report['source_mode'] = 'tracked-source'\n"
    replacement += indent + "report['app_source_tree_sha256'] = hashlib.sha256(json.dumps({str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((root / 'ios/TamaiOS').rglob('*.swift'))}, sort_keys=True).encode()).hexdigest()\n"
    text = text.replace(block, replacement)
    if path.endswith('partner_reply_audit.py'):
        before = "        report['before'] = replay(work, 'before', method())\n"
        require(text.count(before) == 1 and text.count("report['after']") == 2, 'Unexpected partner replay structure')
        text = text.replace(before, '').replace("report['after']", "report['current']")
    text = text.replace('Build-patched TamaLink.answer', 'Tracked-source TamaLink.answer').replace('patched identity methods', 'tracked identity methods').replace('extracted patched identity', 'extracted tracked identity')
    ast.parse(text)
    p.write_text(text)
def prepare():
    require(os.environ.get('GITHUB_REPOSITORY') == 'jakebway/TamaiOS', 'Wrong repository')
    require(os.environ.get('GITHUB_REF') == 'refs/heads/' + BRANCH, 'Wrong branch')
    require(git('rev-parse', 'HEAD^') == BASE, 'Audit branch moved; review a new consolidation target')
    bootstrap = {'.github/workflows/consolidate-swift-sources.yml', 'tools/consolidate_swift_sources.py'}
    require(set(git('diff', '--name-only', BASE, 'HEAD').splitlines()) == bootstrap, 'Unexpected bootstrap changes')
    require(not git('status', '--porcelain'), 'Checkout must be clean')
    require(git('hash-object', 'tamaios_changes.patch') == PATCH_BLOB, 'Patch identity changed')
    patch = ROOT / 'tamaios_changes.patch'
    targets = {line[6:] for line in patch.read_text().splitlines() if line.startswith('+++ b/')}
    require(targets == SWIFT, 'Unexpected Swift patch targets')
    core = {p: digest(p) for p in CORE}
    subprocess.run(['git', 'apply', '--check', str(patch)], check=True)
    subprocess.run(['git', 'apply', str(patch)], check=True)
    require(set(git('diff', '--name-only').splitlines()) == SWIFT, 'Unexpected source changes')
    expected = swift_hashes()
    rewrite_runner('tools/run_expanded_audit.py', '        ', 'run', True)
    rewrite_runner('tools/run_integration_audit.py', '    ', 'run', True)
    rewrite_runner('tools/partner_reply_audit.py', '        ', 'command', False)
    replay = ROOT / 'tools/transport_replay_audit.swift'
    text = replay.read_text()
    require(text.count('build-patched answer method') == 1, 'Unexpected transport scope label')
    replay.write_text(text.replace('build-patched answer method', 'tracked-source answer method'))
    patch.unlink()
    require(swift_hashes() == expected, 'Runtime Swift bytes changed during cleanup')
    manifest = {'base_commit': BASE, 'bootstrap_commit': git('rev-parse', 'HEAD'),
                'retired_patch_blob': PATCH_BLOB, 'swift_matches_previous_build_input': True,
                'expected_built_swift_sha256': expected, 'unchanged_core_sha256': core,
                'scope': 'Byte-equivalent Swift consolidation; no egg/death fix, main merge, installation or notification-delivery claim'}
    (ROOT / MANIFEST).write_text(json.dumps(manifest, indent=2) + '\n')
    allowed = SWIFT | RUNNERS | {'tools/transport_replay_audit.swift', MANIFEST, 'tamaios_changes.patch'}
    subprocess.run(['git', 'add', '-A', '--', *sorted(allowed)], check=True)
    require(set(git('diff', '--cached', '--name-only').splitlines()) == allowed, 'Unexpected staged files')
    subprocess.run(['git', '-c', 'user.name=github-actions[bot]', '-c', 'user.email=41898282+github-actions[bot]@users.noreply.github.com', 'commit', '-m', 'refactor: consolidate build-patched Swift into tracked sources'], check=True)
    verify()
if __name__ == '__main__':
    if sys.argv[1:] == ['--verify']: verify()
    else: prepare()
