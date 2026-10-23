#!/usr/bin/env python3
"""Render only measured round zero: single-run observations, no inference."""
import csv,json
from pathlib import Path
HERE=Path(__file__).resolve().parent
STAGES=['baseline','numeric','primitive','const']
D=json.loads((HERE/'results.json').read_text())
used=[s for s in D['samples'] if s['round']==0]
assert len(used)==len(D['sources'])*len(STAGES)==60
rows=[];component_rows=[]
def pct(a,b):return 100*(a/b-1) if b else None
def fmt(v):return 'n/a' if v is None else f'{v:+.1f}%'
for source in D['sources']:
 group={s['stage']:s for s in used if s['name']==source['name']}
 assert set(group)==set(STAGES)
 labels={tuple(sorted(s['reported_ms'])) for s in group.values()}
 assert len(labels)==1,'timing labels differ: '+source['name']
 for i,stage in enumerate(STAGES):
  sample=group[stage];base=group['baseline'];prev=group[STAGES[max(i-1,0)]]
  assert sample['success'] and sample['returncode']==0,'failed benchmark: '+source['name']
  row=dict(name=source['name'],stage=stage,reported_ms=sample['reported_total_ms'],wall_ms=sample['wall_s']*1000,rss_mib=sample['peak_rss_bytes']/1048576,outside_reported_ms=sample['wall_s']*1000-sample['reported_total_ms'],reported_vs_baseline_pct=pct(sample['reported_total_ms'],base['reported_total_ms']),reported_vs_previous_pct=pct(sample['reported_total_ms'],prev['reported_total_ms']),wall_vs_baseline_pct=pct(sample['wall_s'],base['wall_s']),wall_vs_previous_pct=pct(sample['wall_s'],prev['wall_s']))
  rows.append(row)
  for label,value in sample['reported_ms'].items():component_rows.append(dict(name=source['name'],benchmark=label,stage=stage,reported_ms=value))
for filename,items in [('summary.csv',rows),('components.csv',component_rows)]:
 with (HERE/filename).open('w') as f:
  w=csv.DictWriter(f,fieldnames=list(items[0]));w.writeheader();w.writerows(items)
text=[]
def line(s=''):text.append(s)
line('Octane mini: one measured round across cumulative flat-AST stages')
line('All 15 inputs x 4 stages completed with exit zero, matching timing labels,')
line('and TearDown validation before timing output. No pre-existing failures observed.')
line('These are single observations, not medians, confidence estimates or stable wins.')
line('One complete warmup round preceded the selected measured round (round zero).')
line('The original five-round driver was stopped at the user\'s request. Its completed')
line(f"partial extra round ({D.get('retained_extra_measured_samples_not_used',0)} samples) is retained locally in ignored interrupted.json, excluded here.")
line('No further samples were run after the driver was stopped.')
line()
line('Stages (each optimized with the same C3 toolchain/default boomkat O2 target):')
for s in D['stages']:line('  '+s['name'].ljust(10)+s['source_revision'])
line(D['compiler'].strip());line(D['platform'])
line()
line('Method and limits')
line('Inputs were read unchanged from the Octane worktree bench/mini directory.')
line('Source SHA-256 hashes, script hashes, stage commits and binary hashes are recorded.')
line('Each child ran serially with --script; stage order was rotated and reversed.')
line('The injected mini driver executes Setup, starts Date.now, runs its fixed loop,')
line('then stops the timer and invokes TearDown. Its timer therefore excludes initial')
line('source parsing, Setup and TearDown; dynamic work inside b.run remains included.')
line('Process wall time includes all of those phases, startup and teardown. The gap')
line('between wall and reported time is NOT a pure compilation-time measurement.')
line('RSS is per-child wait4 peak RSS, converted from bytes to MiB on macOS.')
line('There was no CPU affinity/frequency lock or system-wide isolation. Date.now has')
line('1 ms granularity, and individual component timings can be short. Do not interpret')
line('small percentage changes or reversals between stages as causal improvements.')
line('These fixed-iteration mini timings are not official Octane scores; no aggregate')
line('score or confidence interval is reported.')
line()
line('Reported milliseconds (sum of sub-benchmarks in each input)')
line(f"{'input':16} {'base':>8} {'numeric':>8} {'primitive':>10} {'const':>8} {'num/base':>10} {'prim/num':>10} {'const/prim':>12} {'const/base':>12}")
for source in D['sources']:
 g={r['stage']:r for r in rows if r['name']==source['name']}
 line(f"{source['name']:16} {g['baseline']['reported_ms']:8.0f} {g['numeric']['reported_ms']:8.0f} {g['primitive']['reported_ms']:10.0f} {g['const']['reported_ms']:8.0f} {fmt(g['numeric']['reported_vs_previous_pct']):>10} {fmt(g['primitive']['reported_vs_previous_pct']):>10} {fmt(g['const']['reported_vs_previous_pct']):>12} {fmt(g['const']['reported_vs_baseline_pct']):>12}")
