//! Idiomatic Zig wrapper over the `bk_` C embedding ABI (see `include/boomkat.h`).
//!
//! Design notes:
//!   - C status codes become a Zig error set, so every fallible call is `try`.
//!   - `Runtime` and `Value` own their C resources and expose `deinit`, making
//!     them `defer`-friendly. `Value.deinit` is idempotent.
//!   - Any number of runtimes may be open at once, each with its own globals,
//!     objects and interned strings. A runtime must be driven from one thread
//!     at a time; the engine has no locking and enforces nothing. Two threads
//!     each driving their own runtime share nothing and are fine.
//!   - A `Value` belongs to the runtime that produced it and carries that
//!     runtime's id in its handle, so handing one to a different runtime is
//!     `error.Invalid`, never a silently wrong answer.
//!   - Host functions are written as plain Zig functions taking a `Ctx`;
//!     `Runtime.register` builds the `callconv(.c)` trampoline at comptime and
//!     converts a returned Zig error into a JS throw.

const std = @import("std");

pub const c = @cImport({
    @cInclude("boomkat.h");
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
    /// Null/bad argument, or a bad handle -- including one belonging to a
    /// different runtime than the one asked to resolve it.
    Invalid,
    /// Value is not of the requested type (strict readers do not coerce).
    WrongType,
    /// Buffer too small.
    Full,
    /// Aborted by the runtime's interrupt handler.
    Interrupt,
};

fn check(status: c_int) Error!void {
    return switch (status) {
        c.BK_OK => {},
        c.BK_ERR_NOMEM => Error.OutOfMemory,
        c.BK_ERR_SYNTAX => Error.Syntax,
        c.BK_ERR_THROW => Error.Throw,
        c.BK_ERR_INVALID => Error.Invalid,
        c.BK_ERR_TYPE => Error.WrongType,
        c.BK_ERR_FULL => Error.Full,
        c.BK_ERR_INTERRUPT => Error.Interrupt,
        else => Error.Internal,
    };
}

/// The error a value-returning call left behind when it returned a null
/// handle: `bk_error_code` on the issuing context.
fn valueError(ctx: c.bk_ctx) Error {
    check(c.bk_error_code(ctx)) catch |e| return e;
    return Error.Internal;
}

/// JS value types, mirroring `bk_type`.
pub const Type = enum(c_int) {
    undefined = c.BK_TYPE_UNDEFINED,
    null = c.BK_TYPE_NULL,
    boolean = c.BK_TYPE_BOOLEAN,
    number = c.BK_TYPE_NUMBER,
    string = c.BK_TYPE_STRING,
    object = c.BK_TYPE_OBJECT,
    function = c.BK_TYPE_FUNCTION,
    /// symbol, bigint, ...
    other = c.BK_TYPE_OTHER,
};

/// Engine version, e.g. "0.2.0".
pub fn version() [:0]const u8 {
    return std.mem.span(c.bk_version());
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
/// A value belongs to the runtime that produced it and does not outlive it.
/// Handles carry the issuing runtime's id, so a handle given to the wrong
/// runtime is refused with `error.Invalid` rather than resolving to an
/// unrelated value. To move a value across runtimes, read it out and write it
/// back in.
pub const Value = struct {
    /// The context readers resolve through: the runtime's own context for
    /// top-level values, the callback's context inside a host function.
    owner: c.bk_ctx,
    handle: c.bk_value,
    /// False for scope handles, which the engine reclaims on callback return.
    owned: bool = true,

    /// Release the handle. Idempotent, a no-op on scope handles, and safe to
    /// `defer` unconditionally.
    pub fn deinit(self: *Value) void {
        if (self.handle == 0 or !self.owned) return;
        c.bk_free(self.owner, self.handle);
        self.handle = 0;
    }

    pub fn typeOf(self: Value) Type {
        return @enumFromInt(c.bk_type_of(self.owner, self.handle));
    }

    /// Read a JS number. Does not coerce: fails with `error.WrongType` on
    /// anything that is not a number.
    pub fn toNumber(self: Value) Error!f64 {
        var out: f64 = undefined;
        try check(c.bk_read_number(self.owner, self.handle, &out));
        return out;
    }

    /// Read a JS boolean. Does not coerce.
    pub fn toBool(self: Value) Error!bool {
        var out: c_int = undefined;
        try check(c.bk_read_bool(self.owner, self.handle, &out));
        return out != 0;
    }

    /// Copy a JS string out as UTF-8. Does not coerce, so call `String(x)` in
    /// JS first if you want stringification. Caller owns the returned slice.
    pub fn toString(self: Value, gpa: std.mem.Allocator) (Error || std.mem.Allocator.Error)![]u8 {
        var len: usize = undefined;
        try check(c.bk_read_string(self.owner, self.handle, null, 0, &len));

        const buf = try gpa.alloc(u8, len + 1);
        errdefer gpa.free(buf);

        try check(c.bk_read_string(self.owner, self.handle, buf.ptr, buf.len, &len));
        return gpa.realloc(buf, len) catch buf[0..len];
    }

    /// Any value as text, the way `String(v)` would render it. Coerces, so it
    /// may run user code and throw. The returned slice borrows context-owned
    /// storage that stays valid until the fourth following `bk_cstr` call on
    /// the context; copy it to keep it longer.
    pub fn cstr(self: Value) Error![:0]const u8 {
        const p = c.bk_cstr(self.owner, self.handle, null) orelse
            return valueError(self.owner);
        return std.mem.span(p);
    }

    /// Retag an owned handle onto `rt`, for a value persisted inside a callback
    /// that must stay readable after the call returns.
    ///
    /// `rt` must be the runtime the value came from. The runtime id inside the
    /// handle makes any other choice fail loudly with `error.Invalid` on the
    /// next read, but retagging is still a promise rather than a conversion:
    /// no bytes change hands.
    pub fn rebind(self: Value, rt: *Runtime) Value {
        return .{ .owner = rt.ptr, .handle = self.handle, .owned = self.owned };
    }
};

/// Error kinds `Ctx.throwError` can raise, mirroring `bk_error_kind`.
pub const ErrorKind = enum(c_int) {
    generic = c.BK_ERROR,
    type = c.BK_ERROR_TYPE,
    range = c.BK_ERROR_RANGE,
    reference = c.BK_ERROR_REFERENCE,
    syntax = c.BK_ERROR_SYNTAX,
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
    raw: c.bk_ctx,

    /// How many arguments this call was actually made with.
    pub fn argc(self: Ctx) u32 {
        return c.bk_argc(self.raw);
    }

    /// Argument `i` as a scope handle. Reading past `argc` yields `undefined`,
    /// matching JS, so there is no bounds error to handle.
    pub fn arg(self: Ctx, i: u32) Value {
        return .{ .owner = self.raw, .handle = c.bk_arg(self.raw, i), .owned = false };
    }

    /// The `this` receiver. Strict semantics: an undefined receiver stays
    /// undefined rather than becoming the global object.
    pub fn this(self: Ctx) Value {
        return .{ .owner = self.raw, .handle = c.bk_this(self.raw), .owned = false };
    }

    /// `new.target`, or `undefined` on a plain call.
    pub fn newTarget(self: Ctx) Value {
        return .{ .owner = self.raw, .handle = c.bk_new_target(self.raw), .owned = false };
    }

    /// True when invoked through `new` or `super()`.
    pub fn isConstruct(self: Ctx) bool {
        return c.bk_is_construct(self.raw) != 0;
    }

    /// Set the return value. A callback that sets none yields `undefined`.
    pub fn ret(self: Ctx, v: Value) void {
        c.bk_return(self.raw, v.handle);
    }

    pub fn returnNumber(self: Ctx, d: f64) void {
        c.bk_return_number(self.raw, d);
    }

    pub fn returnBool(self: Ctx, b: bool) void {
        c.bk_return_bool(self.raw, @intFromBool(b));
    }

    pub fn returnNull(self: Ctx) void {
        c.bk_return_null(self.raw);
    }

    /// Return a fresh JS string copied from `utf8`.
    pub fn returnString(self: Ctx, utf8: []const u8) void {
        const v = c.bk_string(self.raw, utf8.ptr, utf8.len);
        c.bk_return(self.raw, v);
    }

    /// Record a throw of a fresh `Error` of `kind`.
    ///
    /// This does not unwind: the callback keeps running and must return
    /// normally. A recorded throw beats any return value set alongside it, so
    /// the usual shape is `ctx.throwError(...); return;`.
    pub fn throwError(self: Ctx, kind: ErrorKind, msg: [:0]const u8) void {
        const k: c.bk_error_kind = @intCast(@intFromEnum(kind));
        c.bk_throw_error(self.raw, k, msg.ptr);
    }

    /// Record a throw of an arbitrary value. Same non-unwinding rule as
    /// `throwError`.
    pub fn throwValue(self: Ctx, v: Value) void {
        c.bk_throw(self.raw, v.handle);
    }

    /// Promote a scope handle to a runtime-owned one that outlives the call.
    /// The returned `Value` is owned, so `deinit` it. This is the only
    /// supported way to retain a value past the callback.
    ///
    /// The result stays tagged with this context, which dies when the call
    /// returns. To read it afterwards, retag it with `Value.rebind(&rt)`.
    pub fn persist(self: Ctx, v: Value) Error!Value {
        const h = c.bk_persist(self.raw, v.handle);
        if (h == 0) return valueError(self.raw);
        return .{ .owner = self.raw, .handle = h, .owned = true };
    }

    /// Call a JS function from inside the callback.
    ///
    /// Pass `null` for `this_val` to call with `undefined`. The result is an
    /// owned handle tagged with this context, so the readers resolve it and
    /// `deinit` frees it. To keep it past the callback, `rebind` it to the
    /// runtime first.
    ///
    /// If the callee throws, the exception is recorded on this context and
    /// `error.Throw` comes back; return promptly and let the engine propagate
    /// it. Host recursion is bounded, so a runaway host -> JS -> host chain
    /// raises a RangeError rather than blowing the native stack.
    pub fn call(self: Ctx, func: Value, args: []const Value, this_val: ?Value) Error!Value {
        var argv: [8]c.bk_value = undefined;
        const buf = if (args.len <= argv.len) argv[0..args.len] else return Error.Full;
        for (args, 0..) |a, i| buf[i] = a.handle;

        const h = c.bk_call(
            self.raw,
            func.handle,
            if (this_val) |t| t.handle else 0,
            if (buf.len == 0) null else buf.ptr,
            @intCast(buf.len),
        );
        if (h == 0) return valueError(self.raw);
        return .{ .owner = self.raw, .handle = h, .owned = true };
    }
};

/// Build the `callconv(.c)` trampoline the ABI expects around a Zig function.
///
/// `func` may take `(Ctx)` or `(Ctx, *T)`, and may return `void` or an error
/// union. A returned error becomes a JS `Error` carrying the error's name,
/// because Zig errors cannot cross a C boundary.
fn trampoline(comptime func: anytype) c.bk_host_fn {
    const info = @typeInfo(@TypeOf(func)).@"fn";
    if (info.params.len != 1 and info.params.len != 2)
        @compileError("host function must take (Ctx) or (Ctx, *T)");

    const Shim = struct {
        fn invoke(raw: c.bk_ctx, udata: ?*anyopaque) callconv(.c) void {
            const ctx: Ctx = .{ .raw = raw };
            const result = if (info.params.len == 1)
                func(ctx)
            else
                func(ctx, @ptrCast(@alignCast(udata)));

            // Zig errors cannot unwind through C, so surface them as a throw.
            // error.Throw is the exception: it means a nested bk_ call already
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

/// A JS engine instance: its own globals, objects, shapes and interned
/// strings, sharing nothing with any other runtime.
///
/// Any number may be open at once. Each must be driven from one thread at a
/// time -- the engine has no locking and enforces nothing -- but two threads
/// each driving their own runtime share no state and are fine.
pub const Runtime = struct {
    ptr: c.bk_ctx,

    /// Create a runtime, independent of any already open.
    ///
    /// The returned `Runtime` is returned by value but `Value` holds a pointer
    /// back to it, so keep it at a stable address (a local you never copy is
    /// fine; see the example).
    pub fn init() Error!Runtime {
        return .{ .ptr = c.bk_open() orelse return Error.OutOfMemory };
    }

    /// Destroy the runtime. All outstanding `Value`s from it become invalid;
    /// other runtimes are untouched.
    pub fn deinit(self: *Runtime) void {
        if (self.ptr == null) return;
        c.bk_close(self.ptr);
        self.ptr = null;
    }

    /// Compile and run `src`, evaluated for its completion value (so
    /// `"40 + 2"` yields 42). Pending microtasks are drained before returning.
    /// Caller owns the returned `Value`, which belongs to this runtime.
    pub fn eval(self: *Runtime, src: []const u8) Error!Value {
        const handle = c.bk_eval(self.ptr, src.ptr, src.len);
        if (handle == 0) return valueError(self.ptr);
        return .{ .owner = self.ptr, .handle = handle };
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
    /// Registration is permanent for the runtime's lifetime. `name` must fit
    /// in 255 bytes; longer names fail with `error.Full`.
    pub fn register(
        self: *Runtime,
        name: []const u8,
        comptime func: anytype,
        opts: RegisterOptions,
    ) Error!void {
        var buf: [256]u8 = undefined;
        const namez = std.fmt.bufPrintZ(&buf, "{s}", .{name}) catch return Error.Full;
        const def = c.bk_fn_def{
            .name = namez.ptr,
            .@"fn" = trampoline(func),
            .arity = opts.arity,
            .flags = if (opts.constructable) c.BK_CTOR else 0,
            .udata = opts.udata,
        };
        const table = [_]c.bk_fn_def{ def, std.mem.zeroes(c.bk_fn_def) };
        try check(c.bk_register(self.ptr, 0, &table));
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
        const handle = c.bk_eval(self.ptr, src.ptr, src.len);
        if (handle == 0) return valueError(self.ptr);
        c.bk_free(self.ptr, handle);
    }

    /// Message describing the most recent failure. Empty when there is none.
    /// Borrowed from the runtime and invalidated by the next call, so copy it
    /// if you need to keep it.
    pub fn lastError(self: *Runtime) [:0]const u8 {
        return std.mem.span(c.bk_error(self.ptr));
    }

    /// Run pending promise jobs. `eval` already drains, so this is only needed
    /// after resolving promises from host code.
    pub fn drain(self: *Runtime) Error!void {
        try check(c.bk_drain(self.ptr));
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

    // The coercion tier renders any value without a JS round-trip.
    try std.testing.expectEqualStrings("42", try n.cstr());

    try std.testing.expectError(Error.WrongType, n.toBool());
    try std.testing.expectError(Error.Syntax, rt.eval("var = = ="));
    try std.testing.expectError(Error.Throw, rt.eval("throw new Error('boom')"));
    try std.testing.expectEqualStrings("Error: boom", rt.lastError());
}

test "runtimes are independent and do not share values" {
    const gpa = std.testing.allocator;

    var a = try Runtime.init();
    defer a.deinit();
    var b = try Runtime.init();
    defer b.deinit();

    // Separate global scopes: the same name holds a different value in each.
    try a.exec("var tag = 'A'; var n = 111");
    try b.exec("var tag = 'B'; var n = 222");

    var a_tag = try a.eval("tag");
    defer a_tag.deinit();
    var b_tag = try b.eval("tag");
    defer b_tag.deinit();

    const a_text = try a_tag.toString(gpa);
    defer gpa.free(a_text);
    const b_text = try b_tag.toString(gpa);
    defer gpa.free(b_text);
    try std.testing.expectEqualStrings("A", a_text);
    try std.testing.expectEqualStrings("B", b_text);

    // Separate object graphs, built through the same property sequence so the
    // shape transitions interleave.
    try a.exec("var o = {}; for (let i = 0; i < 50; i++) o['k' + i] = i");
    try b.exec("var o = {}; for (let i = 0; i < 50; i++) o['k' + i] = i * 2");

    var a_k49 = try a.eval("o.k49");
    defer a_k49.deinit();
    var b_k49 = try b.eval("o.k49");
    defer b_k49.deinit();
    try std.testing.expectEqual(@as(f64, 49), try a_k49.toNumber());
    try std.testing.expectEqual(@as(f64, 98), try b_k49.toNumber());

    // Handles carry the id of the runtime that issued them, so A and B never
    // hand out bit-identical handles for unrelated values.
    var a_n = try a.eval("n");
    defer a_n.deinit();
    var b_n = try b.eval("n");
    defer b_n.deinit();
    try std.testing.expect(a_n.handle != b_n.handle);
    try std.testing.expectEqual(@as(f64, 111), try a_n.toNumber());
    try std.testing.expectEqual(@as(f64, 222), try b_n.toNumber());

    // A handle resolved against the wrong runtime is refused, even though the
    // slot it names is occupied there.
    try std.testing.expectError(Error.Invalid, a_n.rebind(&b).toNumber());

    // Moving a value across means reading it out and writing it back in.
    try b.exec("var fromA = 111");
    var moved = try b.eval("fromA + n");
    defer moved.deinit();
    try std.testing.expectEqual(@as(f64, 333), try moved.toNumber());

    // Closing one runtime leaves the other fully working.
    a.deinit();
    var after = try b.eval("n + 1");
    defer after.deinit();
    try std.testing.expectEqual(@as(f64, 223), try after.toNumber());
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

/// Records the udata tag of the runtime that called it: registration passes a
/// distinct tag per runtime, which is how a shared callback tells its callers
/// apart.
fn tWhich(ctx: Ctx, tag: *const u32) void {
    ctx.returnNumber(@floatFromInt(tag.*));
}

test "a callback knows its own runtime through udata, and registration is per-runtime" {
    var a = try Runtime.init();
    defer a.deinit();
    var b = try Runtime.init();
    defer b.deinit();

    const tag_a: u32 = 1;
    const tag_b: u32 = 2;
    try a.registerWith("which", tWhich, &tag_a, .{});
    try b.registerWith("which", tWhich, &tag_b, .{});
    try a.register("sum", tSum, .{ .arity = 2 });

    var from_a = try a.eval("which()");
    defer from_a.deinit();
    var from_b = try b.eval("which()");
    defer from_b.deinit();
    try std.testing.expectEqual(@as(f64, 1), try from_a.toNumber());
    try std.testing.expectEqual(@as(f64, 2), try from_b.toNumber());

    // Registration is per-runtime: `sum` exists only in A.
    var only_a = try a.eval("sum(40, 2)");
    defer only_a.deinit();
    try std.testing.expectEqual(@as(f64, 42), try only_a.toNumber());
    try std.testing.expectError(Error.Throw, b.eval("sum(40, 2)"));
}

/// Persists its argument, then reads it back through the runtime, exercising
/// the `persist` -> `rebind` handoff a host uses to keep a value.
fn tKeep(ctx: Ctx, slot: *Value) !void {
    slot.* = try ctx.persist(ctx.arg(0));
    ctx.returnBool(true);
}

test "a persisted value outlives the call and reads back through the runtime" {
    var rt = try Runtime.init();
    defer rt.deinit();

    var slot: Value = .{ .owner = rt.ptr, .handle = 0, .owned = false };
    try rt.registerWith("keep", tKeep, &slot, .{ .arity = 1 });

    var ok = try rt.eval("keep(42)");
    defer ok.deinit();
    try std.testing.expect(try ok.toBool());

    // The handle was tagged with the (now-finished) call context; retag it onto
    // the runtime to read it afterwards.
    var kept = slot.rebind(&rt);
    defer kept.deinit();
    try std.testing.expectEqual(@as(f64, 42), try kept.toNumber());
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
