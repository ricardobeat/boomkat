//! Idiomatic Zig wrapper over the `jse_` C embedding ABI (see `include/jse.h`).
//!
//! Design notes:
//!   - C status codes become a Zig error set, so every fallible call is `try`.
//!   - `Runtime` and `Value` own their C resources and expose `deinit`, making
//!     them `defer`-friendly. `Value.deinit` is idempotent.
//!   - The engine is single-runtime-per-process and not thread-safe; a second
//!     `Runtime.init` returns `error.Invalid`.
//!   - Host functions are written as plain Zig functions taking a `Ctx`;
//!     `Runtime.register` builds the `callconv(.c)` trampoline at comptime and
//!     converts a returned Zig error into a JS throw.

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

/// A handle to a JS value.
///
/// Two flavours share this type, distinguished by `owned`:
///   - **Owned** handles come from `Runtime.eval` and `Ctx.persist`. The caller
///     must release them with `deinit`.
///   - **Scope** handles come from `Ctx.arg`/`.this`/`.newTarget` and are valid
///     only until the host callback returns. `deinit` on one is a no-op, so
///     `defer v.deinit()` stays correct either way.
///
/// Values do not outlive the `Runtime` that produced them.
pub const Value = struct {
    /// Null inside a host callback, where the readers accept a null runtime.
    rt: ?*Runtime = null,
    handle: c.jse_value,
    /// False for scope handles, which the engine reclaims on callback return.
    owned: bool = true,

    fn rtPtr(self: Value) c.jse_runtime {
        return if (self.rt) |r| r.ptr else null;
    }

    /// Release the handle. Idempotent, a no-op on scope handles, and safe to
    /// `defer` unconditionally.
    pub fn deinit(self: *Value) void {
        if (self.handle == 0 or !self.owned) return;
        c.jse_value_free(self.rtPtr(), self.handle);
        self.handle = 0;
    }

    pub fn typeOf(self: Value) Type {
        return @enumFromInt(c.jse_type_of(self.rtPtr(), self.handle));
    }

    /// Read a JS number. Does not coerce: fails with `error.WrongType` on
    /// anything that is not a number.
    pub fn toNumber(self: Value) Error!f64 {
        var out: f64 = undefined;
        try check(c.jse_get_number(self.rtPtr(), self.handle, &out));
        return out;
    }

    /// Read a JS boolean. Does not coerce.
    pub fn toBool(self: Value) Error!bool {
        var out: c_int = undefined;
        try check(c.jse_get_bool(self.rtPtr(), self.handle, &out));
        return out != 0;
    }

    /// Copy a JS string out as UTF-8. Does not coerce, so call `String(x)` in
    /// JS first if you want stringification. Caller owns the returned slice.
    pub fn toString(self: Value, gpa: std.mem.Allocator) (Error || std.mem.Allocator.Error)![]u8 {
        var len: usize = undefined;
        try check(c.jse_get_string(self.rtPtr(), self.handle, null, 0, &len));

        const buf = try gpa.alloc(u8, len + 1);
        errdefer gpa.free(buf);

        try check(c.jse_get_string(self.rtPtr(), self.handle, buf.ptr, buf.len, &len));
        return gpa.realloc(buf, len) catch buf[0..len];
    }
};

/// Error kinds `Ctx.throwError` can raise, mirroring `jse_error_kind`.
pub const ErrorKind = enum(c_int) {
    generic = c.JSE_ERROR,
    type = c.JSE_ERROR_TYPE,
    range = c.JSE_ERROR_RANGE,
    reference = c.JSE_ERROR_REFERENCE,
    syntax = c.JSE_ERROR_SYNTAX,
};

/// Knobs for `Runtime.register`.
pub const RegisterOptions = struct {
    /// The function's `.length` in JS. Does not constrain the actual argc.
    arity: c_int = 0,
    /// Whether `new fn()` is allowed. When false it throws a TypeError,
    /// matching how built-ins construct only when specified.
    constructable: bool = false,
    /// Passed back to every call untouched; usually set via `registerWith`.
    udata: ?*anyopaque = null,
};

