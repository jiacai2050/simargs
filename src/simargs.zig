//! A simple, opinionated, struct-based argument parser in Zig

const std = @import("std");
const testing = std.testing;

const ParseError = error{ NoProgram, NoOption, MissingRequiredOption, MissingOptionValue };

const OptionError = ParseError || std.mem.Allocator.Error || std.fmt.ParseIntError || std.fmt.ParseFloatError;

/// Parses arguments according to the given structure.
/// - `T` is the configuration of the arguments.
pub fn parse(
    allocator: std.mem.Allocator,
    comptime T: type,
) OptionError!StructArguments(T) {
    const args = try std.process.argsAlloc(allocator);
    var parser = OptionParser(T).init(allocator, args);
    return parser.parse();
}

const OptionField = struct {
    long_name: []const u8,
    opt_type: OptionType,
    short_name: ?u8 = null,
    message: ?[]const u8 = null,
    // whether this option is set
    is_set: bool = false,
};

fn parseOptionFields(comptime T: type) [std.meta.fields(T).len]OptionField {
    const option_type_info = @typeInfo(T);
    if (option_type_info != .Struct) {
        @compileError("option should be defined using struct, found " ++ @typeName(T));
    }

    var opt_fields: [std.meta.fields(T).len]OptionField = undefined;
    inline for (option_type_info.Struct.fields) |fld, idx| {
        const long_name = fld.name;
        const opt_type = OptionType.from_zig_type(
            fld.field_type,
        );
        opt_fields[idx] = .{
            .long_name = long_name,
            .opt_type = opt_type,
            // option with default value is set automatically
            .is_set = !(fld.default_value == null),
        };
    }

    // parse short names
    if (@hasDecl(T, "__shorts__")) {
        const shorts_type = @TypeOf(T.__shorts__);
        if (@typeInfo(shorts_type) != .Struct) {
            @compileError("__shorts__ should be defined using struct, found " ++ @typeName(@typeInfo(shorts_type)));
        }

        comptime inline for (std.meta.fields(shorts_type)) |fld| {
            const long_name = fld.name;
            inline for (opt_fields) |*opt_fld| {
                if (std.mem.eql(u8, opt_fld.long_name, long_name)) {
                    const short_name = @field(T.__shorts__, long_name);
                    if (@typeInfo(@TypeOf(short_name)) != .EnumLiteral) {
                        @compileError("short option value must be literal enum, found " ++ @typeName(@typeInfo(@TypeOf(short_name))));
                    }
                    opt_fld.short_name = @tagName(short_name)[0];

                    break;
                }
            } else {
                @compileError("no such option exists, long_name: " ++ long_name);
            }
        };
    }

    // parse messages
    if (@hasDecl(T, "__messages__")) {
        const messages_type = @TypeOf(T.__messages__);
        if (@typeInfo(messages_type) != .Struct) {
            @compileError("__messages__ should be defined using struct, found " ++ @typeName(@typeInfo(messages_type)));
        }

        inline for (std.meta.fields(messages_type)) |fld| {
            const long_name = fld.name;
            inline for (opt_fields) |*opt_fld| {
                if (std.mem.eql(u8, opt_fld.long_name, long_name)) {
                    opt_fld.message = @field(T.__messages__, long_name);
                    break;
                }
            } else {
                @compileError("no such option exists, long_name: " ++ long_name);
            }
        }
    }

    return opt_fields;
}

test "parse option fields" {
    const fields = comptime parseOptionFields(struct {
        verbose: bool,
        help: ?bool,
        timeout: u16,
        @"user-agent": ?[]const u8,

        pub const __shorts__ = .{
            .verbose = .v,
        };

        pub const __messages__ = .{
            .verbose = "show verbose log",
        };
    });

    try std.testing.expectEqual(4, fields.len);
    const first_opt = OptionField{ .long_name = "verbose", .short_name = 'v', .message = "show verbose log", .opt_type = .RequiredBool };
    try std.testing.expectEqualStrings(first_opt.long_name, fields[0].long_name);
    try std.testing.expectEqual(first_opt.message, fields[0].message);
    try std.testing.expectEqual(first_opt.short_name, fields[0].short_name);
    try std.testing.expectEqual(first_opt.opt_type, fields[0].opt_type);
    try std.testing.expectEqual(first_opt.is_set, fields[0].is_set);
    const last_opt = OptionField{ .long_name = "user-agent", .opt_type = .String };
    try std.testing.expectEqualStrings(last_opt.long_name, fields[3].long_name);
    try std.testing.expectEqual(last_opt.message, fields[3].message);
    try std.testing.expectEqual(last_opt.short_name, fields[3].short_name);
    try std.testing.expectEqual(last_opt.opt_type, fields[3].opt_type);
    try std.testing.expectEqual(last_opt.is_set, fields[3].is_set);
}

