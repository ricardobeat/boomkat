#!/usr/bin/env python3
"""Time isolated core-profile builds against matching reference executables."""
from pathlib import Path
import json
import random
import statistics
import struct
import subprocess
import time

root = Path(__file__).resolve().parents[1]
out = root / 'out/core-timings'
out.mkdir(parents=True, exist_ok=True)
rng = random.Random(42)
results = {}
for benchmark in ['loop', 'function_call', 'property_lookup', 'ic_proto', 'array']:
    source = root / 'test' / 'benchmarks' / ('bench_' + benchmark + '.js')
    image = out / (benchmark + '.bkbc')
    old_image = out / (benchmark + '.reference.bkbc')
    subprocess.run([root / 'out/core-compiler/boomkat_tiny_compile', '--compile', image, source],
                   check=True, capture_output=True)
    # These benchmark programs use only the common API subset. Their code is
    # identical across catalogs; adapt only the capability header for reference.
    payload = bytearray(image.read_bytes())
    struct.pack_into('<I', payload, 16, struct.unpack_from('<I', payload, 16)[0] & ~2048)
    old_image.write_bytes(payload)
    commands = {
        'tiny_reference': [root / 'out/baseline-tiny', old_image],
        'tiny_core': [root / 'out/core-pruned/boomkat_tiny', image],
        'tiny_core_size': [root / 'out/no-unwind-core-separate-no-compact/boomkat_tiny', image],
        'normal_reference': [root / 'out/profile-reference/out/normal/boomkat', '--script', source],
        'normal_core': [root / 'out/normal-check/boomkat', '--script', source],
    }
    outputs = [subprocess.check_output(command) for command in commands.values()]
    assert all(output == outputs[0] for output in outputs)
    samples = {name: [] for name in commands}
    for repeat in range(15):
        order = list(commands)
        rng.shuffle(order)
        for name in order:
            start = time.perf_counter()
            subprocess.run(commands[name], check=True, stdout=subprocess.DEVNULL,
                           stderr=subprocess.PIPE, timeout=30)
            samples[name].append(time.perf_counter() - start)
    medians = {name: statistics.median(values) for name, values in samples.items()}
    ratios = {name: value / medians['normal_reference' if name.startswith('normal') else 'tiny_reference']
              for name, value in medians.items()}
    results[benchmark] = {'median_seconds': medians, 'ratios': ratios, 'samples': samples}
    print(benchmark, ratios, flush=True)
(out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