/// The context of one in-flight host call.
///
/// Everything reachable from a `Ctx` dies when the callback returns, so a
/// `Ctx` must never be stored. Use `persist` to keep a value past the call.
pub const Ctx = struct {
    raw: c.jse_call_ctx,

    /// How many arguments this call was actually made with.
    pub fn argc(self: Ctx) u32 {
        return c.jse_argc(self.raw);
    }

    /// Argument `i` as a scope handle. Reading past `argc` yields `undefined`,
    /// matching JS, so there is no bounds error to handle.
    pub fn arg(self: Ctx, i: u32) Value {
        return .{ .handle = c.jse_arg(self.raw, i), .owned = false };
    }

    /// The `this` receiver. Strict semantics: an undefined receiver stays
    /// undefined rather than becoming the global object.
    pub fn this(self: Ctx) Value {
        return .{ .handle = c.jse_this(self.raw), .owned = false };
    }

    /// `new.target`, or `undefined` on a plain call.
    pub fn newTarget(self: Ctx) Value {
        return .{ .handle = c.jse_new_target(self.raw), .owned = false };
    }

    /// True when invoked through `new` or `super()`.
    pub fn isConstruct(self: Ctx) bool {
        return c.jse_is_construct(self.raw) != 0;
    }

    /// Set the return value. A callback that sets none yields `undefined`.
    pub fn ret(self: Ctx, v: Value) void {
        c.jse_return(self.raw, v.handle);
    }

    pub fn returnNumber(self: Ctx, d: f64) void {
        c.jse_return_number(self.raw, d);
    }

    pub fn returnBool(self: Ctx, b: bool) void {
        c.jse_return_bool(self.raw, @intFromBool(b));
    }

    pub fn returnNull(self: Ctx) void {
        c.jse_return_null(self.raw);
    }

    /// Return a fresh JS string copied from `utf8`.
    pub fn returnString(self: Ctx, utf8: []const u8) void {
        c.jse_return_string(self.raw, utf8.ptr, utf8.len);
    }

    /// Record a throw of a fresh `Error` of `kind`.
    ///
    /// This does not unwind: the callback keeps running and must return
    /// normally. A recorded throw beats any return value set alongside it, so
    /// the usual shape is `ctx.throwError(...); return;`.
    pub fn throwError(self: Ctx, kind: ErrorKind, msg: [:0]const u8) void {
        c.jse_throw_error(self.raw, @intFromEnum(kind), msg.ptr);
    }

    /// Record a throw of an arbitrary value. Same non-unwinding rule as
    /// `throwError`.
    pub fn throwValue(self: Ctx, v: Value) void {
        c.jse_throw(self.raw, v.handle);
    }

    /// Promote a scope handle to a runtime-owned one that outlives the call.
    /// The returned `Value` is owned, so `deinit` it. This is the only
    /// supported way to retain a value past the callback.
    pub fn persist(self: Ctx, rt: *Runtime, v: Value) Value {
        return .{ .rt = rt, .handle = c.jse_value_persist(self.raw, v.handle), .owned = true };
    }

    /// Call a JS function from inside the callback.
    ///
    /// Pass `null` for `this_val` to call with `undefined`. The result is an
    /// owned handle — `deinit` it — but it has no `Runtime` attached, which is
    /// fine: the readers accept a null runtime, and freeing it is a no-op
    /// against the scope. Prefer `callFree` when you only need to read it.
    ///
    /// If the callee throws, the exception is recorded on this context and
    /// `error.Throw` comes back; return promptly and let the engine propagate
    /// it. Host recursion is bounded, so a runaway host -> JS -> host chain
    /// raises a RangeError rather than blowing the native stack.
    pub fn call(self: Ctx, func: Value, args: []const Value, this_val: ?Value) Error!Value {
        var argv: [8]c.jse_value = undefined;
        const buf = if (args.len <= argv.len) argv[0..args.len] else return Error.Full;
        for (args, 0..) |a, i| buf[i] = a.handle;

        var out: c.jse_value = 0;
        try check(c.jse_call(
            self.raw,
            func.handle,
            if (buf.len == 0) null else buf.ptr,
            @intCast(buf.len),
            if (this_val) |t| t.handle else 0,
            &out,
        ));
        return .{ .handle = out, .owned = true };
    }
};

