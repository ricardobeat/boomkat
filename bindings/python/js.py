"""Pure-Python ctypes binding for the bk_ embedding ABI (see include/boomkat.h).

No C extension, no build step: this module dlopen()s the shared library built
by `make shared` and talks to its exported C symbols directly.

    from js import Runtime, JsError

    with Runtime() as rt:
        print(rt.eval("[1, 2, 3].reduce((a, b) => a + b)"))   # 6.0

JS values come back as Python objects: numbers as float, strings as str,
booleans as bool, null/undefined as None. Objects and functions have no Python
equivalent, so they surface as an opaque JsObject; stringify them in JS
(JSON.stringify, String(x)) if you need their contents.

Python functions go the other way with @rt.function, which makes them callable
from JS:

    @rt.function("now")
    def now(call):
        return time.time() * 1000

Several Runtimes can be open at once. Each has its own globals, objects and
strings, and they share nothing -- so a value read out of one is a plain Python
object with no tie to the engine it came from. A single Runtime must be driven
from one thread at a time; nothing enforces that.
"""

import ctypes
import os
import sys
import weakref

__all__ = ["Runtime", "JsError", "JsObject", "JsThrow", "JsValue",
           "JsFunction", "Call", "version"]

# Status codes from boomkat.h. 0 is success; every error is negative.
_OK = 0
_STATUS_NAMES = {
    -1: "out of memory",
    -2: "syntax error",
    -3: "uncaught exception",
    -4: "internal engine error",
    -5: "invalid argument or handle",
    -6: "wrong type",
    -7: "buffer too small or slot table full",
}

# Value types from bk_type_of.
_UNDEFINED, _NULL, _BOOLEAN, _NUMBER, _STRING, _OBJECT, _FUNCTION, _OTHER = range(8)

_TYPE_NAMES = {
    _UNDEFINED: "undefined",
    _NULL: "null",
    _BOOLEAN: "boolean",
    _NUMBER: "number",
    _STRING: "string",
    _OBJECT: "object",
    _FUNCTION: "function",
    _OTHER: "other",
}


# Error kinds for bk_throw_error, keyed by the Python exception the host
# function raised. Anything unlisted becomes a plain Error.
_ERROR, _ERROR_TYPE, _ERROR_RANGE, _ERROR_REFERENCE, _ERROR_SYNTAX = range(5)

_ERROR_KINDS = {
    "Error": _ERROR,
    "TypeError": _ERROR_TYPE,
    "RangeError": _ERROR_RANGE,
    "ReferenceError": _ERROR_REFERENCE,
    "SyntaxError": _ERROR_SYNTAX,
}


class JsError(Exception):
    """A JS-side failure: syntax error, uncaught throw, or engine fault.

    `code` is the raw bk_status integer; `kind` is a human-readable name for
    it. The message is whatever the engine reported.
    """

    def __init__(self, code, message):
        super().__init__(message or _STATUS_NAMES.get(code, "error"))
        self.code = code
        self.kind = _STATUS_NAMES.get(code, "error")


class JsThrow(Exception):
    """Raise this inside a host function to throw a chosen Error class in JS.

    Any other Python exception also becomes a JS throw -- a TypeError becomes a
    JS TypeError, everything else a plain Error -- so this is only needed to
    pick a class that does not match the Python one, such as RangeError.

        raise JsThrow("index out of range", "RangeError")
    """

    def __init__(self, message, kind="Error"):
        super().__init__(message)
        if kind not in _ERROR_KINDS:
            raise ValueError("unknown JS error class %r; expected one of %s"
                             % (kind, ", ".join(sorted(_ERROR_KINDS))))
        self.kind = kind


class JsObject:
    """A JS value with no Python equivalent (object, function, symbol, ...)."""

    __slots__ = ("type_name",)

    def __init__(self, type_id):
        self.type_name = _TYPE_NAMES.get(type_id, "value")

    def __repr__(self):
        return "<js %s>" % self.type_name


def default_library_path():
    """Locate libboomkat next to this checkout, as `make shared` leaves it."""
    if sys.platform == "darwin":
        name = "boomkat.dylib"
    elif sys.platform == "win32":
        name = "boomkat.dll"
    else:
        name = "boomkat.so"
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    return os.path.join(root, "out", name)