fn StructArguments(comptime T: type) type {
    return struct {
        program: []const u8,
        // Parsed arguments
        args: T,
        // Unparsed arguments
        raw_args: [][:0]u8,
        positional_args: std.ArrayList([]const u8),
        allocator: std.mem.Allocator,

        pub fn deinit(self: @This()) void {
            self.positional_args.deinit();
            if (!@import("builtin").is_test) {
                std.process.argsFree(self.allocator, self.raw_args);
            }
        }

        pub fn print_help(
            self: @This(),
            writer: anytype,
        ) !void {
            const fields = comptime parseOptionFields(T);
            const header_tmpl =
                \\ USAGE:
                \\     {s} [OPTIONS] ...
                \\
                \\ OPTIONS:
                \\
            ;
            const header = try std.fmt.allocPrint(self.allocator, header_tmpl, .{
                self.program,
            });
            defer self.allocator.free(header);

            try writer.writeAll(header);
            // TODO: Maybe be too small(or big)?
            const msg_offset = 25;
            inline for (fields) |opt_fld| {
                try writer.writeAll("\t");
                if (opt_fld.short_name) |sn| {
                    try writer.writeAll("-");
                    try writer.writeAll(&[_]u8{sn});
                    try writer.writeAll(", ");
                } else {
                    try writer.writeAll("    ");
                }
                try writer.writeAll("--");
                try writer.writeAll(opt_fld.long_name);

                var blanks = msg_offset - (4 + 2 + opt_fld.long_name.len);
                while (blanks > 0) {
                    try writer.writeAll(" ");
                    blanks -= 1;
                }

                if (opt_fld.message) |msg| {
                    try writer.writeAll(msg);
                    try writer.writeAll(" ");
                }
                inline for (std.meta.fields(T)) |f| {
                    if (std.mem.eql(u8, f.name, opt_fld.long_name)) {
                        if (f.default_value) |v| {
                            const default = @ptrCast(*align(1) const f.field_type, v).*;
                            switch (@TypeOf(default)) {
                                []const u8 => try std.fmt.format(writer, "[default:{s}]", .{default}),
                                ?[]const u8 => try std.fmt.format(writer, "[default:{?s}]", .{default}),
                                else => try std.fmt.format(writer, "[default:{any}]", .{default}),
                            }
                        }
                    }
                }
                try writer.writeAll(opt_fld.opt_type.as_string());
                try writer.writeAll("\n");
            }
        }
    };
}

const OptionType = enum(u32) {
    const REQUIRED_VERSION_SHIFT = 16;
    const Self = @This();

    RequiredInt,
    RequiredBool,
    RequiredFloat,
    RequiredString,

    Int = Self.REQUIRED_VERSION_SHIFT,
    Bool,
    Float,
    String,

    fn from_zig_type(
        comptime T: type,
    ) OptionType {
        return Self.convert(T, false);
    }

    fn convert(comptime T: type, comptime is_optional: bool) OptionType {
        const base_type: Self = switch (@typeInfo(T)) {
            .Int => .RequiredInt,
            .Bool => .RequiredBool,
            .Float => .RequiredFloat,
            .Optional => |opt_info| return Self.convert(opt_info.child, true),
            .Pointer => |ptr_info|
            // only support []const u8
            if (ptr_info.size == .Slice and ptr_info.child == u8 and ptr_info.is_const)
                .RequiredString
            else {
                @compileError("not supported option type:" ++ @typeName(T));
            },
            else => {
                @compileError("not supported option type:" ++ @typeName(T));
            },
        };
        return @intToEnum(@This(), @enumToInt(base_type) + if (is_optional) @This().REQUIRED_VERSION_SHIFT else 0);
    }

    fn is_required(self: Self) bool {
        return @enumToInt(self) < REQUIRED_VERSION_SHIFT;
    }

    fn as_string(self: Self) []const u8 {
        return switch (self) {
            .Int => "[type: integer]",
            .RequiredInt => "[type: integer][REQUIRED]",
            .Bool => "[type: bool]",
            .RequiredBool => "[type: bool][REQUIRED]",
            .Float => "[type: float]",
            .RequiredFloat => "[type: float][REQUIRED]",
            .String => "[type: string]",
            .RequiredString => "[type: string][REQUIRED]",
        };
    }
};

