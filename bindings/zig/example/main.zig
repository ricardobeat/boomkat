//! Minimal tour of the Zig binding: eval a value, read it back, and let a
//! failing script surface as a Zig error.

const std = @import("std");
const js = @import("jse");

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
}
