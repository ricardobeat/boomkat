#!/usr/bin/env python3
"""Embedding the JS engine in Python. Run: python3 bindings/python/example.py"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from js import JsError, JsThrow, Runtime

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

    # --- host functions: Python callables JS can invoke -------------------

    # @rt.function binds a Python function as a JS global. It takes one Call
    # argument; `arity` is what JS reports as .length.
    @rt.function("hostAdd", arity=2)
    def host_add(call):
        return sum(call.args)

    print("hostAdd(40, 2):", rt.eval("hostAdd(40, 2)"))
    print("via .apply:", rt.eval("hostAdd.apply(null, [1, 2, 3, 4])"))

    # The JS name defaults to the Python one, and str returns cross as UTF-8.
    @rt.function()
    def shout(call):
        return call.args[0].upper() + " \U0001F600"

    print("shout('hi'):", rt.eval("shout('hi')"))

    # Raising inside a host function becomes a JS throw rather than escaping
    # into C: a Python TypeError arrives as a JS TypeError. Use JsThrow to
    # pick a different class.
    @rt.function("checkAge", arity=1)
    def check_age(call):
        age = call.args[0]
        if age < 0:
            raise JsThrow("age must not be negative", "RangeError")
        return age >= 18

    print("checkAge(21):", rt.eval("checkAge(21)"))
    print("caught in JS:", rt.eval(
        "try { checkAge(-1) } catch (e) { e.constructor.name + ': ' + e.message }"))

    # A host function can call back into JS. Function arguments arrive as
    # callables, so `fn(x)` runs the JS function through jse_call, and the
    # result comes back as a Python value.
    #
    # The arguments passed to a callback must be ones this call received: the
    # ABI cannot construct JS values inside a host function, so `fn(x)` works
    # while `fn(x + 1)` does not. Compute on the Python side of the result
    # instead, as apply_twice does below.
    @rt.function("describe", arity=2)
    def describe(call):
        fn, value = call.args
        result = fn(value)        # a JS call, result converted to Python
        return "%s -> %s" % (value, result)

    print("describe(x => x * 3, 5):", rt.eval("describe(x => x * 3, 5)"))
    print("describe with a builtin:", rt.eval("describe(Math.sqrt, 81)"))

    # A throw from the JS callback propagates out through the host function
    # with its original class intact.
    print("callback throw:", rt.eval(
        "try { describe(() => { throw new RangeError('nope') }, 1) }"
        " catch (e) { e.constructor.name + ': ' + e.message }"))

    # --- errors -----------------------------------------------------------

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