test "parse OptionType" {
    try std.testing.expectEqual(OptionType.RequiredInt, comptime OptionType.from_zig_type(i32));
    try std.testing.expectEqual(OptionType.Int, comptime OptionType.from_zig_type(?i32));
    try std.testing.expectEqual(OptionType.RequiredString, comptime OptionType.from_zig_type([]const u8));
    try std.testing.expectEqual(OptionType.String, comptime OptionType.from_zig_type(?[]const u8));
}

fn OptionParser(
    comptime T: type,
) type {
    return struct {
        allocator: std.mem.Allocator,
        args: [][:0]u8,
        opt_fields: [std.meta.fields(T).len]OptionField,

        const Self = @This();

        // `T` is a struct, which define options
        fn init(allocator: std.mem.Allocator, args: [][:0]u8) Self {
            return .{
                .allocator = allocator,
                .args = args,
                .opt_fields = comptime parseOptionFields(T),
            };
        }

        // State machine used to parse arguments. Available state transitions:
        // 1. start -> args
        // 2. start -> waitValue -> .. -> waitValue --> args -> ... -> args
        // 3. start

        const ParseState = enum {
            start,
            waitValue,
            waitBoolValue,
            args,
        };

        fn parse(self: *Self) OptionError!StructArguments(T) {
            if (self.args.len == 0) {
                return error.NoProgram;
            }

            var result = StructArguments(T){
                .program = self.args[0],
                .allocator = self.allocator,
                .args = undefined,
                .positional_args = std.ArrayList([]const u8).init(self.allocator),
                .raw_args = self.args,
            };
            errdefer result.deinit();

            comptime inline for (std.meta.fields(T)) |fld| {
                if (fld.default_value) |v| {
                    // https://github.com/ziglang/zig/blob/d69e97ae1677ca487833caf6937fa428563ed0ae/lib/std/json.zig#L1590
                    // why align(1) is used here?
                    @field(result.args, fld.name) = @ptrCast(*align(1) const fld.field_type, v).*;
                } else {
                    if (!OptionType.from_zig_type(fld.field_type).is_required()) {
                        @field(result.args, fld.name) = null;
                    }
                }
            };

            var state = ParseState.start;
            var current_opt: ?*OptionField = null;

            var arg_idx: usize = 1;
            while (arg_idx < self.args.len) {
                const arg = self.args[arg_idx];
                arg_idx += 1;
                std.log.debug("state:{s}, arg:{s}", .{ @tagName(
                    state,
                ), arg });

                switch (state) {
                    .start => {
                        if (!std.mem.startsWith(u8, arg, "-")) {
                            // no option any more, the rest are positional args
                            state = .args;
                            arg_idx -= 1;
                            continue;
                        }

                        if (std.mem.startsWith(u8, arg[1..], "-")) {
                            // long option
                            const long_name = arg[2..];
                            for (self.opt_fields) |*opt_fld| {
                                if (std.mem.eql(u8, opt_fld.long_name, long_name)) {
                                    current_opt = opt_fld;
                                    break;
                                }
                            }
                        } else {
                            // short option
                            const short_name = arg[1..];
                            if (short_name.len != 1) {
                                std.log.warn("No such short option, name:{s}", .{arg});
                                return error.NoOption;
                            }
                            for (self.opt_fields) |*opt| {
                                if (opt.short_name) |name| {
                                    if (name == short_name[0]) {
                                        current_opt = opt;
                                        break;
                                    }
                                }
                            }
                        }

                        var opt = current_opt orelse {
                            std.log.warn("Current option is null, option_name:{s}", .{arg});
                            return error.NoOption;
                        };

                        if (opt.opt_type == .Bool or opt.opt_type == .RequiredBool) {
                            state = .waitBoolValue;
                        } else {
                            state = .waitValue;
                        }
                    },
                    .args => {
                        try result.positional_args.append(arg);
                    },
                    .waitBoolValue => {
                        var opt = current_opt.?;
                        // meet next option name, set current option value to true directly
                        if (std.mem.startsWith(u8, arg, "-")) {
                            // push back current arg
                            arg_idx -= 1;
                            opt.is_set = try Self.setOptionValue(&result.args, opt.long_name, "true");
                        } else {
                            opt.is_set = try Self.setOptionValue(&result.args, opt.long_name, arg);
                        }
                        // reset to initial status
                        state = .start;
                        current_opt = null;
                    },
                    .waitValue => {
                        var opt = current_opt.?;
                        opt.is_set = try Self.setOptionValue(&result.args, opt.long_name, arg);
                        // reset to initial status
                        state = .start;
                        current_opt = null;
                    },
                }
            }

            switch (state) {
                // normal exit state
                .start, .args => {},
                .waitBoolValue => {
                    var opt = current_opt.?;
                    opt.is_set = try Self.setOptionValue(&result.args, opt.long_name, "true");
                },
                .waitValue => return error.MissingOptionValue,
            }

            inline for (self.opt_fields) |opt| {
                if (opt.opt_type.is_required()) {
                    if (!opt.is_set) {
                        std.log.warn("Missing required option, name:{s}", .{opt.long_name});
                        return error.MissingRequiredOption;
                    }
                }
            }
            return result;
        }

        fn getSignedness(comptime opt_type: type) std.builtin.Signedness {
            return switch (@typeInfo(opt_type)) {
                .Int => |i| i.signedness,
                .Optional => |o| Self.getSignedness(o.child),
                else => @compileError("not int type, have no signedness"),
            };
        }

        fn getRealType(comptime opt_type: type) type {
            return switch (@typeInfo(opt_type)) {
                .Optional => |o| Self.getRealType(o.child),
                else => opt_type,
            };
        }

        // return true when set successfully
        fn setOptionValue(opt: *T, long_name: []const u8, raw_value: []const u8) !bool {
            inline for (std.meta.fields(T)) |field| {
                if (std.mem.eql(u8, field.name, long_name)) {
                    @field(opt, field.name) =
                        switch (comptime OptionType.from_zig_type(field.field_type)) {
                        .Int, .RequiredInt => blk: {
                            const real_type = comptime Self.getRealType(field.field_type);
                            break :blk switch (Self.getSignedness(field.field_type)) {
                                .signed => try std.fmt.parseInt(real_type, raw_value, 0),
                                .unsigned => try std.fmt.parseUnsigned(real_type, raw_value, 0),
                            };
                        },
                        .Float, .RequiredFloat => try std.fmt.parseFloat(comptime Self.getRealType(field.field_type), raw_value),
                        .String, .RequiredString => raw_value,
                        .Bool, .RequiredBool => std.mem.eql(u8, raw_value, "true") or std.mem.eql(u8, raw_value, "1"),
                    };

                    return true;
                }
            }

            return false;
        }
    };
}