# The host callback signature: void (*)(bk_call_ctx ctx, void *udata).
# CFUNCTYPE (not PYFUNCTYPE) is right here -- it still acquires the GIL around
# the Python callback, which is what keeps this safe under CPython.
_HOST_FN = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_void_p)


def _declare(lib):
    """Pin argtypes/restype on every symbol.

    This is not optional hygiene: without argtypes, ctypes defaults pointer
    arguments to 32-bit int on some platforms and truncates the runtime handle.
    """
    rt, u32 = ctypes.c_void_p, ctypes.c_uint
    ctx = ctypes.c_void_p
    signatures = [
        ("bk_open", [ctypes.POINTER(ctypes.c_void_p)], ctypes.c_int),
        ("bk_close", [rt], None),
        ("bk_version", [], ctypes.c_char_p),
        ("bk_eval", [rt, ctypes.c_char_p, ctypes.c_size_t,
                      ctypes.POINTER(u32)], ctypes.c_int),
        ("bk_value_free", [rt, u32], None),
        ("bk_type_of", [rt, u32], ctypes.c_int),
        ("bk_get_number", [rt, u32, ctypes.POINTER(ctypes.c_double)], ctypes.c_int),
        ("bk_get_bool", [rt, u32, ctypes.POINTER(ctypes.c_int)], ctypes.c_int),
        ("bk_get_string", [rt, u32, ctypes.c_char_p, ctypes.c_size_t,
                            ctypes.POINTER(ctypes.c_size_t)], ctypes.c_int),
        # The context tier of the same readers. A host callback holds a call
        # context and no runtime, and only these resolve the scope handles
        # bk_arg/bk_this/bk_new_target return.
        ("bk_ctx_type_of", [ctx, u32], ctypes.c_int),
        ("bk_ctx_get_number", [ctx, u32, ctypes.POINTER(ctypes.c_double)],
         ctypes.c_int),
        ("bk_ctx_get_bool", [ctx, u32, ctypes.POINTER(ctypes.c_int)],
         ctypes.c_int),
        ("bk_ctx_get_string", [ctx, u32, ctypes.c_char_p, ctypes.c_size_t,
                                ctypes.POINTER(ctypes.c_size_t)], ctypes.c_int),
        ("bk_ctx_runtime", [ctx], ctypes.c_void_p),
        ("bk_last_error", [rt], ctypes.c_char_p),
        ("bk_last_error_code", [rt], ctypes.c_int),
        ("bk_drain_microtasks", [rt], None),
        # Host functions.
        ("bk_register_fn", [rt, ctypes.c_char_p, ctypes.c_size_t, _HOST_FN,
                             ctypes.c_void_p, ctypes.c_int, ctypes.c_int],
         ctypes.c_int),
        ("bk_argc", [ctx], ctypes.c_uint),
        ("bk_arg", [ctx, u32], u32),
        ("bk_this", [ctx], u32),
        ("bk_new_target", [ctx], u32),
        ("bk_is_construct", [ctx], ctypes.c_int),
        ("bk_return", [ctx, u32], None),
        ("bk_return_number", [ctx, ctypes.c_double], None),
        ("bk_return_bool", [ctx, ctypes.c_int], None),
        ("bk_return_null", [ctx], None),
        ("bk_return_string", [ctx, ctypes.c_char_p, ctypes.c_size_t], None),
        ("bk_throw_error", [ctx, ctypes.c_int, ctypes.c_char_p], None),
        ("bk_throw", [ctx, u32], None),
        ("bk_value_persist", [ctx, u32], u32),
        ("bk_call", [ctx, u32, ctypes.POINTER(u32), ctypes.c_uint, u32,
                      ctypes.POINTER(u32)], ctypes.c_int),
    ]
    for name, argtypes, restype in signatures:
        fn = getattr(lib, name)
        fn.argtypes = argtypes
        fn.restype = restype
    return lib


def _load(path):
    path = path or os.environ.get("BK_LIBRARY") or default_library_path()
    try:
        return _declare(ctypes.CDLL(path))
    except OSError as exc:
        raise JsError(-5, "cannot load the boomkat shared library from %r "
                          "(run `make shared` first): %s" % (path, exc)) from exc


def version(path=None):
    """Engine version string. Does not require an open Runtime."""
    return _load(path).bk_version().decode("utf-8")


