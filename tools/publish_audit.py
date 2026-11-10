import json
import os
import pathlib
import subprocess

root = pathlib.Path('audit-results')
root.mkdir(exist_ok=True)
report = {'commit': os.environ['GITHUB_SHA'], 'branch': os.environ['GITHUB_REF_NAME'], 'run_id': os.environ['GITHUB_RUN_ID'], 'run_attempt': os.environ['GITHUB_RUN_ATTEMPT'], 'steps': {name: os.environ.get(name, 'unknown') for name in ['PREPARE', 'TIMER', 'ISOLATION', 'SNAPSHOT']}, 'scope': 'Native core tests only. Isolation uses synthetic data. Radio snapshot characterization passing confirms an omission, not working connection persistence. Bluetooth/IR gameplay, notifications and iOS remain unverified.'}
summary = root / 'summary.json'
if summary.exists():
    source = json.loads(summary.read_text())
    report['summary_commit'] = source.get('app_commit')
    report['strict_snapshot_status'] = source.get('status')
    report['firmware_checks'] = [{key: row[key] for key in ['firmware', 'checks', 'roundtrip_differing_chunks', 'repeatability_differing_chunks', 'error_type'] if key in row} for row in source.get('runs', [])]
    diagnostics = source.get('timer_diagnostics')
    if isinstance(diagnostics, dict):
        report['timer_diagnostics'] = {'present': True, **diagnostics}
    else:
        report['timer_diagnostics'] = {'present': False, 'completed': None, 'reason': 'No field-level timer diagnostic section in summary'}
else:
    report['summary_missing'] = True
    report['timer_diagnostics'] = {'present': False, 'completed': None, 'reason': 'Summary missing; diagnostic completion unknown'}
report['native_results'] = {}
for name in ['timer', 'isolation']:
    path = root / (name + '-tests.txt')
    report['native_results'][name] = [line for line in path.read_text(errors='replace').splitlines() if line.startswith('test result:')][:10] if path.exists() else ['No result log']
body = 'Automated audit report. Step outcomes and strict snapshot differences are separate; do not interpret a passing characterization as a fixed limitation. Timer diagnostic completion does not imply strict snapshot equality.\n\n```json\n' + json.dumps(report, indent=2) + '\n```\n'
path = root / 'published-report.md'
path.write_text(body)
subprocess.run(['gh', 'issue', 'create', '--repo', os.environ['GITHUB_REPOSITORY'], '--title', 'TamaiOS audit results ' + os.environ['GITHUB_SHA'][:12] + ' run ' + os.environ['GITHUB_RUN_ID'] + '.' + os.environ['GITHUB_RUN_ATTEMPT'], '--body-file', str(path)], check=True)
