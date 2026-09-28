"""Build isolated comparison binaries from the recorded baseline and patches."""
from pathlib import Path
import argparse, json, subprocess, shutil
p = argparse.ArgumentParser()
p.add_argument('--work-dir', required=True, type=Path)
p.add_argument('--variants', nargs='+', default=['baseline', 'frames', 'arrays', 'combined', 'baseline-clock', 'combined-clock', 'two-slots'])
a = p.parse_args()
report = Path(__file__).resolve().parent
root = report.parents[2]
base = a.work_dir.resolve()
base.mkdir(parents=True, exist_ok=True)
revision = json.loads((report / 'manifest.json').read_text())['baseline_revision']
for name in a.variants:
    work = base / ('source-' + name)
    work.mkdir(exist_ok=True)
    archive = subprocess.Popen(['git', 'archive', revision, 'src', 'cli', 'project.json', 'vendor', 'libregexp'], cwd=root, stdout=subprocess.PIPE)
    subprocess.run(['tar', '-xf', '-', '-C', str(work)], stdin=archive.stdout, check=True)
    archive.stdout.close()
    assert archive.wait() == 0
    patches = []
    if name in ['frames', 'combined', 'combined-clock', 'two-slots']:
        patches.append('frames.patch')
    if name in ['arrays', 'combined', 'combined-clock', 'two-slots']:
        patches.append('arrays.patch')
    if name == 'two-slots':
        patches.append('two-slots.patch')
    for patch in patches:
        subprocess.run(['git', 'apply', str(report / patch)], cwd=work, check=True)
    if name.endswith('-clock'):
        path = work / 'src/builtins/date.c3'
        text = path.read_text().replace('fn void builtin_date_now(BuiltinContext* ctx) {', 'fn void builtin_date_now(BuiltinContext* ctx) {\n    if (ctx.argc == 1) {ctx.result_number((double)(long)clock::now() / 1000000.0);return;}')
        path.write_text(text)
    with (base / (name + '-build.txt')).open('w') as log:
        subprocess.run(['c3c', 'build', 'boomkat'], cwd=work, stdout=log, stderr=subprocess.STDOUT, check=True)
    shutil.copy2(work / 'out/boomkat', base / name)
    print('built', name, flush=True)
