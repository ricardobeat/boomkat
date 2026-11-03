#!/bin/zsh
D=${0:A:h}
BK=$D/../../bk-rat
for b in richards deltablue crypto raytrace earley regexp splay navier pdfjs mandreel gbemu codeload box2d zlib typescript; do
  perl -e 'alarm 300; exec @ARGV' $BK --jit --script $D/$b.js > $D/$b.jit.log 2>&1
  echo "== $b exit $?"; grep -v -- '----' $D/$b.jit.log | grep -v '^Score' 
done
echo DONE
