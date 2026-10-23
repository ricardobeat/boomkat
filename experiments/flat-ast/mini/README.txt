Octane mini, staged flat-AST comparison

report.txt and summary.csv compare the 15 unchanged mini inputs at optimized
baseline, numeric, primitive and const stages. One complete measured round is
used, as requested: 60/60 processes passed, after a complete warmup round.
These are directional observations with no confidence or stable-speedup claims.

results.json contains the full warmup and selected round; components.csv retains
individual reported timings. Exact input/stage/binary hashes are recorded.
The excluded partial extra round remains in ignored interrupted.json. Local
stage binaries remain in ignored bin/. No further samples were run after stop.

prepare.py rebuilds isolated stages; run.py defaults to one measured round;
summarize.py regenerates the report without executing benchmarks. Source inputs
are referenced by hash and were not edited or copied. No Test262 was run.
