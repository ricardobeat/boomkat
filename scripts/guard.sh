#!/bin/bash
# Run a command under a memory and time watchdog.
#
#   scripts/guard.sh [-m MB] [-t SECONDS] -- command args...
#
# The command and everything it spawns run in their own process group. Every
# 200 ms the group's resident memory is summed; when it passes the cap
# (default 2048 MB) or the command runs past the time limit (default 600 s),
# the whole group is killed with SIGKILL and the script exits 137. Otherwise
# the command's own status is returned.
#
# The engine has no heap limit of its own, and macOS ignores `ulimit -v`, so
# an unbounded allocation can take the machine down before `timeout` fires.
# Use this around every engine run whose memory use is not already known.
set -u
cap_mb=2048
limit_s=600
while [ $# -gt 0 ]; do
    case "$1" in
        -m) cap_mb=$2; shift 2 ;;
        -t) limit_s=$2; shift 2 ;;
        --) shift; break ;;
        *) break ;;
    esac
done
[ $# -gt 0 ] || { echo "usage: guard.sh [-m MB] [-t SECONDS] -- command..." >&2; exit 2; }

# A new session puts the child and its descendants in one process group.
if command -v setsid >/dev/null 2>&1; then
    setsid "$@" &
else
    perl -e 'use POSIX; POSIX::setsid(); exec @ARGV' "$@" &
fi
pid=$!
start=$(date +%s)
while kill -0 "$pid" 2>/dev/null; do
    rss_kb=$(ps -o rss= -g "$pid" 2>/dev/null | awk '{s+=$1} END {print s+0}')
    now=$(date +%s)
    if [ "$rss_kb" -gt $((cap_mb * 1024)) ]; then
        echo "guard: killed at ${rss_kb} KB resident (cap ${cap_mb} MB)" >&2
        kill -KILL -- "-$pid" 2>/dev/null; wait "$pid" 2>/dev/null; exit 137
    fi
    if [ $((now - start)) -gt "$limit_s" ]; then
        echo "guard: killed after ${limit_s} s" >&2
        kill -KILL -- "-$pid" 2>/dev/null; wait "$pid" 2>/dev/null; exit 137
    fi
    sleep 0.2
done
wait "$pid"
