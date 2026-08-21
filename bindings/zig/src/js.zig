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
//!   - A `Value` belongs to the runtime that produced it and carries a
//!     reference to its owner, so the reader tier is picked for you. Handing a
//!     value to a different runtime yields `error.Invalid`.
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
    /// Value is not of the requested type (readers do not coerce).
    WrongType,
    /// Buffer too small, or the 1024-slot handle table is exhausted.
    Full,
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
        else => Error.Internal,
    };
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

/// Engine version, e.g. "0.1.0".
pub fn version() [:0]const u8 {
    return std.mem.span(c.bk_version());
}

/// Who resolves a `Value`'s handle.
///
/// A handle indexes one runtime's registry, so reading it requires naming that
/// runtime. Outside a callback you hold a `*Runtime`; inside one you hold a
/// `bk_call_ctx` and no runtime, and only the context tier can resolve the
/// scope handles `Ctx.arg`/`.this`/`.newTarget` return. `Value` records which
/// it has, so callers use the same four readers either way.
const Owner = union(enum) {
    runtime: *Runtime,
    ctx: c.bk_call_ctx,
};

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
/// Handles are not portable between runtimes: every runtime numbers its
/// registry slots from the same base, so the same integer is a live handle in
/// each. A handle given to the wrong runtime yields `error.Invalid` only when
/// that slot is empty there; otherwise it reads out an unrelated value. Treat
/// crossing runtimes as a bug rather than something you will be told about --
/// to move a value, read it out and write it back in.
pub const Value = struct {
    owner: Owner,
    handle: c.bk_value,
    /// False for scope handles, which the engine reclaims on callback return.
    owned: bool = true,

    /// Release the handle. Idempotent, a no-op on scope handles, and safe to
    /// `defer` unconditionally.
    pub fn deinit(self: *Value) void {
        if (self.handle == 0 or !self.owned) return;
        switch (self.owner) {
            .runtime => |r| c.bk_value_free(r.ptr, self.handle),
            .ctx => |ctx| c.bk_value_free(c.bk_ctx_runtime(ctx), self.handle),
        }
        self.handle = 0;
    }

    pub fn typeOf(self: Value) Type {
        return @enumFromInt(switch (self.owner) {
            .runtime => |r| c.bk_type_of(r.ptr, self.handle),
            .ctx => |ctx| c.bk_ctx_type_of(ctx, self.handle),
        });
    }

    /// Read a JS number. Does not coerce: fails with `error.WrongType` on
    /// anything that is not a number.
    pub fn toNumber(self: Value) Error!f64 {
        var out: f64 = undefined;
        try check(switch (self.owner) {
            .runtime => |r| c.bk_get_number(r.ptr, self.handle, &out),
            .ctx => |ctx| c.bk_ctx_get_number(ctx, self.handle, &out),
        });
        return out;
    }

    /// Read a JS boolean. Does not coerce.
    pub fn toBool(self: Value) Error!bool {
        var out: c_int = undefined;
        try check(switch (self.owner) {
            .runtime => |r| c.bk_get_bool(r.ptr, self.handle, &out),
            .ctx => |ctx| c.bk_ctx_get_bool(ctx, self.handle, &out),
        });
        return out != 0;
    }

    /// Copy a JS string out as UTF-8. Does not coerce, so call `String(x)` in
    /// JS first if you want stringification. Caller owns the returned slice.
    pub fn toString(self: Value, gpa: std.mem.Allocator) (Error || std.mem.Allocator.Error)![]u8 {
        var len: usize = undefined;
        try check(self.readString(null, 0, &len));

        const buf = try gpa.alloc(u8, len + 1);
        errdefer gpa.free(buf);

        try check(self.readString(buf.ptr, buf.len, &len));
        return gpa.realloc(buf, len) catch buf[0..len];
    }

    /// Retag an owned handle onto `rt`, for a value persisted inside a callback
    /// that must stay readable after the call returns.
    ///
    /// `rt` must be the runtime the value came from. Retagging onto any other
    /// runtime is undetected whenever that slot is occupied there, and reads
    /// back an unrelated value, so this is a promise you make rather than one
    /// the engine checks.
    pub fn rebind(self: Value, rt: *Runtime) Value {
        return .{ .owner = .{ .runtime = rt }, .handle = self.handle, .owned = self.owned };
    }

    /// The two-call `bk_get_string` protocol, on whichever tier owns us.
    fn readString(self: Value, buf: ?[*]u8, cap: usize, len: *usize) c_int {
        return switch (self.owner) {
            .runtime => |r| c.bk_get_string(r.ptr, self.handle, buf, cap, len),
            .ctx => |ctx| c.bk_ctx_get_string(ctx, self.handle, buf, cap, len),
        };
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
    raw: c.bk_call_ctx,

    /// How many arguments this call was actually made with.
    pub fn argc(self: Ctx) u32 {
        return c.bk_argc(self.raw);
    }

    /// Argument `i` as a scope handle. Reading past `argc` yields `undefined`,
    /// matching JS, so there is no bounds error to handle.
    pub fn arg(self: Ctx, i: u32) Value {
        return .{ .owner = .{ .ctx = self.raw }, .handle = c.bk_arg(self.raw, i), .owned = false };
    }

    /// The `this` receiver. Strict semantics: an undefined receiver stays
    /// undefined rather than becoming the global object.
    pub fn this(self: Ctx) Value {
        return .{ .owner = .{ .ctx = self.raw }, .handle = c.bk_this(self.raw), .owned = false };
    }

    /// `new.target`, or `undefined` on a plain call.
    pub fn newTarget(self: Ctx) Value {
        return .{ .owner = .{ .ctx = self.raw }, .handle = c.bk_new_target(self.raw), .owned = false };
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
        c.bk_return_string(self.raw, utf8.ptr, utf8.len);
    }

    /// Record a throw of a fresh `Error` of `kind`.
    ///
    /// This does not unwind: the callback keeps running and must return
    /// normally. A recorded throw beats any return value set alongside it, so
    /// the usual shape is `ctx.throwError(...); return;`.
    pub fn throwError(self: Ctx, kind: ErrorKind, msg: [:0]const u8) void {
        c.bk_throw_error(self.raw, @intFromEnum(kind), msg.ptr);
    }

    /// Record a throw of an arbitrary value. Same non-unwinding rule as
    /// `throwError`.
    pub fn throwValue(self: Ctx, v: Value) void {
        c.bk_throw(self.raw, v.handle);
    }

    /// The runtime this call is running in, for a host that needs to identify
    /// or act on the runtime behind a callback -- telling apart two runtimes
    /// sharing one registered function, or naming the runtime to `rebind` a
    /// persisted value onto once the call returns.
    ///
    /// The returned `Runtime` borrows the engine instance -- it is the same
    /// one the embedder opened, so do not `deinit` it here. It is returned by
    /// value while `Value` holds a pointer back to it, so bind it to a local
    /// (`var rt = ctx.runtime();`) and pass `&rt`.
    ///
    /// Do not re-enter the VM through it: calling `eval`/`exec` on this
    /// runtime while the callback is still on the stack corrupts the
    /// interpreter. Use `Ctx.call` to invoke JS from inside a host function.
    pub fn runtime(self: Ctx) Runtime {
        return .{ .ptr = c.bk_ctx_runtime(self.raw) };
    }

    /// Promote a scope handle to a runtime-owned one that outlives the call.
    /// The returned `Value` is owned, so `deinit` it. This is the only
    /// supported way to retain a value past the callback.
    ///
    /// The result stays tagged with this context, which resolves to the right
    /// runtime for as long as the call is on the stack. To read it after the
    /// callback returns, retag it with `Value.rebind(&rt)`.
    pub fn persist(self: Ctx, v: Value) Value {
        return .{
            .owner = .{ .ctx = self.raw },
            .handle = c.bk_value_persist(self.raw, v.handle),
            .owned = true,
        };
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

        var out: c.bk_value = 0;
        try check(c.bk_call(
            self.raw,
            func.handle,
            if (buf.len == 0) null else buf.ptr,
            @intCast(buf.len),
            if (this_val) |t| t.handle else 0,
            &out,
        ));
        return .{ .owner = .{ .ctx = self.raw }, .handle = out, .owned = true };
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
        fn invoke(raw: c.bk_call_ctx, udata: ?*anyopaque) callconv(.c) void {
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
    ptr: c.bk_runtime,

    /// Create a runtime, independent of any already open.
    ///
    /// The returned `Runtime` is returned by value but `Value` holds a pointer
    /// back to it, so keep it at a stable address (a local you never copy is
    /// fine; see the example).
    pub fn init() Error!Runtime {
        var ptr: c.bk_runtime = null;
        try check(c.bk_open(&ptr));
        return .{ .ptr = ptr };
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
        var handle: c.bk_value = 0;
        try check(c.bk_eval(self.ptr, src.ptr, src.len, &handle));
        return .{ .owner = .{ .runtime = self }, .handle = handle };
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
        try check(c.bk_register_fn(
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
        try check(c.bk_eval(self.ptr, src.ptr, src.len, null));
    }

    /// Message describing the most recent failure. Empty when there is none.
    /// Borrowed from the runtime and invalidated by the next call, so copy it
    /// if you need to keep it.
    pub fn lastError(self: *Runtime) [:0]const u8 {
        return std.mem.span(c.bk_last_error(self.ptr));
    }

    /// Run pending promise jobs. `eval` already drains, so this is only needed
    /// after resolving promises from host code.
    pub fn drainMicrotasks(self: *Runtime) void {
        c.bk_drain_microtasks(self.ptr);
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

    // Handles are per-runtime registry indices, numbered from the same base in
    // every runtime, so A and B hand out equal integers for unrelated values.
    var a_n = try a.eval("n");
    defer a_n.deinit();
    var b_n = try b.eval("n");
    defer b_n.deinit();
    try std.testing.expectEqual(a_n.handle, b_n.handle);
    try std.testing.expectEqual(@as(f64, 111), try a_n.toNumber());
    try std.testing.expectEqual(@as(f64, 222), try b_n.toNumber());

    // Crossing runtimes is a programming error the engine does not reliably
    // catch: with the slot occupied in B, B answers with its OWN value.
    try std.testing.expectEqual(@as(f64, 222), try a_n.rebind(&b).toNumber());

    // It only surfaces as error.Invalid when the slot is empty in the receiver.
    var fresh = try Runtime.init();
    defer fresh.deinit();
    try std.testing.expectError(Error.Invalid, a_n.rebind(&fresh).toNumber());

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

/// Records which runtime the in-flight call belongs to, so the test can check
/// `ctx.runtime()` against the runtime it evaluated through.
fn tWhich(ctx: Ctx, seen: *c.bk_runtime) void {
    seen.* = ctx.runtime().ptr;
    ctx.returnNumber(@floatFromInt(ctx.argc()));
}

test "a callback reaches its own runtime, and registration is per-runtime" {
    var a = try Runtime.init();
    defer a.deinit();
    var b = try Runtime.init();
    defer b.deinit();

    var seen_a: c.bk_runtime = null;
    var seen_b: c.bk_runtime = null;
    try a.registerWith("which", tWhich, &seen_a, .{});
    try b.registerWith("which", tWhich, &seen_b, .{});
    try a.register("sum", tSum, .{ .arity = 2 });

    var from_a = try a.eval("which(1, 2)");
    defer from_a.deinit();
    var from_b = try b.eval("which(1)");
    defer from_b.deinit();
    try std.testing.expectEqual(@as(f64, 2), try from_a.toNumber());
    try std.testing.expectEqual(@as(f64, 1), try from_b.toNumber());

    // ctx.runtime() is the runtime that made the call, never the other one.
    try std.testing.expect(seen_a == a.ptr);
    try std.testing.expect(seen_b == b.ptr);
    try std.testing.expect(seen_a != seen_b);

    // Registration is per-runtime: `sum` exists only in A.
    var only_a = try a.eval("sum(40, 2)");
    defer only_a.deinit();
    try std.testing.expectEqual(@as(f64, 42), try only_a.toNumber());
    try std.testing.expectError(Error.Throw, b.eval("sum(40, 2)"));
}

/// Persists its argument, then reads it back through the runtime, exercising
/// the `persist` -> `rebind` handoff a host uses to keep a value.
fn tKeep(ctx: Ctx, slot: *Value) !void {
    slot.* = ctx.persist(ctx.arg(0));
    ctx.returnBool(true);
}

test "a persisted value outlives the call and reads back through the runtime" {
    var rt = try Runtime.init();
    defer rt.deinit();

    var slot: Value = .{ .owner = .{ .runtime = &rt }, .handle = 0, .owned = false };
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
