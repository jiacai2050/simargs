const std = @import("std");

const MODULE = "simargs";
pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const simargs_dep = b.addModule(MODULE, .{
        .source_file = .{ .path = "src/simargs.zig" },
    });

    // Test
    const tests = b.addTest(.{ .root_source_file = .{ .path = "src/simargs.zig" } });
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // Demo
    const demo_exe = b.addExecutable(.{ .name = "demo", .root_source_file = .{ .path = "demo.zig" }, .target = target, .optimize = optimize });
    demo_exe.addModule("simargs", simargs_dep);
    b.installArtifact(demo_exe);
    const run_demo = b.addRunArtifact(demo_exe);
    if (b.args) |args| {
        run_demo.addArgs(args);
    }
    // run_demo.addArgs(&[_][]const u8{
    //     "--output", "/tmp/simargs.txt", "hello", "world",
    // });

    const run_step = b.step("run-demo", "Run demo");
    run_step.dependOn(&run_demo.step);
}
