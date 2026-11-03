#!/bin/zsh
S=${0:A:h}
JSC=/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc
cd $S
run() { local name=$1; shift; echo "=== $name $(date +%T) load=$(sysctl -n vm.loadavg)" ; /usr/bin/time -l perl -e 'alarm 900; exec @ARGV' "$@" > $S/$name.log 2> $S/$name.time; echo "exit $?"; cat $S/$name.log | tail -22; grep -E 'real|maximum resident' $S/$name.time; }
run jsc-llint $JSC --useJIT=false octane-all.js
run jsc-baseline $JSC --useDFGJIT=false octane-all.js
run jsc-dfg $JSC --useFTLJIT=false octane-all.js
run jsc-full $JSC octane-all.js
run bk-interp $S/../bk-rat --script octane-all.js
run bk-jit $S/../bk-rat --jit --script octane-all.js
echo DONE
