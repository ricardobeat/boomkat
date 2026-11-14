#!/usr/bin/env python3
"""Randomized differential fuzz of string accumulation, tail calls and leaf
builtins: each generated script runs under node and under boomkat in the
interpreter, --jit and --jit --opt; any output difference is reported.

usage: fuzz_jit_strings.py [--seed N] [--count N] [--bin out/boomkat]
"""
import argparse, os, random, subprocess, sys, tempfile

PRINT = "var print = typeof print === 'function' ? print : console.log;\n"

ALIAS = [
    "var c = s;",
    "cells.push(s);",
    "o.k = s;",
    "a[j & 3] = s;",
    "keep = function () { return s; };",
    "args = (function () { return arguments; })(s);",
    "try { t = s; } finally { s += 'f'; }",
    "g2 = (function* () { yield s; })(); g2v = g2.next().value;",
]
PIECES = ["String.fromCharCode(97 + (j % 26))", "'xy'", "j", "s.length",
          "'\\u00e9'", "'\\u4e2d'", "('' + j).charAt(0)"]


def accum(rng):
    body = []
    for _ in range(rng.randint(1, 4)):
        body.append("s += %s;" % rng.choice(PIECES))
        if rng.random() < 0.6:
            body.append(rng.choice(ALIAS))
    n = rng.choice([3, 50, 400])
    return """
function f%(id)d(n) {
  var s = '%(init)s', cells = [], o = {}, a = [], keep, args, t, g2, g2v;
  for (var j = 0; j < n; j++) { %(body)s }
  var r = s.length + ':' + s.slice(-6);
  r += '|' + cells.map(function (x) { return x.length; }).join(',');
  r += '|' + (o.k === undefined ? 'u' : o.k.length) + '|' + a.map(function (x) { return x.length; }).join(',');
  r += '|' + (keep ? keep().length : 'u') + '|' + (args ? args[0].length : 'u');
  r += '|' + (t === undefined ? 'u' : t.length) + '|' + (g2v === undefined ? 'u' : g2v.length);
  return r;
}
for (var i = 0; i < %(reps)d; i++) { var r%(id)d = f%(id)d(%(n)d); }
print('accum%(id)d', r%(id)d);
""" % {"id": rng.randint(0, 1 << 30), "init": rng.choice(["", "p", "pq"]),
       "body": " ".join(body), "n": n, "reps": rng.choice([5, 300])}


FIXED = r"""
var f = function g() { return typeof g; };
var h = function g() { g = 1; return typeof g; };
var k = function g() { return (function () { return typeof g; })(); };
var e = function g() { return eval('typeof g'); };
var w = function g() { var o = {}; with (o) { return typeof g; } };
var st = function g() { 'use strict'; try { g = 1; } catch (x) { return 'threw'; } return 'no'; };
var out = [];
for (var i = 0; i < 3000; i++) out = [f(), h(), k(), e(), w(), st()];
print('names', out.join());

function deep(n, acc) { if (n === 0) return acc; return deep(n - 1, acc + 1); }
print('deep', deep(3000, 0));
function tf(n) { try { return n ? tf(n - 1) : 'z'; } finally { cnt++; } }
var cnt = 0; for (var i = 0; i < 2000; i++) tf(5); print('tryfin', cnt);
function tb(s, i) { return s.charCodeAt(i); }
var sum = 0; for (var i = 0; i < 5000; i++) sum += tb('abc', i % 5) | 0; print('tb', sum);
var bound = function (a, b) { return a + (b === undefined ? 'U' : b); }.bind(null, 'x');
function tbound(v) { return bound(v); }
var bs = ''; for (var i = 0; i < 3000; i++) bs = tbound(i & 1); print('bound', bs);
function many(a, b, c) { return arguments.length + '' + a + b + c; }
function mis(x) { return many(x); }
function mis2(x) { return many(x, 1, 2, 3, 4); }
var ms; for (var i = 0; i < 3000; i++) ms = mis(i) + mis2(i); print('argc', ms);

var recv = ['abc', 5, true, { valueOf: function () { return 7; }, toString: function () { return 'q'; } }, null];
var idx = [0, -1, NaN, 1e300, 2.5, '1', { valueOf: function () { return 1; } }, undefined];
var rs = [];
for (var it = 0; it < 400; it++)
  for (var a = 0; a < recv.length; a++)
    for (var b = 0; b < idx.length; b++) {
      var v;
      try { v = String.prototype.charCodeAt.call(recv[a], idx[b]); } catch (x) { v = 'T'; }
      try { v += '/' + String.prototype.charAt.call(recv[a], idx[b]); } catch (x) { v += 'T'; }
      if (it === 0) rs.push(v);
    }
print('odd', rs.join());

var orig = String.prototype.charCodeAt, sum2 = 0;
for (var i = 0; i < 4000; i++) {
  if (i === 2000) String.prototype.charCodeAt = function () { return 1; };
  sum2 += 'abc'.charCodeAt(1);
}
String.prototype.charCodeAt = orig;
print('replcc', sum2);
var opush = Array.prototype.push, arr = [];
for (var i = 0; i < 4000; i++) {
  if (i === 2000) Array.prototype.push = function (v) { this[this.length] = -v; return 0; };
  arr.push(i);
}
Array.prototype.push = opush;
print('replpush', arr.length, arr[1999], arr[2000], arr[3999]);
"""


def run(cmd, path):
    try:
        p = subprocess.run(cmd + [path], capture_output=True, text=True, timeout=60)
        return p.stdout + (("EXIT %d " % p.returncode + p.stderr[-300:]) if p.returncode else "")
    except subprocess.TimeoutExpired:
        return "TIMEOUT"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--count", type=int, default=40)
    ap.add_argument("--bin", default="out/boomkat")
    o = ap.parse_args()
    modes = {"interp": [o.bin, "--script"], "jit": [o.bin, "--jit", "--script"],
             "opt": [o.bin, "--jit", "--opt", "--script"]}
    fails = 0
    for n in range(o.count + 1):
        rng = random.Random(o.seed * 100003 + n)
        src = PRINT + (FIXED if n == 0 else "".join(accum(rng) for _ in range(3)))
        with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False) as fh:
            fh.write(src)
        want = run(["node"], fh.name)
        for name, cmd in modes.items():
            got = run(cmd, fh.name)
            if got != want:
                fails += 1
                print("MISMATCH case %d mode %s (%s)\n--- node\n%s--- boomkat\n%s"
                      % (n, name, fh.name, want[:600], got[:600]))
                break
        else:
            os.unlink(fh.name)
    print("%d cases, %d mismatches" % (o.count + 1, fails))
    sys.exit(1 if fails else 0)


main()