const TestArguments = struct {
    help: bool,
    rate: ?f32,
    timeout: u16,
    @"user-agent": ?[]const u8,

    pub const __shorts__ = .{
        .help = .h,
        .rate = .r,
    };

    pub const __messages__ = .{ .help = "print this help message" };
};

test "parse/valid option values" {
    const allocator = std.testing.allocator;
    var args = [_][:0]u8{
        try allocator.dupeZ(u8, "awesome-cli"),
        try allocator.dupeZ(u8, "--help"),
        try allocator.dupeZ(u8, "--rate"),
        try allocator.dupeZ(u8, "1.2"),
        try allocator.dupeZ(u8, "--timeout"),
        try allocator.dupeZ(u8, "30"),
        try allocator.dupeZ(u8, "--user-agent"),
        try allocator.dupeZ(u8, "firefox"),
        // positional args
        try allocator.dupeZ(u8, "hello"),
        try allocator.dupeZ(u8, "world"),
    };
    defer for (args) |arg| {
        allocator.free(arg);
    };

    var parser = OptionParser(TestArguments).init(allocator, &args);
    const opt = try parser.parse();
    defer opt.deinit();

    try std.testing.expectEqual(true, opt.args.help);
    try std.testing.expectEqual(opt.args.rate.?, 1.2);
    try std.testing.expectEqual(opt.args.timeout, 30);
    try std.testing.expectEqualStrings("firefox", opt.args.@"user-agent".?);
    try std.testing.expectEqualStrings("hello", opt.positional_args.items[0]);
    try std.testing.expectEqualStrings("world", opt.positional_args.items[1]);

    var help_msg = std.ArrayList(u8).init(allocator);
    defer help_msg.deinit();

    try opt.print_help(help_msg.writer());
    try std.testing.expectEqualStrings(
        \\ USAGE:
        \\     awesome-cli [OPTIONS] ...
        \\
        \\ OPTIONS:
        \\	-h, --help               print this help message [type: bool][REQUIRED]
        \\	-r, --rate               [type: float]
        \\	    --timeout            [type: integer][REQUIRED]
        \\	    --user-agent         [type: string]
        \\
    , help_msg.items);
}

