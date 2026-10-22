#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
for mode in off annotations infer annotations-compact; do
  ./out/boomkat "--numeric-specialization=$mode" --script experiments/ts-numeric/regression.ts
  ./out/boomkat "--numeric-specialization=$mode" experiments/ts-numeric/regression.ts
  ./out/boomkat "--numeric-specialization=$mode" --script experiments/ts-numeric/sloppy.ts
done
./out/boomkat_debug --numeric-specialization=annotations experiments/ts-numeric/regression.ts
./out/boomkat_debug --numeric-specialization=annotations-compact experiments/ts-numeric/regression.ts
./out/boomkat_debug --numeric-specialization=annotations --no-optimize experiments/ts-numeric/regression.ts
for fixture in threaded_numeric_ops strictness_does_not_leak arguments_register; do
  ./out/boomkat --numeric-specialization=infer --script "test/$fixture.js"
done
mkdir -p experiments/ts-numeric/generated
cat > experiments/ts-numeric/generated/engine-annotations <<'WRAPPER'
#!/bin/sh
exec "$BK_EXPERIMENT_BIN" --numeric-specialization=annotations "$@"
WRAPPER
chmod +x experiments/ts-numeric/generated/engine-annotations
export BK_EXPERIMENT_BIN="$PWD/out/boomkat"
BIN=./experiments/ts-numeric/generated/engine-annotations bash test/typescript/run.sh
