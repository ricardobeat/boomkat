# Preserved experimental work

All patches apply against `68d7c01e`. They are independent experimental overlays, not a sequence to apply together. Do not enable them as validated production optimizations.

The region implementation is also committed as `8f875497` on `wip/function-ssa-regions`, with focused recovery/formal tests and an explicit limitations document. Other overlays preserve numeric globals, memory CSE, shared store checks and store-read fusion. Their validation differs; see manifest.json and the checkpoint report.

The original +9% DeltaBlue deficit in some prefix screens used mismatched feature defaults and is invalid. Later matched tests found neutral DeltaBlue; the region screen measured Richards 1756 -> 1619ms relative to the preceding prefix prototype. No full-suite or broad correctness conclusion is established for these experiments.