test "parse/missing required arguments" {
    const allocator = std.testing.allocator;
    var args = [_][:0]u8{
        try allocator.dupeZ(u8, "abc"),
        try allocator.dupeZ(u8, "def"),
    };
    defer for (args) |arg| {
        allocator.free(arg);
    };
    var parser = OptionParser(TestArguments).init(allocator, &args);

    try std.testing.expectError(error.MissingRequiredOption, parser.parse());
}

test "parse/invalid u16 values" {
    const allocator = std.testing.allocator;
    var args = [_][:0]u8{
        try allocator.dupeZ(u8, "awesome-cli"),
        try allocator.dupeZ(u8, "--timeout"),
        try allocator.dupeZ(u8, "not-a-number"),
        try allocator.dupeZ(u8, "--help"),
    };
    defer for (args) |arg| {
        allocator.free(arg);
    };
    var parser = OptionParser(TestArguments).init(allocator, &args);

    try std.testing.expectError(error.InvalidCharacter, parser.parse());
}

test "parse/invalid f32 values" {
    const allocator = std.testing.allocator;
    var args = [_][:0]u8{
        try allocator.dupeZ(u8, "awesome-cli"),
        try allocator.dupeZ(u8, "--rate"),
        try allocator.dupeZ(u8, "not-a-number"),
        try allocator.dupeZ(u8, "--help"),
    };
    defer for (args) |arg| {
        allocator.free(arg);
    };
    var parser = OptionParser(TestArguments).init(allocator, &args);

    try std.testing.expectError(error.InvalidCharacter, parser.parse());
}

test "parse/unknown option" {
    const allocator = std.testing.allocator;
    var args = [_][:0]u8{
        try allocator.dupeZ(u8, "awesome-cli"),
        try allocator.dupeZ(u8, "-h"),
        try allocator.dupeZ(u8, "--timeout"),
        try allocator.dupeZ(u8, "1"),
        try allocator.dupeZ(u8, "--notexists"),
    };
    defer for (args) |arg| {
        allocator.free(arg);
    };
    var parser = OptionParser(TestArguments).init(allocator, &args);

    try std.testing.expectError(error.NoOption, parser.parse());
}

test "parse/missing option value" {
    const allocator = std.testing.allocator;
    var args = [_][:0]u8{
        try allocator.dupeZ(u8, "awesome-cli"),
        try allocator.dupeZ(u8, "-h"),
        try allocator.dupeZ(u8, "--timeout"),
    };
    defer for (args) |arg| {
        allocator.free(arg);
    };
    var parser = OptionParser(TestArguments).init(allocator, &args);

    try std.testing.expectError(error.MissingOptionValue, parser.parse());
}

test "parse/default value" {
    const allocator = std.testing.allocator;
    var args = [_][:0]u8{
        try allocator.dupeZ(u8, "awesome-cli"),
    };
    defer for (args) |arg| {
        allocator.free(arg);
    };
    var parser = OptionParser(struct {
        a1: []const u8 = "A1",
        a2: ?[]const u8 = "A2",
        b1: u8 = 1,
        b2: ?u8 = 11,
        c1: f16 = 1.5,
        c2: ?f16 = 2.5,
        d1: bool = true,
        d2: ?bool = false,
    }).init(allocator, &args);
    const opt = try parser.parse();
    try std.testing.expectEqualStrings("A1", opt.args.a1);
    try std.testing.expectEqual(opt.positional_args.items.len, 0);
    var help_msg = std.ArrayList(u8).init(allocator);
    defer help_msg.deinit();
    try opt.print_help(help_msg.writer());
    try std.testing.expectEqualStrings(
        \\ USAGE:
        \\     awesome-cli [OPTIONS] ...
        \\
        \\ OPTIONS:
        \\	    --a1                 [default:A1][type: string][REQUIRED]
        \\	    --a2                 [default:A2][type: string]
        \\	    --b1                 [default:1][type: integer][REQUIRED]
        \\	    --b2                 [default:11][type: integer]
        \\	    --c1                 [default:1.5e+00][type: float][REQUIRED]
        \\	    --c2                 [default:2.5e+00][type: float]
        \\	    --d1                 [default:true][type: bool][REQUIRED]
        \\	    --d2                 [default:false][type: bool]
        \\
    , help_msg.items);
}
