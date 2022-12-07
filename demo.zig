const std = @import("std");
const argsParser = @import("simargs");

pub const log_level: std.log.Level = .info;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var opt = try argsParser.parse(allocator, struct {
        // Those fields declare arguments options
        // only `action` is required, others are all optional
        help: ?i64,
        version: ?bool,
        action: []const u8,
        name: ?[]const u8,
        age: ?f64 = 30, // default value

        // This declares option's short name
        pub const __shorts__ = .{
            .help = .h,
            .action = .a,
        };

        // This declares option's help message
        pub const __messages__ = .{
            .help = "show help", //
            .action = "tell me what you want to do", //
            .age = "How old are you",
        };
    });
    defer opt.deinit();

    std.log.info("program is {s}", .{opt.program});
    inline for (std.meta.fields(@TypeOf(opt.args))) |fld| {
        std.log.info("option name:{s}, value:{any}", .{ fld.name, @field(opt.args, fld.name) });
    }

    // Provide a print_help util method
    try opt.print_help();
}
