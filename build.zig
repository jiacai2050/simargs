const std = @import("std");

const MODULE = "simargs";
pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const lib = b.addStaticLibrary(.{ .name = MODULE, .target = target, .optimize = optimize, .root_source_file = .{ .path = "src/simargs.zig" } });
    lib.install();

    _ = b.addModule(MODULE, .{
        .source_file = .{ .path = "src/simargs.zig" },
    });

    const main_tests = b.addTest(.{ .target = target, .optimize = optimize, .root_source_file = .{ .path = "src/simargs.zig" } });

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);

    const demo_exe = b.addExecutable(.{ .name = "demo", .root_source_file = .{ .path = "demo.zig" }, .target = target, .optimize = optimize });
    demo_exe.addAnonymousModule("simargs", .{ .source_file = .{ .path = "src/simargs.zig" } });
    demo_exe.install();
    const run_demo = demo_exe.run();
    if (b.args) |args| {
        run_demo.addArgs(args);
    }
    // run_demo.addArgs(&[_][]const u8{
    //     "--output", "/tmp/simargs.txt", "hello", "world",
    // });

    const run_step = b.step("run-demo", "Run demo");
    run_step.dependOn(&run_demo.step);
}
