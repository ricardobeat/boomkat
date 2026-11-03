#!/bin/zsh
D=${0:A:h}
BK=$D/../bk-rat
echo "== suite --stats"; $BK --jit --stats --script $D/octane-all.js 2>/dev/null | grep -E '^[A-Za-z]+: [0-9]|^Score|SLJIT (totals|budget)'
echo "== navier-first"; $BK --jit --script $D/octane-navier-first.js 2>/dev/null | grep -E '^(NavierStokes|Richards|Score)'
for b in navier richards raytrace pdfjs mandreel box2d; do echo "== $b standalone stats"; $BK --jit --stats --script $D/single/$b.js 2>/dev/null | grep -E 'SLJIT (totals|budget)'; done
echo DONE