class JsValue:
    """A live reference to one argument of an in-flight host call.

    Handles reached through a call context are scope handles: the engine
    invalidates them when the host function returns. These are therefore
    deliberately not storable, and using one after its call returned raises
    JsError rather than dereferencing a dead handle. Their purpose is to let a
    host function forward an argument it received into a JS callback.
    """

    __slots__ = ("_call", "_handle", "_type")

    def __init__(self, call, handle, type_id):
        self._call = call
        self._handle = handle
        self._type = type_id

    @property
    def type_name(self):
        return _TYPE_NAMES.get(self._type, "value")

    def to_python(self):
        """Convert to a plain Python value, as call.args already did."""
        return self._call.reader.to_python(self._handle, self._type)

    def __repr__(self):
        return "<js %s>" % self.type_name


class JsFunction(JsValue):
    """A JS function argument, callable from Python while its host call runs."""

    __slots__ = ()

    def __call__(self, *args):
        return self._call._invoke(self._handle, args)

    def __repr__(self):
        return "<js function>"


class Call:
    """One in-flight invocation of a Python host function.

    Arguments are already converted to Python values in `args`; the raw context
    is only used for the things conversion cannot express -- calling a JS
    function back, or asking whether this was a `new` call.

    `runtime` is the Runtime this call is running inside, resolved from the
    context itself rather than assumed, so a host function registered in
    several runtimes sees the right one every time.
    """

    __slots__ = ("_lib", "_ctx", "_runtime", "reader", "args", "raw", "_live")

    def __init__(self, lib, ctx, runtime):
        self._lib = lib
        self._ctx = ctx
        self._runtime = runtime
        self._live = True
        # Everything a callback reads goes through the context tier: its
        # arguments are scope handles, which the runtime tier cannot resolve.
        self.reader = _Reader(lib, ctx, "bk_ctx_")
        handles = tuple(lib.bk_arg(ctx, i) for i in range(lib.bk_argc(ctx)))
        # `raw` keeps the live references, which is what a JS callback can be
        # handed back; `args` is the convenient plain-Python view of the same
        # arguments. A function argument appears in both, since calling one is
        # the common case and needs no ceremony.
        self.raw = tuple(self._wrap(h, self.reader.type_of(h)) for h in handles)
        # A callable stays callable in `args` so `call.args[0](x)` just works;
        # everything else becomes a plain Python value.
        self.args = tuple(v if isinstance(v, JsFunction) else v.to_python()
                          for v in self.raw)

    @property
    def this(self):
        """The `this` receiver. Strict semantics: undefined stays undefined."""
        handle = self._lib.bk_this(self._ctx)
        value = self._wrap(handle, self.reader.type_of(handle))
        return value if isinstance(value, JsFunction) else value.to_python()

    @property
    def new_target(self):
        """new.target, or None on a plain call."""
        handle = self._lib.bk_new_target(self._ctx)
        return self.reader.to_python(handle)

    @property
    def runtime(self):
        """The Runtime this call is executing inside."""
        return self._runtime

    @property
    def is_construct(self):
        """True when invoked through `new` or `super()`."""
        return bool(self._lib.bk_is_construct(self._ctx))

    def _wrap(self, handle, type_id):
        # OTHER is treated as callable alongside FUNCTION because bk_ctx_type_of
        # has no lightfunc case: engine built-ins such as Math.abs are stored
        # as a tagged ordinal rather than an HObject, so they fall through to
        # OTHER even though `typeof` says "function" and bk_call invokes them
        # fine. Symbols and bigints also land in OTHER, and calling one throws
        # a TypeError from JS -- the correct outcome anyway.
        cls = JsFunction if type_id in (_FUNCTION, _OTHER) else JsValue
        return cls(self, handle, type_id)

    def _invoke(self, func, args):
        """Call a JS function from inside this host function, via bk_call."""
        if not self._live:
            raise JsError(-5, "this JS function outlived the host call it came "
                              "from; scope handles die when the callback returns")
        argv = (ctypes.c_uint * max(len(args), 1))()
        for i, arg in enumerate(args):
            argv[i] = self._to_js(arg)
        out = ctypes.c_uint(0)
        rc = self._lib.bk_call(self._ctx, func, argv, len(args), 0,
                                ctypes.byref(out))
        if rc != _OK:
            # The throw is already recorded on this context. Signal it to the
            # trampoline, which returns promptly and lets the engine propagate
            # the original JS exception rather than a new one.
            raise _Propagate()
        # bk_call hands back a runtime-owned handle, not a scope handle, but
        # the context tier resolves both -- so read it through this call's
        # reader rather than reaching for the Runtime.
        try:
            return self.reader.to_python(out.value)
        finally:
            self._lib.bk_value_free(self._runtime._rt, out.value)

    def _to_js(self, value):
        """Handle for a Python value passed as a bk_call argument.

        This ABI gives a callback no way to mint a value: bk_return_* write
        the return slot rather than yielding a handle, bk_call only resolves
        handles that already exist, and bk_eval is a top-level entry point
        that must not be re-entered from inside a callback. So the arguments a
        host function can forward are the ones it was handed, identified by
        position via JsValue.

        Passing a fresh Python value is reported rather than silently coerced.
        Build it in JS instead -- have the callback take a factory function, or
        return the data and let JS assemble the call.
        """
        if isinstance(value, JsValue):
            if value._call is not self:
                raise JsError(-5, "that JS value belongs to a different host call")
            return value._handle
        # A plain Python value is forwardable when it is one of this call's own
        # arguments unchanged -- the overwhelmingly common case, `f(x)` where x
        # came out of call.args. Match on type and equality so 1.0 and True
        # stay distinct, and take the handle that produced it.
        for js_value, converted in zip(self.raw, self.args):
            if isinstance(js_value, JsFunction):
                continue
            if type(converted) is type(value) and converted == value:
                return js_value._handle
        raise JsError(-6, "cannot pass a new %s to a JS callback: this ABI "
                          "cannot construct JS values inside a host function, "
                          "so only this call's own arguments can be forwarded"
                          % (type(value).__name__,))


