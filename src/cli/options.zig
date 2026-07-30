const std = @import("std");
const source_mod = @import("../model/source_info.zig");

pub const Command = enum {
    help,
    version,
    detect,
    inspect,
    normalize,
    validate,
    query,
    aggregate,
    correlate,
    export_records,
    diagnose,

    pub fn label(self: Command) []const u8 {
        return switch (self) {
            .help => "help",
            .version => "version",
            .detect => "detect",
            .inspect => "inspect",
            .normalize => "normalize",
            .validate => "validate",
            .query => "query",
            .aggregate => "aggregate",
            .correlate => "correlate",
            .export_records => "export",
            .diagnose => "diagnose",
        };
    }
};

pub const ExportFormat = enum { json, jsonl, csv, text };
pub const ReportFormat = enum { text, json };

pub const Options = struct {
    command: Command = .help,
    inputs: [32][]const u8 = undefined,
    input_count: usize = 0,
    format: source_mod.SourceFormat = .unknown,
    output_path: ?[]const u8 = null,
    expression: ?[]const u8 = null,
    schema_name: []const u8 = "service-event",
    export_format: ExportFormat = .jsonl,
    report_format: ReportFormat = .text,
    columns: ?[]const u8 = null,
    numeric_field: ?[]const u8 = null,
    bucket_seconds: ?u64 = null,
    correlation_field: ?[]const u8 = null,
    correlation_window_seconds: u64 = 300,
    correlation_score: u8 = 60,
    explicit_stdin: bool = false,
    pretty: bool = false,
    strict: bool = false,
    deduplicate: bool = false,
    no_header: bool = false,
    continue_after_error: bool = true,
    case_insensitive: bool = false,
    max_input_bytes: usize = 64 * 1024 * 1024,
    max_line_bytes: usize = 1024 * 1024,

    pub fn addInput(self: *Options, input: []const u8) ParseError!void {
        if (self.input_count >= self.inputs.len) return error.TooManyInputs;
        if (std.mem.eql(u8, input, "-")) self.explicit_stdin = true else {
            self.inputs[self.input_count] = input;
            self.input_count += 1;
        }
    }

    pub fn inputSlice(self: *const Options) []const []const u8 {
        return self.inputs[0..self.input_count];
    }
};

pub const ParseError = error{
    MissingCommand,
    UnknownCommand,
    UnknownOption,
    MissingOptionValue,
    InvalidFormat,
    InvalidExportFormat,
    InvalidReportFormat,
    InvalidNumber,
    NumberOutOfRange,
    TooManyInputs,
    ConflictingInput,
    MissingExpression,
};

pub fn parse(arguments: []const []const u8) ParseError!Options {
    var options = Options{};
    if (arguments.len == 0) return options;
    var index: usize = 0;
    if (std.mem.eql(u8, arguments[0], "--help") or std.mem.eql(u8, arguments[0], "-h")) return options;
    if (std.mem.eql(u8, arguments[0], "--version") or std.mem.eql(u8, arguments[0], "version")) {
        options.command = .version;
        return options;
    }
    options.command = commandFromText(arguments[0]) orelse return error.UnknownCommand;
    index = 1;
    while (index < arguments.len) : (index += 1) {
        const argument = arguments[index];
        if (!std.mem.startsWith(u8, argument, "-")) {
            try options.addInput(argument);
            continue;
        }
        if (std.mem.eql(u8, argument, "-")) {
            try options.addInput(argument);
            continue;
        }
        if (std.mem.eql(u8, argument, "--help") or std.mem.eql(u8, argument, "-h")) {
            options.command = .help;
            continue;
        }
        if (std.mem.eql(u8, argument, "--pretty")) {
            options.pretty = true;
            continue;
        }
        if (std.mem.eql(u8, argument, "--strict")) {
            options.strict = true;
            options.continue_after_error = false;
            continue;
        }
        if (std.mem.eql(u8, argument, "--deduplicate")) {
            options.deduplicate = true;
            continue;
        }
        if (std.mem.eql(u8, argument, "--no-header")) {
            options.no_header = true;
            continue;
        }
        if (std.mem.eql(u8, argument, "--case-insensitive")) {
            options.case_insensitive = true;
            continue;
        }
        if (std.mem.eql(u8, argument, "--stdin")) {
            options.explicit_stdin = true;
            continue;
        }
        if (std.mem.eql(u8, argument, "--format") or std.mem.eql(u8, argument, "-f")) {
            const value = try nextValue(arguments, &index);
            options.format = source_mod.SourceFormat.fromLabel(value) orelse return error.InvalidFormat;
            continue;
        }
        if (std.mem.eql(u8, argument, "--output") or std.mem.eql(u8, argument, "-o")) {
            options.output_path = try nextValue(arguments, &index);
            continue;
        }
        if (std.mem.eql(u8, argument, "--where") or std.mem.eql(u8, argument, "-q")) {
            options.expression = try nextValue(arguments, &index);
            continue;
        }
        if (std.mem.eql(u8, argument, "--schema")) {
            options.schema_name = try nextValue(arguments, &index);
            continue;
        }
        if (std.mem.eql(u8, argument, "--to")) {
            options.export_format = parseExportFormat(try nextValue(arguments, &index)) orelse return error.InvalidExportFormat;
            continue;
        }
        if (std.mem.eql(u8, argument, "--report-format")) {
            options.report_format = parseReportFormat(try nextValue(arguments, &index)) orelse return error.InvalidReportFormat;
            continue;
        }
        if (std.mem.eql(u8, argument, "--columns")) {
            options.columns = try nextValue(arguments, &index);
            continue;
        }
        if (std.mem.eql(u8, argument, "--field")) {
            options.numeric_field = try nextValue(arguments, &index);
            continue;
        }
        if (std.mem.eql(u8, argument, "--bucket-seconds")) {
            options.bucket_seconds = try parseUnsigned(u64, try nextValue(arguments, &index));
            continue;
        }
        if (std.mem.eql(u8, argument, "--correlation-field")) {
            options.correlation_field = try nextValue(arguments, &index);
            continue;
        }
        if (std.mem.eql(u8, argument, "--window-seconds")) {
            options.correlation_window_seconds = try parseUnsigned(u64, try nextValue(arguments, &index));
            continue;
        }
        if (std.mem.eql(u8, argument, "--score")) {
            const score = try parseUnsigned(u16, try nextValue(arguments, &index));
            if (score > 100) return error.NumberOutOfRange;
            options.correlation_score = @intCast(score);
            continue;
        }
        if (std.mem.eql(u8, argument, "--max-input-bytes")) {
            options.max_input_bytes = try parseUnsigned(usize, try nextValue(arguments, &index));
            continue;
        }
        if (std.mem.eql(u8, argument, "--max-line-bytes")) {
            options.max_line_bytes = try parseUnsigned(usize, try nextValue(arguments, &index));
            continue;
        }
        return error.UnknownOption;
    }
    try validate(&options);
    return options;
}