/// Build the `callconv(.c)` trampoline the ABI expects around a Zig function.
///
/// `func` may take `(Ctx)` or `(Ctx, *T)`, and may return `void` or an error
/// union. A returned error becomes a JS `Error` carrying the error's name,
/// because Zig errors cannot cross a C boundary.
fn trampoline(comptime func: anytype) c.jse_host_fn {
    const info = @typeInfo(@TypeOf(func)).@"fn";
    if (info.params.len != 1 and info.params.len != 2)
        @compileError("host function must take (Ctx) or (Ctx, *T)");

    const Shim = struct {
        fn invoke(raw: c.jse_call_ctx, udata: ?*anyopaque) callconv(.c) void {
            const ctx: Ctx = .{ .raw = raw };
            const result = if (info.params.len == 1)
                func(ctx)
            else
                func(ctx, @ptrCast(@alignCast(udata)));

            // Zig errors cannot unwind through C, so surface them as a throw.
            // error.Throw is the exception: it means a nested jse_ call already
            // recorded the real exception on this context, and re-throwing here
            // would replace a precise TypeError with a generic Error("Throw").
            if (@typeInfo(@TypeOf(result)) == .error_union) {
                _ = result catch |err| {
                    if (err != Error.Throw) ctx.throwError(.generic, @errorName(err));
                    return;
                };
            }
        }
    };
    return Shim.invoke;
}

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

    /// Bind a Zig function as a JS global named `name`.
    ///
    /// `func` is any function taking a `Ctx` (optionally plus a `*T` user-data
    /// pointer) and returning `void` or an error union. The `callconv(.c)`
    /// trampoline the ABI needs is generated at comptime, so hosts write
    /// ordinary Zig:
    ///
    /// ```zig
    /// fn add(ctx: js.Ctx) !void {
    ///     ctx.returnNumber(try ctx.arg(0).toNumber() + try ctx.arg(1).toNumber());
    /// }
    /// try rt.register("add", add, .{ .arity = 2 });
    /// ```
    ///
    /// An error returned by `func` cannot cross the C boundary, so the
    /// trampoline converts it into a JS `Error` whose message is the error
    /// name (`error.WrongType` becomes `throw new Error("WrongType")`). Throw
    /// deliberately with `ctx.throwError` when you want a specific kind or
    /// message; a recorded throw wins over any return value.
    ///
    /// `error.Throw` is passed through untouched, because it means a nested
    /// `ctx.call` already recorded the callee's own exception. So the natural
    /// `try ctx.call(...)` propagates a JS `TypeError` as a `TypeError`.
    ///
    /// Registration is permanent for the runtime's lifetime.
    pub fn register(
        self: *Runtime,
        name: []const u8,
        comptime func: anytype,
        opts: RegisterOptions,
    ) Error!void {
        try check(c.jse_register_fn(
            self.ptr,
            name.ptr,
            name.len,
            trampoline(func),
            opts.udata,
            opts.arity,
            @intFromBool(opts.constructable),
        ));
    }

    /// Bind a Zig function as a JS global, passing `udata` back to every call.
    ///
    /// `func` takes `(Ctx, *T)`. The pointer is passed through untouched and
    /// never dereferenced by the engine, so `udata` must outlive the runtime.
    pub fn registerWith(
        self: *Runtime,
        name: []const u8,
        comptime func: anytype,
        udata: anytype,
        opts: RegisterOptions,
    ) Error!void {
        var full = opts;
        full.udata = @constCast(@ptrCast(udata));
        try self.register(name, func, full);
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
    try std.testing.expectEqualStrings("Error: boom", rt.lastError());
}

