//! Build script for the Zig binding to the bk_ C ABI.
//! Written for Zig 0.16.0 (`b.createModule` + `.root_module`).
//!
//! By default this links the SHARED library built by `make shared` at the repo
//! root, two directories up. Override either path with:
//!   zig build run -Dboomkat-include=/usr/local/include -Dboomkat-lib=/usr/local/lib/boomkat.dylib
//!
//! Why the dylib and not out/boomkat.a: the C3 runtime discovers its @init
//! constructors by walking the init sections of the running image at startup.
//! When a foreign linker (Zig's) produces the final executable, that walk binds
//! to the wrong image header -- Zig emits a second, bogus __mh_execute_header
//! in __DATA,__bss -- and faults before main() runs. Linking the dylib, which
//! c3c linked itself, keeps the walk correct because dyld runs those
//! constructors against the library's own header. Static linking of this
//! archive into a non-c3c-linked binary is not currently supported.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const include_dir = b.option(
        []const u8,
        "boomkat-include",
        "Directory containing boomkat.h (default: ../../include)",
    ) orelse b.pathFromRoot("../../include");

    const default_lib = switch (target.result.os.tag) {
        .macos => "../../out/boomkat.dylib",
        else => "../../out/boomkat.so",
    };
    const lib_path = b.option(
        []const u8,
        "boomkat-lib",
        "Path to the boomkat shared library (default: ../../out/boomkat.<dylib|so>)",
    ) orelse b.pathFromRoot(default_lib);

    // The binding module: importable as `@import("boomkat")` by consumers.
    const mod = b.addModule("boomkat", .{
        .root_source_file = b.path("src/js.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addIncludePath(.{ .cwd_relative = include_dir });
    mod.addObjectFile(.{ .cwd_relative = lib_path });

    // The dylib's install name is @rpath/boomkat.dylib, so the executable needs
    // an rpath pointing at the directory it was linked from.
    const lib_dir = std.fs.path.dirname(lib_path) orelse ".";
    mod.addRPathSpecial(lib_dir);

    const Example = struct {
        name: []const u8,
        path: []const u8,
        step: []const u8,
        desc: []const u8,
    };
    const examples = [_]Example{
        .{
            .name = "boomkat-example",
            .path = "example/main.zig",
            .step = "run",
            .desc = "Build and run the example",
        },
        .{
            .name = "boomkat-two-runtimes",
            .path = "example/two_runtimes.zig",
            .step = "run-two-runtimes",
            .desc = "Build and run the two-runtime example",
        },
    };

    for (examples) |ex| {
        const exe = b.addExecutable(.{
            .name = ex.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(ex.path),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "boomkat", .module = mod }},
            }),
        });
        b.installArtifact(exe);

        const run = b.addRunArtifact(exe);
        run.step.dependOn(b.getInstallStep());
        if (b.args) |args| run.addArgs(args);
        b.step(ex.step, ex.desc).dependOn(&run.step);
    }

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run the binding's unit tests").dependOn(&run_tests.step);
}
