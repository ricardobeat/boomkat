"""
ctypes wrapper for the jse_ embedding ABI.

Loads the shared library built by `make shared` and exposes a small Pythonic
surface over the same 12 exported symbols the C header declares.

    from jse import Runtime
    with Runtime("out/libjse.dylib") as rt:
        print(rt.eval("40 + 2"))   # 42.0
"""

import ctypes
import os
import sys

OK = 0
ERR_NOMEM, ERR_SYNTAX, ERR_THROW = -1, -2, -3
ERR_INTERNAL, ERR_INVALID, ERR_TYPE, ERR_FULL = -4, -5, -6, -7

(UNDEFINED, NULL, BOOLEAN, NUMBER, STRING, OBJECT, FUNCTION, OTHER) = range(8)


def _default_lib():
    ext = "dylib" if sys.platform == "darwin" else "so"
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(os.path.dirname(here))
    return os.path.join(root, "out", "libjse." + ext)


class JSError(Exception):
    """A syntax error, an uncaught JS throw, or an engine fault."""

    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def _bind(lib):
    lib.jse_open.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
    lib.jse_open.restype = ctypes.c_int
    lib.jse_close.argtypes = [ctypes.c_void_p]
    lib.jse_close.restype = None
    lib.jse_version.argtypes = []
    lib.jse_version.restype = ctypes.c_char_p
    lib.jse_eval.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t,
                             ctypes.POINTER(ctypes.c_uint)]
    lib.jse_eval.restype = ctypes.c_int
    lib.jse_value_free.argtypes = [ctypes.c_void_p, ctypes.c_uint]
    lib.jse_value_free.restype = None
    lib.jse_type_of.argtypes = [ctypes.c_void_p, ctypes.c_uint]
    lib.jse_type_of.restype = ctypes.c_int
    lib.jse_get_number.argtypes = [ctypes.c_void_p, ctypes.c_uint,
                                   ctypes.POINTER(ctypes.c_double)]
    lib.jse_get_number.restype = ctypes.c_int
    lib.jse_get_bool.argtypes = [ctypes.c_void_p, ctypes.c_uint,
                                 ctypes.POINTER(ctypes.c_int)]
    lib.jse_get_bool.restype = ctypes.c_int
    lib.jse_get_string.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_char_p,
                                   ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
    lib.jse_get_string.restype = ctypes.c_int
    lib.jse_last_error.argtypes = [ctypes.c_void_p]
    lib.jse_last_error.restype = ctypes.c_char_p
    lib.jse_last_error_code.argtypes = [ctypes.c_void_p]
    lib.jse_last_error_code.restype = ctypes.c_int
    lib.jse_drain_microtasks.argtypes = [ctypes.c_void_p]
    lib.jse_drain_microtasks.restype = None
    return lib


class Runtime:
    """One engine instance. Only one may exist per process."""

    def __init__(self, path=None):
        self.lib = _bind(ctypes.CDLL(path or _default_lib()))
        self._rt = ctypes.c_void_p()
        rc = self.lib.jse_open(ctypes.byref(self._rt))
        if rc != OK:
            raise JSError(rc, "jse_open failed (a runtime is already open?)")

    @property
    def version(self):
        return self.lib.jse_version().decode()

    def eval(self, src):
        """Evaluate source and return the completion value as a Python object."""
        raw = src.encode("utf-8")
        handle = ctypes.c_uint(0)
        rc = self.lib.jse_eval(self._rt, raw, len(raw), ctypes.byref(handle))
        if rc != OK:
            raise JSError(rc, self.lib.jse_last_error(self._rt).decode())
        try:
            return self._unwrap(handle.value)
        finally:
            self.lib.jse_value_free(self._rt, handle.value)

    def drain_microtasks(self):
        self.lib.jse_drain_microtasks(self._rt)

    def _unwrap(self, h):
        t = self.lib.jse_type_of(self._rt, h)
        if t == UNDEFINED:
            return None
        if t == NULL:
            return None
        if t == BOOLEAN:
            out = ctypes.c_int()
            self.lib.jse_get_bool(self._rt, h, ctypes.byref(out))
            return bool(out.value)
        if t == NUMBER:
            out = ctypes.c_double()
            self.lib.jse_get_number(self._rt, h, ctypes.byref(out))
            return out.value
        if t == STRING:
            return self._read_string(h)
        return _Opaque(t)

    def _read_string(self, h):
        # Two-call protocol: measure with a NULL buffer, then fill.
        n = ctypes.c_size_t(0)
        rc = self.lib.jse_get_string(self._rt, h, None, 0, ctypes.byref(n))
        if rc != OK:
            raise JSError(rc, "jse_get_string measure failed")
        buf = ctypes.create_string_buffer(n.value + 1)
        rc = self.lib.jse_get_string(self._rt, h, buf, n.value + 1, ctypes.byref(n))
        if rc != OK:
            raise JSError(rc, "jse_get_string read failed")
        return buf.raw[:n.value].decode("utf-8")

    def close(self):
        if self._rt:
            self.lib.jse_close(self._rt)
            self._rt = ctypes.c_void_p()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


class _Opaque:
    """A value with no Python equivalent (object, function, symbol)."""

    _NAMES = {OBJECT: "object", FUNCTION: "function", OTHER: "other"}

    def __init__(self, type_id):
        self.type_id = type_id

    def __repr__(self):
        return "<jse %s>" % self._NAMES.get(self.type_id, "value")


if __name__ == "__main__":
    with Runtime() as rt:
        print("version:", rt.version)
        print("40 + 2 =", rt.eval("40 + 2"))
        print("string:", repr(rt.eval("'hi ' + String.fromCodePoint(0x1F600)")))
        print("array:", rt.eval("[1,2,3].map(n => n*n).join(',')"))
        try:
            rt.eval("throw new Error('boom')")
        except JSError as e:
            print("caught:", e.code, e)
