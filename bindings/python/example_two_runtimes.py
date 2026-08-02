#!/usr/bin/env python3
"""Two runtimes in one process. Run: python3 bindings/python/example_two_runtimes.py

Runtimes share nothing: separate globals, separate objects, separate interned
strings. Values do not cross between them -- to move data, read it out of one
as a Python object and pass it into the other.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from js import JsError, Runtime

# Two runtimes, open at the same time, each closed on the way out.
with Runtime() as a, Runtime() as b:

    # --- independent globals ----------------------------------------------

    a.eval("globalThis.x = 111")
    b.eval("globalThis.x = 222")
    print("a.x:", a.eval("x"), " b.x:", b.eval("x"))

    # A global defined in one is simply absent from the other.
    a.eval("globalThis.onlyInA = 'hello'")
    try:
        b.eval("onlyInA")
    except JsError as err:
        print("b cannot see onlyInA:", err)

    # --- independent objects and shapes -----------------------------------

    # Build the same property sequence in both. Each runtime has its own shape
    # table, so the two objects evolve independently.
    a.eval("globalThis.o = {}; for (let i = 0; i < 200; i++) o['k' + i] = i")
    b.eval("globalThis.o = {}; for (let i = 0; i < 200; i++) o['k' + i] = -i")
    print("a.o.k199:", a.eval("o.k199"), " b.o.k199:", b.eval("o.k199"))

    # --- independent string tables ----------------------------------------

    # String equality inside the engine is pointer identity, so each runtime
    # interns its own copy. Identical text in both compares equal within each.
    a.eval("globalThis.s = 'shared text'")
    b.eval("globalThis.s = 'shared text'")
    print("a: s === 'shared text' ->", a.eval("s === 'shared text'"))
    print("b: s === 'shared text' ->", b.eval("s === 'shared text'"))

    # --- host functions are per runtime -----------------------------------

    # The same Python callable registered in both runtimes. `call.runtime` is
    # resolved from the call context (jse_ctx_runtime), so each invocation
    # identifies the runtime it is actually executing inside rather than
    # whichever one happened to register it last.
    names = {a: "a", b: "b"}

    def which(call):
        return names[call.runtime]

    a.register("whichRuntime", which)
    b.register("whichRuntime", which)
    print("host fn invoked from a says:", a.eval("whichRuntime()"))
    print("host fn invoked from b says:", b.eval("whichRuntime()"))

    # --- moving a value between runtimes ----------------------------------

    # There is no handle to pass: eval() hands back a plain Python object, and
    # that is what crosses. Anything an engine owns -- an object, a function --
    # has to be serialized first.
    payload = a.eval("JSON.stringify({from: 'a', n: 7})")
    b.eval("globalThis.fromA = JSON.parse(%r)" % payload)
    print("b received from a:", b.eval("fromA.from + '/' + fromA.n"))

    # --- closing one leaves the other untouched ---------------------------

    a.close()
    print("b still works after a closed:", b.eval("x + 1"))
    print("a is closed:", end=" ")
    try:
        a.eval("1")
    except JsError as err:
        print(err)

print("both runtimes closed")