// --- host function tests --------------------------------------------------

fn tSum(ctx: Ctx) !void {
    var total: f64 = 0;
    for (0..ctx.argc()) |i| total += try ctx.arg(@intCast(i)).toNumber();
    ctx.returnNumber(total);
}

fn tScale(ctx: Ctx, factor: *const f64) !void {
    ctx.returnNumber(try ctx.arg(0).toNumber() * factor.*);
}

fn tRefuse(ctx: Ctx) void {
    ctx.throwError(.range, "out of range");
}

/// Returns an error rather than throwing, to prove the trampoline converts it.
fn tStrict(ctx: Ctx) !void {
    ctx.returnBool(try ctx.arg(0).toBool());
}

/// twice(f, x) -> f(f(x)), the host calling back into JS.
fn tTwice(ctx: Ctx) !void {
    var once = try ctx.call(ctx.arg(0), &.{ctx.arg(1)}, null);
    defer once.deinit();
    var twice = try ctx.call(ctx.arg(0), &.{once}, null);
    defer twice.deinit();
    ctx.ret(twice);
}

test "host functions: arguments, udata, throws, and calling back into JS" {
    var rt = try Runtime.init();
    defer rt.deinit();

    const factor: f64 = 10;
    try rt.register("sum", tSum, .{ .arity = 2 });
    try rt.registerWith("scale", tScale, &factor, .{ .arity = 1 });
    try rt.register("refuse", tRefuse, .{});
    try rt.register("strict", tStrict, .{ .arity = 1 });
    try rt.register("twice", tTwice, .{ .arity = 2 });

    const expectEvalNumber = struct {
        fn f(r: *Runtime, src: []const u8, want: f64) !void {
            var v = try r.eval(src);
            defer v.deinit();
            try std.testing.expectEqual(want, try v.toNumber());
        }
    }.f;

    // Arguments in, value out; argc varies per call site.
    try expectEvalNumber(&rt, "sum(40, 2)", 42);
    try expectEvalNumber(&rt, "sum(1,2,3,4,5,6,7,8,9)", 45);
    try expectEvalNumber(&rt, "sum()", 0);

    // It is a real function object: .length, .apply, and use as a callback.
    try expectEvalNumber(&rt, "sum.length", 2);
    try expectEvalNumber(&rt, "sum.apply(null, [40, 2])", 42);
    try expectEvalNumber(&rt, "[[1,2],[3,4]].map(a => sum.apply(null, a))[1]", 7);

    // udata passthrough.
    try expectEvalNumber(&rt, "scale(4.2)", 42);

    // A deliberate throw arrives in JS as the requested error kind.
    try expectEvalNumber(&rt,
        \\try { refuse(); 0 } catch (e) { e instanceof RangeError && e.message === 'out of range' ? 42 : 0 }
    , 42);

    // A returned Zig error becomes a generic Error named after the error.
    try expectEvalNumber(&rt,
        \\try { strict('not a bool'); 0 } catch (e) { e.message === 'WrongType' ? 42 : 0 }
    , 42);

    // Host -> JS -> host, and a callee throw propagating back out.
    try expectEvalNumber(&rt, "twice(x => x + 21, 0)", 42);
    // A host function is an ordinary callee too: twice(scale, x) is scale(scale(x)).
    try expectEvalNumber(&rt, "twice(scale, 0.42)", 42);
    try expectEvalNumber(&rt,
        \\try { twice(() => { throw new TypeError('nope') }, 1); 0 }
        \\catch (e) { e instanceof TypeError ? 42 : 0 }
    , 42);

    // Bounded recursion throws rather than exhausting the native stack, and
    // the engine keeps working afterwards.
    try expectEvalNumber(&rt, "try { twice(function f(n) { return twice(f, n) }, 1); 0 } catch (e) { 42 }", 42);
    try expectEvalNumber(&rt, "sum(21, 21)", 42);
}
