"""Pure-Python ctypes binding for the jse_ embedding ABI (see include/jse.h).

No C extension, no build step: this module dlopen()s the shared library built
by `make shared` and talks to the twelve exported C symbols directly.

    from js import Runtime, JsError

    with Runtime() as rt:
        print(rt.eval("[1, 2, 3].reduce((a, b) => a + b)"))   # 6.0

JS values come back as Python objects: numbers as float, strings as str,
booleans as bool, null/undefined as None. Objects and functions have no Python
equivalent, so they surface as an opaque JsObject; stringify them in JS
(JSON.stringify, String(x)) if you need their contents.

Only one Runtime may exist per process -- the engine keeps process-global
state. Opening a second one raises JsError. The engine is not thread-safe.
"""

import ctypes
import os
import sys

__all__ = ["Runtime", "JsError", "JsObject", "version"]

# Status codes from jse.h. 0 is success; every error is negative.
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

# Value types from jse_type_of.
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


class JsError(Exception):
    """A JS-side failure: syntax error, uncaught throw, or engine fault.

    `code` is the raw jse_status integer; `kind` is a human-readable name for
    it. The message is whatever the engine reported.
    """

    def __init__(self, code, message):
        super().__init__(message or _STATUS_NAMES.get(code, "error"))
        self.code = code
        self.kind = _STATUS_NAMES.get(code, "error")


class JsObject:
    """A JS value with no Python equivalent (object, function, symbol, ...)."""

    __slots__ = ("type_name",)

    def __init__(self, type_id):
        self.type_name = _TYPE_NAMES.get(type_id, "value")

    def __repr__(self):
        return "<js %s>" % self.type_name


def default_library_path():
    """Locate libjse next to this checkout, as `make shared` leaves it."""
    if sys.platform == "darwin":
        name = "libjse.dylib"
    elif sys.platform == "win32":
        name = "jse.dll"
    else:
        name = "libjse.so"
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    return os.path.join(root, "out", name)


def _declare(lib):
    """Pin argtypes/restype on every symbol.

    This is not optional hygiene: without argtypes, ctypes defaults pointer
    arguments to 32-bit int on some platforms and truncates the runtime handle.
    """
    rt, u32 = ctypes.c_void_p, ctypes.c_uint
    signatures = [
        ("jse_open", [ctypes.POINTER(ctypes.c_void_p)], ctypes.c_int),
        ("jse_close", [rt], None),
        ("jse_version", [], ctypes.c_char_p),
        ("jse_eval", [rt, ctypes.c_char_p, ctypes.c_size_t,
                      ctypes.POINTER(u32)], ctypes.c_int),
        ("jse_value_free", [rt, u32], None),
        ("jse_type_of", [rt, u32], ctypes.c_int),
        ("jse_get_number", [rt, u32, ctypes.POINTER(ctypes.c_double)], ctypes.c_int),
        ("jse_get_bool", [rt, u32, ctypes.POINTER(ctypes.c_int)], ctypes.c_int),
        ("jse_get_string", [rt, u32, ctypes.c_char_p, ctypes.c_size_t,
                            ctypes.POINTER(ctypes.c_size_t)], ctypes.c_int),
        ("jse_last_error", [rt], ctypes.c_char_p),
        ("jse_last_error_code", [rt], ctypes.c_int),
        ("jse_drain_microtasks", [rt], None),
    ]
    for name, argtypes, restype in signatures:
        fn = getattr(lib, name)
        fn.argtypes = argtypes
        fn.restype = restype
    return lib


def _load(path):
    path = path or os.environ.get("JSE_LIBRARY") or default_library_path()
    try:
        return _declare(ctypes.CDLL(path))
    except OSError as exc:
        raise JsError(-5, "cannot load the jse shared library from %r "
                          "(run `make shared` first): %s" % (path, exc)) from exc


def version(path=None):
    """Engine version string. Does not require an open Runtime."""
    return _load(path).jse_version().decode("utf-8")


class Runtime:
    """One JavaScript engine instance, usable as a context manager.

    Closing is idempotent, and `with` closes on the way out even if the body
    raised, so the engine heap is never leaked.
    """

    def __init__(self, library_path=None):
        self._lib = _load(library_path)
        self._rt = ctypes.c_void_p()
        rc = self._lib.jse_open(ctypes.byref(self._rt))
        if rc != _OK:
            raise JsError(rc, "jse_open failed (is another Runtime already open? "
                              "the engine allows one per process)")

    @property
    def version(self):
        return self._lib.jse_version().decode("utf-8")

    def eval(self, source):
        """Evaluate JS source and return its completion value.

        Raises JsError on a syntax error or an uncaught throw. Pending promise
        jobs are drained by the engine before this returns.
        """
        self._check_open()
        encoded = source.encode("utf-8")
        handle = ctypes.c_uint(0)
        rc = self._lib.jse_eval(self._rt, encoded, len(encoded), ctypes.byref(handle))
        if rc != _OK:
            raise JsError(rc, self._error_message())
        try:
            return self._to_python(handle.value)
        finally:
            # The handle occupies a slot in a fixed-size registry, so release
            # it even if conversion raised.
            self._lib.jse_value_free(self._rt, handle.value)

    def drain_microtasks(self):
        """Run pending promise jobs. eval() already does this on its own."""
        self._check_open()
        self._lib.jse_drain_microtasks(self._rt)

    def close(self):
        if self._rt:
            self._lib.jse_close(self._rt)
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
        raw = self._lib.jse_last_error(self._rt)
        # The engine owns this buffer and overwrites it on the next call, so
        # decode (copy) immediately rather than holding the pointer.
        return raw.decode("utf-8", "replace") if raw else ""

    def _to_python(self, handle):
        type_id = self._lib.jse_type_of(self._rt, handle)
        if type_id in (_UNDEFINED, _NULL):
            return None
        if type_id == _BOOLEAN:
            out = ctypes.c_int()
            self._expect(self._lib.jse_get_bool(self._rt, handle, ctypes.byref(out)))
            return bool(out.value)
        if type_id == _NUMBER:
            out = ctypes.c_double()
            self._expect(self._lib.jse_get_number(self._rt, handle, ctypes.byref(out)))
            return out.value
        if type_id == _STRING:
            return self._read_string(handle)
        return JsObject(type_id)

    def _read_string(self, handle):
        # Two-call protocol: a NULL buffer measures, then we allocate and fill.
        size = ctypes.c_size_t(0)
        self._expect(self._lib.jse_get_string(self._rt, handle, None, 0,
                                              ctypes.byref(size)))
        buffer = ctypes.create_string_buffer(size.value + 1)
        self._expect(self._lib.jse_get_string(self._rt, handle, buffer,
                                              size.value + 1, ctypes.byref(size)))
        # The engine emits real UTF-8 here, converting its internal CESU-8, so
        # astral characters arrive as proper 4-byte sequences.
        return buffer.raw[:size.value].decode("utf-8")

    def _expect(self, rc):
        if rc != _OK:
            raise JsError(rc, self._error_message())