class _Propagate(Exception):
    """Internal: a JS exception is already recorded; unwind Python quietly."""


def _count_parameters(pyfunc):
    """Default for the JS .length of a host function.

    A host function's Python signature is always f(call) -- the JS arguments
    arrive inside the Call, not as separate parameters -- so there is nothing
    to count. JS built-ins whose length is unspecified report 0, and that is
    the honest default here too; pass arity= to declare a real one.
    """
    return 0


class _Reader:
    """One tier of the ABI's readers, bound to the thing that resolves handles.

    The ABI reads values through two parallel families. Outside a callback you
    hold a runtime and call bk_get_number and friends; inside one you hold a
    call context and call the bk_ctx_ forms. They are not interchangeable:
    the handles bk_arg/bk_this/bk_new_target return name a slot in the
    call's scope rather than in the runtime's registry, so only the context
    tier can resolve them, and neither tier accepts a null first argument.

    Rather than spread that fork through every conversion site, each tier
    becomes a _Reader carrying its own owner pointer and function names.
    """

    __slots__ = ("_owner", "type_of", "_get_bool", "_get_number", "_get_string")

    def __init__(self, lib, owner, prefix):
        self._owner = owner
        self.type_of = _bind(lib, prefix + "type_of", owner)
        self._get_bool = _bind(lib, prefix + "get_bool", owner)
        self._get_number = _bind(lib, prefix + "get_number", owner)
        self._get_string = _bind(lib, prefix + "get_string", owner)

    def to_python(self, handle, type_id=None):
        """Convert a handle to a plain Python value."""
        if type_id is None:
            type_id = self.type_of(handle)
        if type_id in (_UNDEFINED, _NULL):
            return None
        if type_id == _BOOLEAN:
            out = ctypes.c_int()
            if self._get_bool(handle, ctypes.byref(out)) != _OK:
                return JsObject(type_id)
            return bool(out.value)
        if type_id == _NUMBER:
            out = ctypes.c_double()
            if self._get_number(handle, ctypes.byref(out)) != _OK:
                return JsObject(type_id)
            return out.value
        if type_id == _STRING:
            size = ctypes.c_size_t(0)
            if self._get_string(handle, None, 0, ctypes.byref(size)) != _OK:
                return JsObject(type_id)
            buffer = ctypes.create_string_buffer(size.value + 1)
            if self._get_string(handle, buffer, size.value + 1,
                                ctypes.byref(size)) != _OK:
                return JsObject(type_id)
            return buffer.raw[:size.value].decode("utf-8")
        return JsObject(type_id)


