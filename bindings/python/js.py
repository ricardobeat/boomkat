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
    -7: "buffer too small or registry full",
    -8: "aborted by the interrupt handler",
    -9: "invalid text encoding",
    -10: "feature not in this build",
}

# Immediate handles from boomkat.h: valid in any context, never freed.
_HANDLE_UNDEFINED, _HANDLE_NULL, _HANDLE_TRUE, _HANDLE_FALSE = 1, 2, 3, 4

# Value types from bk_get_type.
_UNDEFINED, _NULL, _BOOLEAN, _NUMBER, _STRING, _OBJECT, _FUNCTION, _SYMBOL, _BIGINT = range(9)

_TYPE_NAMES = {
    _UNDEFINED: "undefined",
    _NULL: "null",
    _BOOLEAN: "boolean",
    _NUMBER: "number",
    _STRING: "string",
    _OBJECT: "object",
    _FUNCTION: "function",
    _SYMBOL: "symbol",
    _BIGINT: "bigint",
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


# The host callback signature: void (*)(bk_ctx ctx, void *udata).
# CFUNCTYPE (not PYFUNCTYPE) is right here -- it still acquires the GIL around
# the Python callback, which is what keeps this safe under CPython.
_HOST_FN = ctypes.CFUNCTYPE(ctypes.c_uint64, ctypes.c_void_p, ctypes.c_uint64,
                            ctypes.c_uint, ctypes.POINTER(ctypes.c_uint64), ctypes.c_void_p)


class _StringView(ctypes.Structure):
    """bk_string_view: width 1 is Latin-1, width 2 native UTF-16."""

    _fields_ = [("data", ctypes.c_void_p), ("length", ctypes.c_size_t),
                ("width", ctypes.c_uint8), ("ascii", ctypes.c_uint8)]


# void (*bk_string_release)(void *opaque, const void *data, size_t length)
_STRING_RELEASE = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_void_p,
                                   ctypes.c_size_t)


class _FnDef(ctypes.Structure):
    """One entry of a bk_set_function_list table (mirrors bk_fn_def in boomkat.h)."""

    _fields_ = [("name", ctypes.c_char_p),
                ("fn", _HOST_FN),
                ("arity", ctypes.c_int),
                ("flags", ctypes.c_uint),
                ("udata", ctypes.c_void_p)]


