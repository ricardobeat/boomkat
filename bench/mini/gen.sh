#!/bin/sh
# Builds short Octane variants. Octane warms a benchmark up for a second and
# scores the runs that follow, so each variant runs Setup, a fixed number of
# warm-up iterations, a fixed number of timed ones, then TearDown (which
# validates), and prints the timed milliseconds and the warm-up's.
# MINI_WARM and MINI_RUNS, when the host defines them, replace the two counts
# (scripts/mini_steady.py does, to count the instructions of a steady run).
# usage: gen.sh <zoo bench dir> name:warm:runs ...
src=$1; shift
for spec in "$@"; do
  name=${spec%%:*}; counts=${spec#*:}; w=${counts%%:*}; n=${counts#*:}
  awk -v w="$w" -v n="$n" '/^BenchmarkSuite.config.doWarmup = undefined;/ {
    print "BenchmarkSuite.RunSuites = function () {";
    print "  var warm = typeof MINI_WARM == \"number\" ? MINI_WARM : " w ";";
    print "  var runs = typeof MINI_RUNS == \"number\" ? MINI_RUNS : " n ";";
    print "  // Plain loops: a native callback frame (forEach) would keep the";
    print "  // collector from ever finishing a cycle.";
    print "  for (var si = 0; si < BenchmarkSuite.suites.length; si++) {";
    print "   var s = BenchmarkSuite.suites[si];";
    print "   for (var bi = 0; bi < s.benchmarks.length; bi++) {";
    print "    var b = s.benchmarks[bi];";
    print "    if (b.name.indexOf(\"Latency\") >= 0) continue;";
    print "    if (BenchmarkSuite.ResetRNG) BenchmarkSuite.ResetRNG(); b.Setup(); var t0 = Date.now();";
    print "    for (var i = 0; i < warm; i++) b.run();";
    print "    var t1 = Date.now();";
    print "    for (var i = 0; i < runs; i++) b.run();";
    print "    var t2 = Date.now(); b.TearDown();";
    print "    print(b.name + \": \" + (t2 - t1) + \" ms, warm-up \" + (t1 - t0) + \" ms\");";
    print "  } }";
    print "};";
  } { print }' "$src/$name.js" > "$name.js"
done
