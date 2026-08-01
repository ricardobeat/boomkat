//! Minimal tour of the Zig binding: eval a value, read it back, let a failing
//! script surface as a Zig error, and expose Zig functions to JS.

const std = @import("std");
const js = @import("jse");

// --- host functions -------------------------------------------------------
//
// A host function is a plain Zig function taking a `js.Ctx`. `rt.register`
// generates the `callconv(.c)` trampoline the C ABI needs at comptime.

/// hypot(a, b) -> sqrt(a*a + b*b). Arguments in, a number out.
fn hypot(ctx: js.Ctx) !void {
    const a = try ctx.arg(0).toNumber();
    const b = try ctx.arg(1).toNumber();
    ctx.returnNumber(@sqrt(a * a + b * b));
}

/// Throws a JS RangeError, caught by JS below. `throwError` records the throw
/// and returns normally -- nothing unwinds through C -- so we return right after.
fn checkAge(ctx: js.Ctx) !void {
    const age = try ctx.arg(0).toNumber();
    if (age < 0) {
        ctx.throwError(.range, "age must not be negative");
        return;
    }
    ctx.returnBool(age >= 18);
}

/// mapTwice(f, x) -> f(f(x)): the host calling back into JS via jse_call.
/// If `f` throws, `ctx.call` yields error.Throw and the trampoline lets the
/// callee's own exception propagate unchanged.
fn mapTwice(ctx: js.Ctx) !void {
    var once = try ctx.call(ctx.arg(0), &.{ctx.arg(1)}, null);
    defer once.deinit();
    var twice = try ctx.call(ctx.arg(0), &.{once}, null);
    defer twice.deinit();
    ctx.ret(twice);
}

/// Runtime state reaches a callback through `udata`, since a Zig closure is
/// not C-ABI-compatible. The pointer must outlive the runtime.
fn bump(ctx: js.Ctx, counter: *u32) void {
    counter.* += 1;
    ctx.returnNumber(@floatFromInt(counter.*));
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();

    var out_buf: [4096]u8 = undefined;
    var out_file: std.Io.File.Writer = .init(.stdout(), init.io, &out_buf);
    const out = &out_file.interface;
    defer out.flush() catch {};

    try out.print("jse {s}\n", .{js.version()});

    // The runtime owns the engine; `defer deinit` tears it down.
    var rt = try js.Runtime.init();
    defer rt.deinit();

    // Scripts are evaluated for their completion value, like eval().
    var sum = try rt.eval("let n = 0; for (let i = 1; i <= 100; i++) n += i; n");
    defer sum.deinit();
    try out.print("sum 1..100 = {d}\n", .{try sum.toNumber()});

    // Values carry their JS type; readers are strict and never coerce.
    var joined = try rt.eval("[1, 2, 3, 4].map(x => x * x).join(',')");
    defer joined.deinit();
    const text = try joined.toString(gpa);
    try out.print("squares ({s}) = {s}\n", .{ @tagName(joined.typeOf()), text });

    // Failures are ordinary Zig errors, so `catch` and `try` both work. The
    // detail lives in rt.lastError().
    if (rt.eval("JSON.parse('{oops}')")) |_| {
        try out.print("unreachable: bad JSON parsed\n", .{});
    } else |err| {
        try out.print("{s}: {s}\n", .{ @errorName(err), rt.lastError() });
    }

    // A syntax error is a distinct error tag from a thrown exception.
    if (rt.eval("function (")) |_| {
        try out.print("unreachable: bad syntax compiled\n", .{});
    } else |err| {
        try out.print("{s}: {s}\n", .{ @errorName(err), rt.lastError() });
    }

    // --- host functions ---------------------------------------------------

    var calls: u32 = 0;
    try rt.register("hypot", hypot, .{ .arity = 2 });
    try rt.register("checkAge", checkAge, .{ .arity = 1 });
    try rt.register("mapTwice", mapTwice, .{ .arity = 2 });
    try rt.registerWith("bump", bump, &calls, .{});

    // Called from JS with arguments, returning a value.
    var h = try rt.eval("hypot(3, 4)");
    defer h.deinit();
    try out.print("hypot(3, 4) = {d}\n", .{try h.toNumber()});

    // Registered functions are ordinary function objects: .length, .apply,
    // and use as a callback to a built-in all work.
    var mapped = try rt.eval("[[3,4],[5,12]].map(p => hypot.apply(null, p)).join(',')");
    defer mapped.deinit();
    var arity = try rt.eval("hypot.length");
    defer arity.deinit();
    try out.print("mapped = {s} (hypot.length = {d})\n", .{
        try mapped.toString(gpa),
        try arity.toNumber(),
    });

    // A host throw, caught by JS.
    var caught = try rt.eval(
        \\try { checkAge(-1); 'no throw' }
        \\catch (e) { e.constructor.name + ': ' + e.message }
    );
    defer caught.deinit();
    try out.print("caught = {s}\n", .{try caught.toString(gpa)});

    // The host calling a JS callback, and a callee throw propagating back out
    // with its original type intact.
    var twice = try rt.eval("mapTwice(x => x * 3, 5)");
    defer twice.deinit();
    try out.print("mapTwice(x => x * 3, 5) = {d}\n", .{try twice.toNumber()});

    var propagated = try rt.eval(
        \\try { mapTwice(() => { throw new TypeError('from JS') }, 1); 'no throw' }
        \\catch (e) { e.constructor.name + ': ' + e.message }
    );
    defer propagated.deinit();
    try out.print("propagated = {s}\n", .{try propagated.toString(gpa)});

    // udata carries host state across calls.
    var bumped = try rt.eval("bump(); bump(); bump()");
    defer bumped.deinit();
    try out.print("bump() called {d} times, counter = {d}\n", .{
        calls,
        try bumped.toNumber(),
    });
}
