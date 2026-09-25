#!/usr/bin/env python3
"""Check that callback collections do not retain pins across native returns."""

import os
from pathlib import Path
import sys
import tempfile


SOURCE = """
for (var run = 0; run < ROUNDS; ++run) {
    var input = new BigInt64Array(513);
    for (var i = 0; i < input.length; ++i) input[i] = BigInt(input.length - i);
    var calls = 0;
    var result = input.toSorted(function (a, b) {
        if ((calls++ & 31) === 0) [{ a: a }, { b: b }];
        return a < b ? -1 : a > b ? 1 : 0;
    });
    if (result[0] !== 1n || result[512] !== 513n) throw new Error('sort result');
}
"""


def peak_rss(engine, rounds):
    with tempfile.TemporaryDirectory(prefix="boomkat-temproot-") as directory:
        script = Path(directory) / "sort.js"
        script.write_text(SOURCE.replace("ROUNDS", str(rounds)))
        pid = os.fork()
        if pid == 0:
            try:
                os.execv(str(engine), [str(engine), "--script", str(script)])
            finally:
                os._exit(127)
        _, status, usage = os.wait4(pid, 0)
        if status:
            raise RuntimeError(f"engine failed with wait status {status}")
        # macOS reports bytes; Linux reports KiB. The ratio works for both.
        return usage.ru_maxrss


def main():
    root = Path(__file__).resolve().parent.parent
    engine = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else root / "out/boomkat"
    small = peak_rss(engine, 20)
    large = peak_rss(engine, 200)
    ratio = large / small
    print(f"temproot RSS: 20 sorts={small}, 200 sorts={large}, ratio={ratio:.2f}")
    if ratio > 2.0:
        raise SystemExit("FAIL: temporary roots accumulate across native calls")
    print("temproot_rss: PASS")


if __name__ == "__main__":
    main()
