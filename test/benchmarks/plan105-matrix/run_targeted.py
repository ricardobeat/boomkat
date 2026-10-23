#!/usr/bin/env python3
"""Measure operation-specific workloads sequentially after the mini-suite screen."""
import argparse
import json
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pairs', type=int, default=3)
    args = parser.parse_args()
    root = Path('test/benchmarks')
    fixtures = root/'plan105-matrix'
    out = Path('out/plan105-matrix')
    cases = {
        'lazy-prototypes': [root/'allocation-study/closures.js'],
        'constructor-8': [fixtures/'constructors.js'],
        'ctor-last': [fixtures/'constructors.js'],
        'ctor-highwater': [fixtures/'constructors.js'],
        'sized-objects': [fixtures/'constructors.js', root/'shape-study/object-layout.js'],
        'flat-literals': [root/'shape-study/object-layout.js', fixtures/'mixed-construction.js'],
        'enum-json': [fixtures/'enumeration.js'],
        'enum-full': [fixtures/'enumeration.js'],
        'negative-read': [fixtures/'optional-reads.js'],
        'computed-dict': [fixtures/'dictionaries.js'],
        'fresh-key-dict': [fixtures/'dictionaries.js'],
        'pic-two': [root/'shape-study/own-polymorphism.js'],
        'pic-four': [root/'shape-study/own-polymorphism.js'],
        'pic-shared-action': [root/'shape-study/own-polymorphism.js'],
    }
    results = {}
    for name, files in cases.items():
        raw = out/(name+'-targeted.json')
        command = [sys.executable, str(root/'allocation-study/measure.py'),
                   str(out/'baseline-51e0e10e'), str(out/name), *map(str, files),
                   '--pairs', str(args.pairs), '--out', str(raw)]
        print('START', name, flush=True)
        with (out/(name+'-targeted.log')).open('w') as log:
            process = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
        results[name] = dict(returncode=process.returncode)
        if process.returncode == 0:
            data = json.loads(raw.read_text())
            results[name]['rows'] = [dict(file=r['file'], cpu_percent=100*(r['medians']['cpu'][1]/r['medians']['cpu'][0]-1),rss=r['rss']) for r in data['rows']]
        else:
            results[name]['error'] = (out/(name+'-targeted.log')).read_text()[-3000:]
        (out/'targeted-attempts.json').write_text(json.dumps(results, indent=2)+'\n')
        print('RESULT',name,results[name],flush=True)


if __name__ == '__main__':
    main()
