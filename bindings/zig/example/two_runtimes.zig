//! Two runtimes open at once: independent globals and objects, a host function
//! registered in both, and a value from one refused by the other.
//!
//! Each runtime has its own globals, objects, shapes and interned strings and
//! shares nothing with the other. A runtime must be driven from one thread at a
//! time -- the engine has no locking -- but two threads each driving their own
//! runtime share no state.

const std = @import("std");
const js = @import("jse");

/// Registered in both runtimes. `ctx.runtime()` tells the call which runtime it
/// is running in, so one function body can serve several.
fn label(ctx: js.Ctx, tag: *const []const u8) void {
    ctx.returnString(tag.*);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();

    var out_buf: [4096]u8 = undefined;
    var out_file: std.Io.File.Writer = .init(.stdout(), init.io, &out_buf);
    const out = &out_file.interface;
    defer out.flush() catch {};

    // Two runtimes, open simultaneously.
    var a = try js.Runtime.init();
    defer a.deinit();
    var b = try js.Runtime.init();
    defer b.deinit();

    // --- independent globals ----------------------------------------------

    try a.exec("var tag = 'alpha-A'; var n = 111");
    try b.exec("var tag = 'beta-B';  var n = 222");

    var a_tag = try a.eval("tag + '/' + n");
    defer a_tag.deinit();
    var b_tag = try b.eval("tag + '/' + n");
    defer b_tag.deinit();
    try out.print("A globals = {s}\n", .{try a_tag.toString(gpa)});
    try out.print("B globals = {s}\n", .{try b_tag.toString(gpa)});

    // --- independent objects ----------------------------------------------
    //
    // The same property sequence in both, so the shape transitions interleave.

    try a.exec("var o = {}; for (let i = 0; i < 200; i++) o['k' + i] = i");
    try b.exec("var o = {}; for (let i = 0; i < 200; i++) o['k' + i] = i * 2");

    var a_k = try a.eval("o.k199");
    defer a_k.deinit();
    var b_k = try b.eval("o.k199");
    defer b_k.deinit();
    try out.print("A o.k199 = {d}, B o.k199 = {d}\n", .{
        try a_k.toNumber(),
        try b_k.toNumber(),
    });

    // --- one host function, two runtimes ----------------------------------

    const a_name: []const u8 = "from-A";
    const b_name: []const u8 = "from-B";
    try a.registerWith("label", label, &a_name, .{});
    try b.registerWith("label", label, &b_name, .{});

    var a_lbl = try a.eval("label()");
    defer a_lbl.deinit();
    var b_lbl = try b.eval("label()");
    defer b_lbl.deinit();
    try out.print("A label() = {s}, B label() = {s}\n", .{
        try a_lbl.toString(gpa),
        try b_lbl.toString(gpa),
    });

    // --- values do not cross runtimes -------------------------------------
    //
    // A handle is an index into ONE runtime's registry, and both runtimes
    // number their slots from the same base -- the handles below are equal as
    // integers. Offering a handle to the wrong runtime is a programming error:
    // it is caught only when that slot happens to be empty in the receiving
    // runtime, and otherwise reads out whatever unrelated value lives there.
    // Keep each value with its own runtime; do not rely on being told.

    var a_n = try a.eval("n");
    defer a_n.deinit();
    var b_n = try b.eval("n");
    defer b_n.deinit();
    try out.print("A handle {d} = {d}, B handle {d} = {d}\n", .{
        a_n.handle, try a_n.toNumber(),
        b_n.handle, try b_n.toNumber(),
    });

    // Same integer, different runtime, different value: nothing about the
    // handle itself distinguishes them.
    const smuggled = a_n.rebind(&b);
    if (smuggled.toNumber()) |v| {
        try out.print("A's handle read by B = {d} (B's own value, not A's)\n", .{v});
    } else |err| {
        try out.print("A's handle read by B = {s} (slot empty in B)\n", .{@errorName(err)});
    }

    // To move a value, read it out of one runtime and write it back into the
    // other. Numbers, strings and JSON all travel fine.
    var json = try a.eval("JSON.stringify({ from: tag, n })");
    defer json.deinit();
    const payload = try json.toString(gpa);

    var script: std.ArrayList(u8) = .empty;
    try script.appendSlice(gpa, "var imported = ");
    try script.appendSlice(gpa, payload);
    try script.appendSlice(gpa, "; imported.from + ' carried ' + imported.n");

    var carried = try b.eval(script.items);
    defer carried.deinit();
    try out.print("moved into B = {s}\n", .{try carried.toString(gpa)});

    // --- lifetimes are independent ----------------------------------------

    a.deinit();
    var after = try b.eval("tag + ' still works, n=' + n");
    defer after.deinit();
    try out.print("after closing A: {s}\n", .{try after.toString(gpa)});
}