fn validate(options: *const Options) ParseError!void {
    if (options.explicit_stdin and options.input_count != 0) return error.ConflictingInput;
    if (options.command == .query and options.expression == null) return error.MissingExpression;
    if (options.max_input_bytes == 0 or options.max_line_bytes == 0) return error.NumberOutOfRange;
    if (options.correlation_window_seconds > std.math.maxInt(i64)) return error.NumberOutOfRange;
}

fn nextValue(arguments: []const []const u8, index: *usize) ParseError![]const u8 {
    index.* += 1;
    if (index.* >= arguments.len) return error.MissingOptionValue;
    return arguments[index.*];
}

fn parseUnsigned(comptime T: type, input: []const u8) ParseError!T {
    return std.fmt.parseUnsigned(T, input, 10) catch return error.InvalidNumber;
}

pub fn commandFromText(input: []const u8) ?Command {
    if (std.ascii.eqlIgnoreCase(input, "help")) return .help;
    if (std.ascii.eqlIgnoreCase(input, "detect")) return .detect;
    if (std.ascii.eqlIgnoreCase(input, "inspect")) return .inspect;
    if (std.ascii.eqlIgnoreCase(input, "normalize")) return .normalize;
    if (std.ascii.eqlIgnoreCase(input, "validate")) return .validate;
    if (std.ascii.eqlIgnoreCase(input, "query")) return .query;
    if (std.ascii.eqlIgnoreCase(input, "aggregate")) return .aggregate;
    if (std.ascii.eqlIgnoreCase(input, "correlate")) return .correlate;
    if (std.ascii.eqlIgnoreCase(input, "export")) return .export_records;
    if (std.ascii.eqlIgnoreCase(input, "diagnose")) return .diagnose;
    return null;
}

fn parseExportFormat(input: []const u8) ?ExportFormat {
    if (std.ascii.eqlIgnoreCase(input, "json")) return .json;
    if (std.ascii.eqlIgnoreCase(input, "jsonl") or std.ascii.eqlIgnoreCase(input, "ndjson")) return .jsonl;
    if (std.ascii.eqlIgnoreCase(input, "csv")) return .csv;
    if (std.ascii.eqlIgnoreCase(input, "text") or std.ascii.eqlIgnoreCase(input, "table")) return .text;
    return null;
}

fn parseReportFormat(input: []const u8) ?ReportFormat {
    if (std.ascii.eqlIgnoreCase(input, "text")) return .text;
    if (std.ascii.eqlIgnoreCase(input, "json")) return .json;
    return null;
}

test "CLI options parse query expressions and explicit format" {
    const args = [_][]const u8{ "query", "--format", "jsonl", "--where", "severity >= warning", "events.jsonl" };
    const options = try parse(&args);
    try std.testing.expectEqual(Command.query, options.command);
    try std.testing.expectEqual(source_mod.SourceFormat.jsonl, options.format);
    try std.testing.expectEqualStrings("severity >= warning", options.expression.?);
}

test "CLI rejects stdin mixed with paths" {
    const args = [_][]const u8{ "inspect", "--stdin", "events.jsonl" };
    try std.testing.expectError(error.ConflictingInput, parse(&args));
}