line()
line('Whole-process wall milliseconds (includes initial parse/setup/teardown)')
line(f"{'input':16} {'base':>10} {'numeric':>10} {'primitive':>10} {'const':>10} {'const/base':>12}")
for source in D['sources']:
 g={r['stage']:r for r in rows if r['name']==source['name']}
 line(f"{source['name']:16} {g['baseline']['wall_ms']:10.1f} {g['numeric']['wall_ms']:10.1f} {g['primitive']['wall_ms']:10.1f} {g['const']['wall_ms']:10.1f} {fmt(g['const']['wall_vs_baseline_pct']):>12}")
line()
line('Peak RSS MiB')
line(f"{'input':16} {'base':>9} {'numeric':>9} {'primitive':>10} {'const':>9} {'const-base':>12}")
for source in D['sources']:
 g={r['stage']:r for r in rows if r['name']==source['name']}
 line(f"{source['name']:16} {g['baseline']['rss_mib']:9.2f} {g['numeric']['rss_mib']:9.2f} {g['primitive']['rss_mib']:10.2f} {g['const']['rss_mib']:9.2f} {g['const']['rss_mib']-g['baseline']['rss_mib']:+12.2f}")
line()
line('Directional interpretation')
line('* The broad mini workloads do not reproduce the large synthetic constant-heavy')
line('  wins from the earlier targeted experiment. Most final-stage observations are')
line('  close to baseline; this one round cannot establish a broad speedup.')
line('* Mandreel is essentially flat: 1510/1505/1506/1509 reported ms at the four')
line('  stages. Its RSS rises roughly 214.3 -> 224.5 MiB at the numeric stage and')
line('  remains there. This is consistent with a temporary per-node analysis column;')
line('  it is not an allocation-by-allocation attribution.')
line('* TypeScript is also close: 1781/1768/1779/1785 ms; whole-process time stays')
line('  around 1.85-1.87 s. No const-propagation benefit is established here.')
line('* Zlib happens to show 9749 -> 9129 ms at the final stage (-6.4%). Treat this')
line('  as an observation only. RegExp and GBEmu show large intermediate reversals')
line('  (GBEmu 417/416/454/419 ms), illustrating why one sample is not proof.')
line('* Existing embedded validation passed at each stage. There is no correctness')
line('  failure to separate from performance in this selected round.')
line('* Large retained heaps can mask transient compiler allocation differences in')
line('  process peak RSS. A flat RSS result does not mean the analysis allocates nothing.')
line()
line('Artifacts/reproduction')
line('  stages.json       exact source commits, build settings and binary hashes')
line('  results.json      complete warmup plus round-zero raw samples; round zero analyzed')
line('  interrupted.json  ignored local backup, including excluded partial-round data')
line('  pilot.json        earlier heavy-case pilot, excluded from this report')
line('  summary.csv       stage-by-stage observations and incremental/baseline deltas')
line('  components.csv    individual embedded benchmark timing lines')
line('  prepare.py        rebuild stage binaries in isolated temporary worktrees')
line('  run.py            defaults to one measured round plus one warmup round')
line('  summarize.py      regenerate this report without running benchmarks')
line('Stage binaries are retained locally in ignored bin/. The ~10.8 MB source inputs')
line('are referenced by exact hashes rather than copied or edited. To reproduce later:')
line('  python3 experiments/flat-ast/mini/prepare.py')
line('  python3 experiments/flat-ast/mini/run.py --rounds 1 --source OCTANE/bench/mini')
line('  python3 experiments/flat-ast/mini/summarize.py')
line('No Test262 commands, suites or runners were used. No main/octane source was edited.')
(HERE/'report.txt').write_text('\n'.join(text)+'\n')
print('Rendered one round:',len(used),'validated samples')
