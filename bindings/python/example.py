#!/usr/bin/env python3
"""Embedding the JS engine in Python. Run: python3 bindings/python/example.py"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from js import JsError, Runtime

# `with` closes the runtime on the way out, even if the body raises.
with Runtime() as rt:
    print("engine version:", rt.version)

    # Any JS expression comes back as its completion value.
    total = rt.eval("[1, 2, 3, 4].map(n => n * n).reduce((a, b) => a + b)")
    print("sum of squares:", total)

    # Strings survive the round trip as real UTF-8, astral planes included.
    print("greeting:", rt.eval("'hello ' + String.fromCodePoint(0x1F600)"))

    # State persists across eval() calls within one runtime.
    rt.eval("globalThis.counter = 0")
    rt.eval("counter += 5")
    print("counter:", rt.eval("counter"))

    # An uncaught JS throw arrives as a normal Python exception.
    try:
        rt.eval("null.oops")
    except JsError as err:
        print("caught throw: [%s] %s" % (err.kind, err))

    # So does a syntax error, distinguished by err.code.
    try:
        rt.eval("function (")
    except JsError as err:
        print("caught syntax: [%s] %s" % (err.kind, err))

    # The runtime is unharmed and still usable afterwards.
    print("still alive:", rt.eval("'yes'"))

print("runtime closed")
