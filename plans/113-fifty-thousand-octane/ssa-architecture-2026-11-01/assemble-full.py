"""Reassemble the measured original suite: python assemble-full.py OCTANE_DIR OUTPUT."""
from pathlib import Path
import hashlib
import json
import re
import sys

root, output = map(Path, sys.argv[1:3])
metadata = json.loads(Path(__file__).with_name('full-octane-inputs.json').read_text())
for name, expected in metadata['inputs'].items():
    actual = hashlib.sha256((root / name).read_bytes()).hexdigest()
    if actual != expected:
        raise SystemExit(f'Input hash mismatch: {name}')
shim = 'var read = function(path) { throw new Error("unexpected shell read: " + path); };\n'
bundle = shim + re.sub(r"load\(base_dir \+ '([^']+)'\);",
                       lambda m: (root / m[1]).read_text(),
                       (root / 'run.js').read_text())
if hashlib.sha256(bundle.encode()).hexdigest() != metadata['bundle_sha256']:
    raise SystemExit('Assembled bundle hash mismatch')
output.write_text(bundle)
print(metadata['bundle_sha256'])
