#!/bin/sh
# Builds sub-second Octane variants: each benchmark runs Setup, a fixed number
# of iterations, then TearDown (which validates), and prints elapsed ms.
# usage: gen.sh <zoo bench dir> name:iters ...
src=$1; shift
for spec in "$@"; do
  name=${spec%%:*}; n=${spec#*:}
  awk -v n="$n" '/^BenchmarkSuite.config.doWarmup = undefined;/ {
    print "BenchmarkSuite.RunSuites = function () {";
    print "  var total = 0;";
    print "  // Plain loops: a native callback frame (forEach) would keep the";
    print "  // collector from ever finishing a cycle.";
    print "  for (var si = 0; si < BenchmarkSuite.suites.length; si++) {";
    print "   var s = BenchmarkSuite.suites[si];";
    print "   for (var bi = 0; bi < s.benchmarks.length; bi++) {";
    print "    var b = s.benchmarks[bi];";
    print "    if (b.name.indexOf(\"Latency\") >= 0) continue;";
    print "    if (BenchmarkSuite.ResetRNG) BenchmarkSuite.ResetRNG(); b.Setup(); var t = Date.now();";
    print "    for (var i = 0; i < " n "; i++) b.run();";
    print "    var ms = Date.now() - t; total += ms; b.TearDown();";
    print "    print(b.name + \": \" + ms + \" ms\");";
    print "  } }";
    print "};";
  } { print }' "$src/$name.js" > "$name.js"
done
