const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const lib = b.addStaticLibrary("simargs", "src/simargs.zig");
    lib.setBuildMode(mode);
    lib.install();

    const main_tests = b.addTest("src/simargs.zig");
    main_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);

    const demo_exe = b.addExecutable("demo", "demo.zig");
    demo_exe.addPackagePath("simargs", "src/simargs.zig");
    demo_exe.setBuildMode(mode);
    demo_exe.install();
    const run_demo = demo_exe.run();
    run_demo.addArgs(&[_][]const u8{
        "--action", "show-time", "hello", "world",
    });

    const run_step = b.step("run-demo", "Run demo");
    run_step.dependOn(&run_demo.step);
}
