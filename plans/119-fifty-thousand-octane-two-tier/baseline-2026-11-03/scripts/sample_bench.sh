#!/bin/zsh
# usage: sample_bench.sh <bench> <mode: jit|interp> <seconds>
D=${0:A:h}
BK=$D/../../bk-rat
b=$1; mode=$2; secs=${3:-4}
flag=(); [[ $mode == jit ]] && flag=(--jit)
$BK $flag --script $D/$b.js > $D/$b.$mode.sample.log 2>&1 &
pid=$!
sleep 0.5
sample $pid $secs -mayDie -file $D/$b.$mode.sample.txt >/dev/null 2>&1
wait $pid
echo "$b $mode exit $?"
