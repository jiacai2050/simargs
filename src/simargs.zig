//! A simple, opinionated, struct-based argument parser in Zig

const std = @import("std");
const testing = std.testing;

const ParseError = error{ NoProgram, NoLongOption, ExpectedOption, NoShortOption, MissingRequiredOption };

const OptionError = ParseError || std.mem.Allocator.Error || std.fmt.ParseIntError || std.fmt.ParseFloatError;

pub fn parse(
    allocator: std.mem.Allocator,
    comptime T: type,
) !StructArguments(T) {
    var parser = OptionParser(T).init(allocator, comptime parseOptionFields(T));
    return parser.parse();
}

fn parseOptionFields(comptime T: type) [std.meta.fields(T).len]OptionField {
    const option_type_info = @typeInfo(T);
    if (option_type_info != .Struct) {
        @compileError("option should be defined using struct, found " ++ @typeName(T));
    }

    var opt_fields: [std.meta.fields(T).len]OptionField = undefined;
    inline for (option_type_info.Struct.fields) |fld, idx| {
        const long_name = fld.name;
        const opt_type = OptionType.from_zig_type(fld.field_type, false);
        opt_fields[idx] = .{
            .long_name = long_name,
            .opt_type = opt_type,
            .is_set = false,
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

fn StructArguments(comptime T: type) type {
    return struct {
        program: []const u8,
        args: T,
        positional_args: std.ArrayList([]const u8),
        allocator: std.mem.Allocator,

        pub fn deinit(self: @This()) void {
            self.allocator.free(self.program);
            self.positional_args.deinit();
        }

        pub fn print_help(
            self: @This(),
        ) !void {
            const fields = comptime parseOptionFields(T);
            var stdout = std.io.getStdOut();
            var w = stdout.writer();
            var buf = std.ArrayList([]const u8).init(self.allocator);
            defer buf.deinit();

            const header_tmpl =
                \\ USAGE:
                \\     {s} [OPTIONS] ...
                \\
                \\ OPTIONS:
            ;
            const header = try std.fmt.allocPrint(self.allocator, header_tmpl, .{
                self.program,
            });
            try buf.append(header);
            // TODO: Maybe be too small(or big)?
            const msg_offset = 25;
            for (fields) |fld| {
                var line_buf = std.ArrayList([]const u8).init(self.allocator);
                try line_buf.append("\t");
                if (fld.short_name) |sn| {
                    try line_buf.append("-");
                    try line_buf.append(&[_]u8{sn});
                    try line_buf.append(", ");
                } else {
                    try line_buf.append("    ");
                }
                try line_buf.append("--");
                try line_buf.append(fld.long_name);

                var blanks = msg_offset - (4 + 2 + fld.long_name.len);
                while (blanks > 0) {
                    try line_buf.append(" ");
                    blanks -= 1;
                }

                if (fld.message) |msg| {
                    try line_buf.append(msg);
                }
                const line = try std.mem.join(self.allocator, "", line_buf.items);
                try buf.append(line);
            }

            try w.writeAll(try std.mem.join(self.allocator, "\n", buf.items));
        }
    };
}

const OptionType = enum(u32) {
    const REQUIRED_VERSION_SHIFT = 16;

    RequiredInt,
    RequiredBool,
    RequiredFloat,
    RequiredString,

    Int = @This().REQUIRED_VERSION_SHIFT,
    Bool,
    Float,
    String,

    fn from_zig_type(comptime T: type, comptime is_optional: bool) OptionType {
        const base_type: @This() = switch (@typeInfo(T)) {
            .Int => .RequiredInt,
            .Bool => .RequiredBool,
            .Float => .RequiredFloat,
            .Optional => |opt_info| return from_zig_type(opt_info.child, true),
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

    fn is_required(self: @This()) bool {
        return @enumToInt(self) < REQUIRED_VERSION_SHIFT;
    }
};

const OptionField = struct {
    long_name: []const u8,
    short_name: ?u8 = null,
    message: ?[]const u8 = null,
    opt_type: OptionType,
    is_set: bool,
};

fn OptionParser(
    comptime T: type,
) type {
    return struct {
        parsedOptions: [std.meta.fields(T).len]OptionField,
        allocator: std.mem.Allocator,

        const Self = @This();

        // `T` is a struct, which define options
        fn init(allocator: std.mem.Allocator, opt_fields: [std.meta.fields(T).len]OptionField) Self {
            return .{
                .allocator = allocator,
                .parsedOptions = opt_fields,
            };
        }

        // State machine used to parse arguments. Available state transitions:
        // 1. start -> args
        // 2. start -> waitValue -> .. -> waitValue --> args -> ... -> args
        // 3. start

        const ParseState = enum {
            start,
            waitValue,
            args,
        };

        fn parse(self: *Self) OptionError!StructArguments(T) {
            var args_iter = try std.process.argsWithAllocator(self.allocator);
            defer args_iter.deinit();

            var result = StructArguments(T){
                .program = args_iter.next() orelse return error.NoProgram,
                .allocator = self.allocator,
                .args = undefined,
                .positional_args = std.ArrayList([]const u8).init(self.allocator),
            };
            comptime inline for (std.meta.fields(T)) |fld| {
                if (!OptionType.from_zig_type(fld.field_type, false).is_required()) {
                    @field(result.args, fld.name) = null;
                }
            };

            var state = ParseState.start;
            var current_opt: ?*OptionField = null;
            while (args_iter.next()) |arg| {
                std.log.debug("current state is: {s}", .{@tagName(state)});

                switch (state) {
                    .start => {
                        if (!std.mem.startsWith(u8, arg, "-")) {
                            // no option any more, the rest are positional args
                            state = .args;
                            try result.positional_args.append(arg);
                            continue;
                        }

                        if (std.mem.startsWith(u8, arg[1..], "-")) {
                            // long option
                            const long_name = arg[2..];
                            for (self.parsedOptions) |*opt_fld| {
                                if (std.mem.eql(u8, opt_fld.long_name, long_name)) {
                                    current_opt = opt_fld;
                                    break;
                                }
                            }
                        } else {
                            // short option
                            const short_name = arg[1..];
                            if (short_name.len != 1) {
                                std.log.err("No such short option, name:{s}", .{arg});
                                return error.NoShortOption;
                            }
                            for (self.parsedOptions) |*opt| {
                                if (opt.short_name) |name| {
                                    if (name == short_name[0]) {
                                        current_opt = opt;
                                        break;
                                    }
                                }
                            }
                        }

                        var opt = current_opt orelse {
                            std.log.err("Current option is null, option_name:{s}", .{arg});
                            return error.NoLongOption;
                        };

                        if (opt.opt_type == .Bool or opt.opt_type == .RequiredBool) { // no value required, parse next option
                            opt.is_set = true;
                            state = .start;
                        } else {
                            // value required, parse option value
                            state = .waitValue;
                        }
                    },
                    .args => try result.positional_args.append(arg),
                    .waitValue => {
                        var opt = current_opt orelse unreachable;
                        inline for (std.meta.fields(T)) |field| {
                            if (std.mem.eql(u8, field.name, opt.long_name)) {
                                try Self.setOptionValue(&result.args, field.name, OptionType.from_zig_type(field.field_type, false), arg);
                                opt.is_set = true;
                                break;
                            }
                        }
                        state = .start;
                    },
                }
            }

            inline for (self.parsedOptions) |opt| {
                if (opt.opt_type.is_required()) {
                    if (!opt.is_set) {
                        std.log.err("Missing required option, name:{s}", .{opt.long_name});
                        return error.MissingRequiredOption;
                    }
                }
            }
            return result;
        }

        fn setOptionValue(opt: *T, comptime opt_name: []const u8, comptime opt_type: OptionType, raw_value: []const u8) !void {
            @field(opt, opt_name) =
                switch (opt_type) {
                .Int, .RequiredInt => try std.fmt.parseInt(i64, raw_value, 10),
                .Float, .RequiredFloat => try std.fmt.parseFloat(f64, raw_value),
                .String, .RequiredString => raw_value,
                // bool require no parameter
                .Bool, .RequiredBool => unreachable,
            };
        }
    };
}
