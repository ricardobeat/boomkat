"""Build baseline, duplicate-lookup-only, and combined constructor binaries."""
import argparse
from pathlib import Path
import shutil
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--work-dir', required=True, type=Path)
args = p.parse_args()
report = Path(__file__).resolve().parent
root = report.parents[2]
revision = 'edb25e2b'
base = args.work_dir.resolve()
base.mkdir(parents=True, exist_ok=True)
for name in ['baseline', 'putnew', 'combined']:
    work = base / ('source-' + name)
    work.mkdir(exist_ok=True)
    archive = subprocess.Popen(['git', 'archive', revision, 'src', 'cli', 'project.json', 'vendor', 'libregexp'],
                               cwd=root, stdout=subprocess.PIPE)
    subprocess.run(['tar', '-xf', '-', '-C', str(work)], stdin=archive.stdout, check=True)
    archive.stdout.close()
    assert archive.wait() == 0
    if name == 'putnew':
        path = work / 'src/vm/vm_property.c3'
        source = path.read_text()
        old = 'hobj.put_prop(key, put_val, hobject::PROP_FLAGS_WEC, ds.vm.heap);'
        new = 'hobj.put_prop_new(key, put_val, hobject::PROP_FLAGS_WEC, ds.vm.heap);'
        assert source.count(old) == 1
        path.write_text(source.replace(old, new))
    elif name == 'combined':
        subprocess.run(['git', 'apply', str(report / 'constructor.patch')], cwd=work, check=True)
    with (base / (name + '-build.txt')).open('w') as log:
        subprocess.run(['c3c', 'build', 'boomkat'], cwd=work, stdout=log, stderr=subprocess.STDOUT, check=True)
    shutil.copy2(work / 'out/boomkat', base / name)
    print('built', name, flush=True)