def _bind(lib, name, owner):
    """Partially apply an ABI function to the runtime or context it reads through."""
    fn = getattr(lib, name)
    return lambda *rest: fn(owner, *rest)


# Every open Runtime, keyed by its engine pointer, so a call context can be
# mapped back to the Python object that owns it. Weak so that a Runtime the
# embedder has dropped stays collectable; entries also go on close().
_OPEN_RUNTIMES = weakref.WeakValueDictionary()


def _runtime_for(lib, ctx, fallback):
    """The Runtime a callback is executing inside, per bk_ctx_runtime."""
    pointer = lib.bk_ctx_runtime(ctx)
    return _OPEN_RUNTIMES.get(pointer, fallback)


class Runtime:
    """One JavaScript engine instance, usable as a context manager.

    Closing is idempotent, and `with` closes on the way out even if the body
    raised, so the engine heap is never leaked.

    Several Runtimes can be open at the same time. They share no globals, no
    objects and no interned strings, and a JS value belongs to exactly the one
    that produced it. The binding never lets a handle escape its Runtime: eval()
    converts results to plain Python objects, so moving data between two
    Runtimes is just reading it out of one and passing it into the other.
    """

    def __init__(self, library_path=None):
        self._lib = _load(library_path)
        self._rt = ctypes.c_void_p()
        # Every CFUNCTYPE trampoline handed to C lives here for the runtime's
        # lifetime. ctypes does NOT keep one alive on its own: drop the last
        # Python reference and the object is collected, leaving the engine
        # holding a pointer to freed memory that it will happily call. Since
        # bk_register_fn is permanent for the runtime, so is this list.
        self._trampolines = []
        # The most recent Python exception a host function raised. JS only ever
        # sees its text, so keeping the object here preserves the traceback for
        # an embedder that wants to re-raise or log it after eval() returns.
        self._last_host_exception = None
        rc = self._lib.bk_open(ctypes.byref(self._rt))
        if rc != _OK:
            raise JsError(rc, "bk_open failed to create a runtime")
        # The runtime tier of the readers, for handles this Runtime owns.
        self._reader = _Reader(self._lib, self._rt, "bk_")
        _OPEN_RUNTIMES[self._rt.value] = self

    @property
    def version(self):
        return self._lib.bk_version().decode("utf-8")

    def eval(self, source):
        """Evaluate JS source and return its completion value.

        Raises JsError on a syntax error or an uncaught throw. Pending promise
        jobs are drained by the engine before this returns.
        """
        self._check_open()
        encoded = source.encode("utf-8")
        handle = ctypes.c_uint(0)
        rc = self._lib.bk_eval(self._rt, encoded, len(encoded), ctypes.byref(handle))
        if rc != _OK:
            raise JsError(rc, self._error_message())
        try:
            return self._to_python(handle.value)
        finally:
            # The handle occupies a slot in a fixed-size registry, so release
            # it even if conversion raised.
            self._lib.bk_value_free(self._rt, handle.value)

    def register(self, name, pyfunc, arity=None, constructable=False):
        """Bind a Python callable as the JS global `name`.

        The callable receives one Call argument and returns a Python value,
        which becomes the JS return value; returning None yields undefined.
        Raising converts to a JS throw -- see JsThrow for choosing the class.

        `arity` becomes the function's .length, defaulting to the number of
        positional parameters the callable declares. Registration is permanent:
        the ABI offers no way to unbind.
        """
        self._check_open()
        if arity is None:
            arity = _count_parameters(pyfunc)
        trampoline = _HOST_FN(self._make_trampoline(pyfunc))
        # Append BEFORE registering: once C holds the pointer, a collection
        # between the two statements would already be fatal.
        self._trampolines.append(trampoline)
        encoded = name.encode("utf-8")
        rc = self._lib.bk_register_fn(self._rt, encoded, len(encoded),
                                       trampoline, None, arity,
                                       1 if constructable else 0)
        if rc != _OK:
            self._trampolines.pop()
            raise JsError(rc, self._error_message())
        return pyfunc

    def function(self, name=None, arity=None, constructable=False):
        """Decorator form of register(). Defaults the JS name to the Python one.

            @rt.function()
            def greet(call):
                return "hello " + call.args[0]
        """
        def decorate(pyfunc):
            self.register(name or pyfunc.__name__, pyfunc, arity, constructable)
            return pyfunc
        return decorate

    def _make_trampoline(self, pyfunc):
        """Wrap `pyfunc` in the C-callable shim the engine invokes.

        Nothing may escape this function as a Python exception: it is called
        from C, which has no notion of one. ctypes would merely print a
        traceback and return, leaving JS to carry on with a bogus undefined. So
        every path is caught and converted into a recorded JS throw.
        """
        lib = self._lib

        def trampoline(ctx, _udata):
            call = None
            try:
                # A trampoline is created per registration, so `self` is the
                # Runtime this callback was bound to. bk_ctx_runtime(ctx)
                # reports the same thing from the engine's side; consult it so
                # `call.runtime` is what the engine says, not what the closure
                # assumed.
                call = Call(lib, ctx, _runtime_for(lib, ctx, self))
                result = pyfunc(call)
            except _Propagate:
                # bk_call already recorded the callee's throw on this context.
                # Returning now lets the engine propagate that exception intact.
                return
            except JsThrow as exc:
                lib.bk_throw_error(ctx, _ERROR_KINDS[exc.kind],
                                    str(exc).encode("utf-8"))
                return
            except BaseException as exc:
                # Stash the original so the embedder can inspect the Python
                # traceback after eval() returns; JS only ever sees the text.
                self._last_host_exception = exc
                kind = _ERROR_KINDS.get(type(exc).__name__, _ERROR)
                message = "%s: %s" % (type(exc).__name__, exc)
                lib.bk_throw_error(ctx, kind, message.encode("utf-8"))
                return
            finally:
                if call is not None:
                    # Scope handles die with the call; make the JsFunction
                    # objects that wrap them refuse to be used afterwards.
                    call._live = False
            try:
                self._set_return(ctx, result)
            except BaseException as exc:
                lib.bk_throw_error(ctx, _ERROR,
                                    ("cannot return %r to JS: %s"
                                     % (type(result).__name__, exc)).encode("utf-8"))

        return trampoline

    def _set_return(self, ctx, result):
        """Store a Python value as the call's JS return value."""
        lib = self._lib
        if result is None:
            return  # A callback that sets no return value yields undefined.
        if isinstance(result, bool):
            # Checked before int: bool is a subclass of int in Python.
            lib.bk_return_bool(ctx, 1 if result else 0)
        elif isinstance(result, (int, float)):
            lib.bk_return_number(ctx, float(result))
        elif isinstance(result, str):
            encoded = result.encode("utf-8")
            lib.bk_return_string(ctx, encoded, len(encoded))
        elif isinstance(result, JsValue):
            # Returning an argument straight back, or the result of a callback.
            lib.bk_return(ctx, result._handle)
        elif isinstance(result, (list, dict, tuple)):
            # No ABI constructor builds an object or array inside a callback,
            # and bk_eval must not be re-entered from one. Returning JSON text
            # silently would make a dict arrive as a string, so say so instead:
            # the host stringifies deliberately and JS calls JSON.parse.
            raise TypeError("returning a %s would have to cross as JSON text; "
                            "return json.dumps(...) and JSON.parse it in JS"
                            % type(result).__name__)
        else:
            raise TypeError("no JS equivalent; return a number, string, bool, "
                            "None, or a value from call.raw")

    def drain_microtasks(self):
        """Run pending promise jobs. eval() already does this on its own."""
        self._check_open()
        self._lib.bk_drain_microtasks(self._rt)

    def close(self):
        if self._rt:
            _OPEN_RUNTIMES.pop(self._rt.value, None)
            self._lib.bk_close(self._rt)
            self._rt = ctypes.c_void_p()

    def __enter__(self):
        return self

    def __exit__(self, *exc_info):
        self.close()
        return False

    def _check_open(self):
        if not self._rt:
            raise JsError(-5, "this Runtime is closed")

    def _error_message(self):
        raw = self._lib.bk_last_error(self._rt)
        # The engine owns this buffer and overwrites it on the next call, so
        # decode (copy) immediately rather than holding the pointer.
        return raw.decode("utf-8", "replace") if raw else ""

    def _to_python(self, handle):
        # Strings emerge as real UTF-8: the engine converts its internal
        # CESU-8, so astral characters arrive as 4-byte sequences.
        return self._reader.to_python(handle)
