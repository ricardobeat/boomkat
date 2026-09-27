# CPU prototype workloads (plan 093)

Checked workloads for retained and archived experiments. Run scripts through
explicit immutable release binaries. Always alternate baseline and candidate:

```sh
python3 scripts/bench_interleaved.py /path/to/baseline /path/to/candidate benchmarks/cpu093/*.js --out /tmp/cpu093-results
```

The runner warms both binaries, swaps the leading binary on each pair, checks
output equality, and saves raw timings, peak RSS, paired changes, and dispersion.
It uses macOS `/usr/bin/time -l`. Do not run builds or other benchmarks alongside
it. Large host-load shifts can distort separate medians; inspect adjacent paired
ratios and their spread. `scripts/bench_collection_counts.py` supplies track A's
workloads, including size scans and tiny retained collections.

`frame_tail.js` and the two `allocation_*.js` workloads reproduce archived
experiments. Their presence does not mean those code changes were retained.
`map_boundary.js` and `set_boundary.js` use 256 live entries; neighboring 257-entry
controls are made by replacing both size literals while keeping 200,000 queries.
The churn workloads keep 8,192 live entries through 100 populations of replacement
and check two million hit/miss pairs. They retain the ordered log deliberately.
