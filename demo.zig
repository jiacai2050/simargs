const std = @import("std");
const simargs = @import("simargs");

pub const log_level: std.log.Level = .info;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var opt = try simargs.parse(allocator, struct {
        // Those fields declare arguments options
        // only `output` is required, others are all optional
        verbose: ?bool,
        @"user-agent": enum { Chrome, Firefox, Safari } = .Firefox,
        timeout: ?u16 = 30, // default value
        output: []const u8,

        // This declares option's short name
        pub const __shorts__ = .{
            .verbose = .v,
            .output = .o,
            .@"user-agent" = .A,
        };

        // This declares option's help message
        pub const __messages__ = .{
            .verbose = "Make the operation more talkative",
            .output = "Write to file instead of stdout",
            .timeout = "Max time this request can cost",
        };
    });
    defer opt.deinit();

    const sep = "-" ** 30;
    std.debug.print("{s}Program{s}\n{s}\n\n", .{ sep, sep, opt.program });
    std.debug.print("{s}Arguments{s}\n", .{ sep, sep });
    inline for (std.meta.fields(@TypeOf(opt.args))) |fld| {
        const format = "{s:>10}: " ++ switch (fld.field_type) {
            []const u8 => "{s}",
            ?[]const u8 => "{?s}",
            else => "{any}",
        } ++ "\n";
        std.debug.print(format, .{ fld.name, @field(opt.args, fld.name) });
    }
    std.debug.print("\n{s}Positionals{s}\n", .{ sep, sep });
    for (opt.positional_args.items) |arg, idx| {
        std.debug.print("{d}: {s}\n", .{ idx + 1, arg });
    }

    // Provide a print_help util method
    std.debug.print("\n{s}print_help{s}\n", .{ sep, sep });
    const stdout = std.io.getStdOut();
    try opt.print_help(stdout.writer(), "[file]");
}
