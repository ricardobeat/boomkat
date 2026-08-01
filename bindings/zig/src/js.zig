//! Idiomatic Zig wrapper over the `jse_` C embedding ABI (see `include/jse.h`).
//!
//! Design notes:
//!   - C status codes become a Zig error set, so every fallible call is `try`.
//!   - `Runtime` and `Value` own their C resources and expose `deinit`, making
//!     them `defer`-friendly. `Value.deinit` is idempotent.
//!   - The engine is single-runtime-per-process and not thread-safe; a second
//!     `Runtime.init` returns `error.Invalid`.

const std = @import("std");

pub const c = @cImport({
    @cInclude("jse.h");
});

/// Every failure the ABI can report. `Syntax` and `Throw` carry a message
/// retrievable with `Runtime.lastError`.
pub const Error = error{
    OutOfMemory,
    /// Source failed to compile.
    Syntax,
    /// Script threw an uncaught exception.
    Throw,
    /// Engine fault with no JS error attached.
    Internal,
    /// Null/bad argument, bad handle, or a second runtime in this process.
    Invalid,
    /// Value is not of the requested type (readers do not coerce).
    WrongType,
    /// Buffer too small, or the 1024-slot handle table is exhausted.
    Full,
};

fn check(status: c_int) Error!void {
    return switch (status) {
        c.JSE_OK => {},
        c.JSE_ERR_NOMEM => Error.OutOfMemory,
        c.JSE_ERR_SYNTAX => Error.Syntax,
        c.JSE_ERR_THROW => Error.Throw,
        c.JSE_ERR_INVALID => Error.Invalid,
        c.JSE_ERR_TYPE => Error.WrongType,
        c.JSE_ERR_FULL => Error.Full,
        else => Error.Internal,
    };
}

/// JS value types, mirroring `jse_type`.
pub const Type = enum(c_int) {
    undefined = c.JSE_TYPE_UNDEFINED,
    null = c.JSE_TYPE_NULL,
    boolean = c.JSE_TYPE_BOOLEAN,
    number = c.JSE_TYPE_NUMBER,
    string = c.JSE_TYPE_STRING,
    object = c.JSE_TYPE_OBJECT,
    function = c.JSE_TYPE_FUNCTION,
    /// symbol, bigint, ...
    other = c.JSE_TYPE_OTHER,
};

/// Engine version, e.g. "0.1.0".
pub fn version() [:0]const u8 {
    return std.mem.span(c.jse_version());
}

/// A handle to a JS value. Owned by the caller: release it with `deinit`.
/// Values do not outlive the `Runtime` that produced them.
pub const Value = struct {
    rt: *Runtime,
    handle: c.jse_value,

    /// Release the handle. Idempotent, and safe to `defer` unconditionally.
    pub fn deinit(self: *Value) void {
        if (self.handle == 0) return;
        c.jse_value_free(self.rt.ptr, self.handle);
        self.handle = 0;
    }

    pub fn typeOf(self: Value) Type {
        return @enumFromInt(c.jse_type_of(self.rt.ptr, self.handle));
    }

    /// Read a JS number. Does not coerce: fails with `error.WrongType` on
    /// anything that is not a number.
    pub fn toNumber(self: Value) Error!f64 {
        var out: f64 = undefined;
        try check(c.jse_get_number(self.rt.ptr, self.handle, &out));
        return out;
    }

    /// Read a JS boolean. Does not coerce.
    pub fn toBool(self: Value) Error!bool {
        var out: c_int = undefined;
        try check(c.jse_get_bool(self.rt.ptr, self.handle, &out));
        return out != 0;
    }

    /// Copy a JS string out as UTF-8. Does not coerce, so call `String(x)` in
    /// JS first if you want stringification. Caller owns the returned slice.
    pub fn toString(self: Value, gpa: std.mem.Allocator) (Error || std.mem.Allocator.Error)![]u8 {
        var len: usize = undefined;
        try check(c.jse_get_string(self.rt.ptr, self.handle, null, 0, &len));

        const buf = try gpa.alloc(u8, len + 1);
        errdefer gpa.free(buf);

        try check(c.jse_get_string(self.rt.ptr, self.handle, buf.ptr, buf.len, &len));
        return gpa.realloc(buf, len) catch buf[0..len];
    }
};

/// The JS engine instance. Only one may exist per process.
pub const Runtime = struct {
    ptr: c.jse_runtime,

    /// Create the runtime. Returns `error.Invalid` if one is already open.
    ///
    /// The returned `Runtime` is returned by value but `Value` holds a pointer
    /// back to it, so keep it at a stable address (a local you never copy is
    /// fine; see the example).
    pub fn init() Error!Runtime {
        var ptr: c.jse_runtime = null;
        try check(c.jse_open(&ptr));
        return .{ .ptr = ptr };
    }

    /// Destroy the runtime. All outstanding `Value`s become invalid.
    pub fn deinit(self: *Runtime) void {
        if (self.ptr == null) return;
        c.jse_close(self.ptr);
        self.ptr = null;
    }

    /// Compile and run `src`, evaluated for its completion value (so
    /// `"40 + 2"` yields 42). Pending microtasks are drained before returning.
    /// Caller owns the returned `Value`.
    pub fn eval(self: *Runtime, src: []const u8) Error!Value {
        var handle: c.jse_value = 0;
        try check(c.jse_eval(self.ptr, src.ptr, src.len, &handle));
        return .{ .rt = self, .handle = handle };
    }

    /// Run `src` purely for its side effects, discarding the result.
    pub fn exec(self: *Runtime, src: []const u8) Error!void {
        try check(c.jse_eval(self.ptr, src.ptr, src.len, null));
    }

    /// Message describing the most recent failure. Empty when there is none.
    /// Borrowed from the runtime and invalidated by the next call, so copy it
    /// if you need to keep it.
    pub fn lastError(self: *Runtime) [:0]const u8 {
        return std.mem.span(c.jse_last_error(self.ptr));
    }

    /// Run pending promise jobs. `eval` already drains, so this is only needed
    /// after resolving promises from host code.
    pub fn drainMicrotasks(self: *Runtime) void {
        c.jse_drain_microtasks(self.ptr);
    }
};

test "eval, read back, and surface errors" {
    const gpa = std.testing.allocator;

    var rt = try Runtime.init();
    defer rt.deinit();

    var n = try rt.eval("40 + 2");
    defer n.deinit();
    try std.testing.expectEqual(Type.number, n.typeOf());
    try std.testing.expectEqual(@as(f64, 42), try n.toNumber());

    var s = try rt.eval("['a','b'].join('-')");
    defer s.deinit();
    const text = try s.toString(gpa);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("a-b", text);

    try std.testing.expectError(Error.WrongType, n.toBool());
    try std.testing.expectError(Error.Syntax, rt.eval("var = = ="));
    try std.testing.expectError(Error.Throw, rt.eval("throw new Error('boom')"));
    try std.testing.expectEqualStrings("boom", rt.lastError());
}
