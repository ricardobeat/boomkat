"""Build isolated before/after binaries with the same diagnostic clock hook."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--work-dir', required=True, type=Path)
args = p.parse_args()
report = Path(__file__).resolve().parent
root = report.parents[2]
revision = json.loads((report / 'manifest.json').read_text())['baseline_revision']
base = args.work_dir.resolve()
base.mkdir(parents=True, exist_ok=True)
for name in ['baseline', 'combined']:
    work = base / ('source-' + name + '-clock')
    work.mkdir(exist_ok=True)
    archive = subprocess.Popen(['git', 'archive', revision, 'src', 'cli', 'project.json', 'vendor', 'libregexp'],
                               cwd=root, stdout=subprocess.PIPE)
    subprocess.run(['tar', '-xf', '-', '-C', str(work)], stdin=archive.stdout, check=True)
    archive.stdout.close()
    assert archive.wait() == 0
    if name == 'combined':
        subprocess.run(['git', 'apply', str(report / 'runtime.patch')], cwd=work, check=True)
    path = work / 'src/builtins/date.c3'
    text = path.read_text()
    marker = 'fn void builtin_date_now(BuiltinContext* ctx) {'
    assert text.count(marker) == 1
    path.write_text(text.replace(marker, marker + '\n    if (ctx.argc == 1) {ctx.result_number((double)(long)clock::now() / 1000000.0);return;}'))
    with (base / (name + '-clock-build.txt')).open('w') as log:
        subprocess.run(['c3c', 'build', 'boomkat'], cwd=work, stdout=log, stderr=subprocess.STDOUT, check=True)
    shutil.copy2(work / 'out/boomkat', base / (name + '-clock'))
    print('built', name + '-clock', flush=True)
