Flat AST prototype benchmark artifacts

Start with report.txt for the findings, methodology, bytecode explanation and
memory tradeoffs. summary.csv is the compact table; results.json and raw/*.json
contain all measurements. Bounded runtime bytecode dumps are committed alongside
them. Large compile inputs/dumps remain locally available and are ignored;
prepare.py and the CLIs regenerate them.

Compared bb4738ea against the extended prototype, with optimization enabled on
both sides, seven alternating measured pairs plus one warmup pair. The measured
engine source is now committed byte-for-byte as d2cd70d6b557137e5f9fbfe46847999d1dd10045.
No Test262 was run.

Runtime medians, baseline -> prototype:
  128-term numeric subtree: 203.712 -> 35.583 ms (-82.5%; synthetic upper bound)
  Primitive/bitwise:       122.730 -> 33.135 ms (-73.0%; synthetic target)
  Literal string suffix:   82.125 -> 51.098 ms (-37.8%; dynamic prefix retained)
  Local const chain:       37.478 -> 37.575 ms (+0.3%; indistinguishable from noise)
  Existing runtime controls remain essentially unchanged.

The const kernel drops only 8 -> 7 instructions: three LDINT declarations remain.
That limits this implementation's benefit; it does not imply const propagation
is fundamentally unhelpful. Compile-time costs and RSS are reported separately.

To reproduce from prebuilt binaries:
  python3 experiments/flat-ast/prepare.py
  python3 experiments/flat-ast/run.py --pairs 7
  python3 experiments/flat-ast/summarize.py

report.txt documents the separate baseline worktree and build commands. Nothing
was merged, and the main checkout and TS specialization worktree were untouched.

The historical prototype.patch and preliminary pilot.json are also ignored.
results.json records the source commit and the command that reconstructs the
exact measured engine patch; the committed history replaces a redundant patch.

The subsequent mini/README.txt and mini/report.txt contain the requested
one-round Octane comparison of baseline and each cumulative optimization.