def _declare(lib):
    """Pin argtypes/restype on every symbol.

    This is not optional hygiene: without argtypes, ctypes defaults pointer
    arguments to 32-bit int on some platforms and truncates the context handle.
    """
    ctx = ctypes.c_void_p
    val = ctypes.c_uint64
    signatures = [
        ("bk_new_runtime", [ctypes.c_void_p], ctx),
        ("bk_free_runtime", [ctx], None),
        ("bk_new_context", [ctx], ctx),
        ("bk_free_context", [ctx], None),
        ("bk_version", [], ctypes.c_char_p),
        # Value-producing calls return the handle directly; 0 means failure
        # with the detail in bk_get_error_message/bk_get_error_code.
        ("bk_eval_ex", [ctx, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_uint], val),
        ("bk_free_value", [ctx, val], None),
        ("bk_get_type", [ctx, val], ctypes.c_int),
        ("bk_read_number", [ctx, val, ctypes.POINTER(ctypes.c_double)],
         ctypes.c_int),
        ("bk_read_bool", [ctx, val, ctypes.POINTER(ctypes.c_int)], ctypes.c_int),
        ("bk_read_string", [ctx, val, ctypes.c_char_p, ctypes.c_size_t,
                             ctypes.POINTER(ctypes.c_size_t)], ctypes.c_int),
        ("bk_read_string_utf16", [ctx, val, ctypes.POINTER(ctypes.c_uint16),
                                  ctypes.c_size_t,
                                  ctypes.POINTER(ctypes.c_size_t)], ctypes.c_int),

        ("bk_get_error_message", [ctx], ctypes.c_char_p),
        ("bk_get_error_code", [ctx], ctypes.c_int),
        ("bk_run_jobs", [ctx], ctypes.c_int),
        # Host functions: one call installs a whole bk_fn_def table, ended by
        # an entry with a NULL name. Target 0 means globalThis.
        ("bk_set_function_list", [ctx, val, ctypes.POINTER(_FnDef)], ctypes.c_int),



        ("bk_get_new_target", [ctx], val),
        ("bk_is_constructor_call", [ctx], ctypes.c_int),

        ("bk_throw_error", [ctx, ctypes.c_int, ctypes.c_char_p], val),
        ("bk_throw", [ctx, val], val),
        # Constructors, for building a return value inside a callback. The
        # so ctypes cannot reach them.
        ("bk_new_number", [ctx, ctypes.c_double], val),
        ("bk_new_string", [ctx, ctypes.c_char_p, ctypes.c_size_t], val),
        ("bk_new_string_utf16", [ctx, ctypes.POINTER(ctypes.c_uint16),
                                 ctypes.c_size_t], val),
        ("bk_new_external_string_latin1", [ctx, ctypes.c_void_p, ctypes.c_size_t,
                                           _STRING_RELEASE, ctypes.c_void_p], val),
        ("bk_new_external_string_utf16", [ctx, ctypes.c_void_p, ctypes.c_size_t,
                                          _STRING_RELEASE, ctypes.c_void_p], val),
        ("bk_string_view_get", [ctx, val, ctypes.POINTER(_StringView)], ctypes.c_int),
        ("bk_dup_value", [ctx, val], val),
        ("bk_call", [ctx, val, val, ctypes.POINTER(val), ctypes.c_uint], val),
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

    __slots__ = ("_lib", "_ctx", "_runtime", "reader", "args", "raw", "_live", "_this")

    def __init__(self, lib, ctx, runtime, this_value, argc, argv):
        self._lib = lib
        self._ctx = ctx
        self._runtime = runtime
        self._live = True
        # One reader tier in v2: a callback's context resolves scope handles
        # and registry handles alike.
        self.reader = _Reader(lib, ctx)
        self._this = this_value
        handles = tuple(argv[i] for i in range(argc))
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
        handle = self._this
        value = self._wrap(handle, self.reader.type_of(handle))
        return value if isinstance(value, JsFunction) else value.to_python()

    @property
    def new_target(self):
        """new.target, or None on a plain call."""
        return self.reader.to_python(self._lib.bk_get_new_target(self._ctx))

    @property
    def runtime(self):
        """The Runtime this call is executing inside."""
        return self._runtime

    @property
    def is_construct(self):
        """True when invoked through `new` or `super()`."""
        return bool(self._lib.bk_is_constructor_call(self._ctx))

    def _wrap(self, handle, type_id):
        cls = JsFunction if type_id == _FUNCTION else JsValue
        return cls(self, handle, type_id)

    def _invoke(self, func, args):
        """Call a JS function from inside this host function, via bk_call."""
        if not self._live:
            raise JsError(-5, "this JS function outlived the host call it came "
                              "from; scope handles die when the callback returns")
        argv = (ctypes.c_uint64 * max(len(args), 1))()
        for i, arg in enumerate(args):
            argv[i] = self._to_js(arg)
        out = self._lib.bk_call(self._ctx, func, 0, argv, len(args))
        if out == 0:
            # The throw is already recorded on this context. Signal it to the
            # trampoline, which returns promptly and lets the engine propagate
            # the original JS exception rather than a new one.
            raise _Propagate()
        # bk_call hands back a registry handle, which this call's context
        # resolves like any other, so read it through the same reader.
        try:
            return self.reader.to_python(out)
        finally:
            self._lib.bk_free_value(self._ctx, out)

    def _to_js(self, value):
        """Forward this call's existing arguments to a JS callback."""
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
        raise JsError(-6, "cannot pass a new %s to a JS callback: this binding "
                          "forwards only this call's own arguments"
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
    """The ABI's readers, bound to the context that resolves handles.

    v2 has one context type: the runtime's own context at top level, the
    callback's context inside a host function. Both resolve registry handles
    and the borrowed call handles (arguments, this, new.target).
    """

    __slots__ = ("_owner", "type_of", "_read_bool", "_read_number", "_read_string_utf16")

    def __init__(self, lib, owner):
        self._owner = owner
        self.type_of = _bind(lib, "bk_get_type", owner)
        self._read_bool = _bind(lib, "bk_read_bool", owner)
        self._read_number = _bind(lib, "bk_read_number", owner)
        self._read_string_utf16 = _bind(lib, "bk_read_string_utf16", owner)

    def to_python(self, handle, type_id=None):
        """Convert a handle to a plain Python value."""
        if type_id is None:
            type_id = self.type_of(handle)
        if type_id in (_UNDEFINED, _NULL):
            return None
        if type_id == _BOOLEAN:
            out = ctypes.c_int()
            if self._read_bool(handle, ctypes.byref(out)) != _OK:
                return JsObject(type_id)
            return bool(out.value)
        if type_id == _NUMBER:
            out = ctypes.c_double()
            if self._read_number(handle, ctypes.byref(out)) != _OK:
                return JsObject(type_id)
            return out.value
        if type_id == _STRING:
            # UTF-16 round-trips a lone surrogate, which Python str can hold.
            size = ctypes.c_size_t(0)
            if self._read_string_utf16(handle, None, 0, ctypes.byref(size)) != _OK:
                return JsObject(type_id)
            buffer = (ctypes.c_uint16 * size.value)()
            if self._read_string_utf16(handle, buffer, size.value,
                                       ctypes.byref(size)) != _OK:
                return JsObject(type_id)
            return bytes(memoryview(buffer).cast("B")).decode(
                "utf-16-le", "surrogatepass")
        return JsObject(type_id)


def _bind(lib, name, owner):
    """Partially apply an ABI function to the runtime or context it reads through."""
    fn = getattr(lib, name)
    return lambda *rest: fn(owner, *rest)


# Every open Runtime, keyed by its engine pointer, so a call context can be
# mapped back to the Python object that owns it. Weak so that a Runtime the
# embedder has dropped stays collectable; entries also go on close().
_OPEN_RUNTIMES = weakref.WeakValueDictionary()


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
        # Every CFUNCTYPE trampoline handed to C lives here for the runtime's
        # lifetime. ctypes does NOT keep one alive on its own: drop the last
        # Python reference and the object is collected, leaving the engine
        # holding a pointer to freed memory that it will happily call. Since
        # bk_set_function_list is permanent for the runtime, so is this list.
        self._trampolines = []
        # The most recent Python exception a host function raised. JS only ever
        # sees its text, so keeping the object here preserves the traceback for
        # an embedder that wants to re-raise or log it after eval() returns.
        self._last_host_exception = None
        self._runtime = self._lib.bk_new_runtime(None)
        if not self._runtime:
            raise JsError(-1, "cannot create runtime")
        self._rt = self._lib.bk_new_context(self._runtime)
        if not self._rt:
            self._lib.bk_free_runtime(self._runtime)
            raise JsError(-1, "cannot create context")
        # The readers, for handles this Runtime owns.
        self._reader = _Reader(self._lib, self._rt)
        _OPEN_RUNTIMES[self._rt] = self

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
        handle = self._lib.bk_eval_ex(self._rt, encoded, len(encoded), b"<eval>", 0)
        if handle == 0:
            raise JsError(self._lib.bk_get_error_code(self._rt),
                          self._error_message())
        try:
            return self._to_python(handle)
        finally:
            # The handle occupies a registry slot, so release it even if
            # conversion raised.
            self._lib.bk_free_value(self._rt, handle)

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
        table = (_FnDef * 2)(_FnDef(encoded, trampoline, arity,
                                    1 if constructable else 0, None),
                             _FnDef())
        rc = self._lib.bk_set_function_list(self._rt, 0, table)
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

        def trampoline(ctx, this_value, argc, argv, _udata):
            call = None
            try:
                # A trampoline is created per registration, so `self` is the
                # Runtime this callback was bound to; there is no other tier
                # to consult in v2.
                call = Call(lib, ctx, self, this_value, argc, argv)
                result = pyfunc(call)
            except _Propagate:
                # bk_call already recorded the callee's throw on this context.
                # Returning now lets the engine propagate that exception intact.
                return 0
            except JsThrow as exc:
                return lib.bk_throw_error(ctx, _ERROR_KINDS[exc.kind],
                                    str(exc).encode("utf-8"))
            except BaseException as exc:
                # Stash the original so the embedder can inspect the Python
                # traceback after eval() returns; JS only ever sees the text.
                self._last_host_exception = exc
                kind = _ERROR_KINDS.get(type(exc).__name__, _ERROR)
                message = "%s: %s" % (type(exc).__name__, exc)
                return lib.bk_throw_error(ctx, kind, message.encode("utf-8"))
            finally:
                if call is not None:
                    # Scope handles die with the call; make the JsFunction
                    # objects that wrap them refuse to be used afterwards.
                    call._live = False
            try:
                return self._set_return(ctx, result)
            except BaseException as exc:
                return lib.bk_throw_error(ctx, _ERROR,
                                    ("cannot return %r to JS: %s"
                                     % (type(result).__name__, exc)).encode("utf-8"))

        return trampoline

    def _set_return(self, ctx, result):
        """Store a Python value as the call's JS return value."""
        lib = self._lib
        if result is None:
            return _HANDLE_UNDEFINED
        if isinstance(result, bool):
            # Checked before int: bool is a subclass of int in Python.
            handle = _HANDLE_TRUE if result else _HANDLE_FALSE
        elif isinstance(result, (int, float)):
            handle = lib.bk_new_number(ctx, float(result))
        elif isinstance(result, str):
            encoded = result.encode("utf-16-le", "surrogatepass")
            units = (ctypes.c_uint16 * (len(encoded) // 2)).from_buffer_copy(encoded)
            handle = lib.bk_new_string_utf16(ctx, units, len(units))
        elif isinstance(result, JsValue):
            # Returning an argument straight back, or the result of a callback.
            # The engine copies the returned handle, so it is passed as is.
            return result._handle
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
        return handle

    def drain_microtasks(self):
        """Run pending promise jobs. eval() already does this on its own."""
        self._check_open()
        self._lib.bk_run_jobs(self._runtime)

    def close(self):
        if self._rt:
            _OPEN_RUNTIMES.pop(self._rt, None)
            self._lib.bk_free_context(self._rt)
            self._lib.bk_free_runtime(self._runtime)
            self._runtime = None
            self._rt = None

    def __enter__(self):
        return self

    def __exit__(self, *exc_info):
        self.close()
        return False

    def _check_open(self):
        if not self._rt:
            raise JsError(-5, "this Runtime is closed")

    def _error_message(self):
        raw = self._lib.bk_get_error_message(self._rt)
        # The engine owns this buffer and overwrites it on the next call, so
        # decode (copy) immediately rather than holding the pointer.
        return raw.decode("utf-8", "replace") if raw else ""

    def _to_python(self, handle):
        # Strings emerge as real UTF-8: the engine converts its internal
        # CESU-8, so astral characters arrive as 4-byte sequences.
        return self._reader.to_python(handle)
