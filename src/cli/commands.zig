const std = @import("std");
const options_mod = @import("options.zig");
const source_mod = @import("../model/source_info.zig");
const record_mod = @import("../model/record.zig");
const detector = @import("../input/detector.zig");
const file_loader = @import("../input/file_loader.zig");
const stream = @import("../input/stream_reader.zig");
const session_mod = @import("../workflow/session.zig");
const reporting = @import("../workflow/reporting.zig");
const projection = @import("../processing/projection.zig");
const query_parser = @import("../processing/query_parser.zig");
const query_eval = @import("../processing/query_eval.zig");
const aggregation = @import("../processing/aggregation.zig");
const route_metrics = @import("../processing/route_metrics.zig");
const correlation = @import("../processing/correlation.zig");
const duplicate = @import("../processing/duplicate.zig");
const schema_mod = @import("../validation/schema.zig");
const validation = @import("../validation/rules.zig");
const validation_report = @import("../validation/report.zig");
const json_export = @import("../export/json.zig");
const csv_export = @import("../export/csv.zig");
const text_export = @import("../export/text.zig");

pub const ExitCode = enum(u8) {
    success = 0,
    usage = 2,
    input_error = 3,
    validation_failed = 4,
    no_matches = 5,
    internal_error = 70,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    stdout: std.fs.File.Writer,
    stderr: std.fs.File.Writer,
};

pub fn execute(context: Context, options: options_mod.Options) !ExitCode {
    return switch (options.command) {
        .help => printHelp(context.stdout),
        .version => printVersion(context.stdout),
        .detect => detectCommand(context, options),
        .inspect => recordsCommand(context, options, .inspect),
        .normalize => recordsCommand(context, options, .normalize),
        .query => recordsCommand(context, options, .query),
        .export_records => recordsCommand(context, options, .export_records),
        .validate => validateCommand(context, options),
        .aggregate => aggregateCommand(context, options),
        .correlate => correlateCommand(context, options),
        .diagnose => diagnoseCommand(context, options),
    };
}

const RecordMode = enum { inspect, normalize, query, export_records };

fn printVersion(writer: anytype) !ExitCode {
    try writer.writeAll("opsmosaic 0.1.0 (Zig 0.13.0)\n");
    return .success;
}

fn printHelp(writer: anytype) !ExitCode {
    try writer.writeAll(
        \\OpsMosaic — offline operational-data ingestion and analysis
        \\
        \\Usage: opsmosaic <command> [options] [files...]
        \\
        \\Commands:
        \\  detect      identify an input format with confidence and evidence
        \\  inspect     parse and display concise normalized records
        \\  normalize   parse, normalize, and emit JSON Lines
        \\  validate    apply a built-in schema and report findings
        \\  query       filter normalized records with the query language
        \\  aggregate   summarize severities, services, formats, tags, and HTTP status
        \\  correlate   group records using deterministic operational identifiers
        \\  export      write JSON, JSON Lines, CSV, or text projections
        \\  diagnose    report parser recovery, warnings, quality, and coverage
        \\
        \\Common options:
        \\  -f, --format <auto|syslog|rfc5424|jsonl|csv|ini|access-log|dns-zone|env|manifest>
        \\  -o, --output <path>       write data output to a file
        \\  --stdin                   read standard input instead of files
        \\  --strict                  stop on the first malformed record
        \\  --deduplicate             suppress semantic duplicates
        \\  --max-input-bytes <n>     bound total bytes read from one input
        \\  --max-line-bytes <n>      bound one line-oriented record
        \\
        \\Command options:
        \\  query --where <expression> [--case-insensitive]
        \\  validate --schema <service-event|http-event|inventory|deployment>
        \\  export --to <json|jsonl|csv|text> [--columns <list>] [--pretty]
        \\  aggregate [--field <numeric-field>] [--bucket-seconds <n>]
        \\  correlate [--correlation-field <name>] [--window-seconds <n>] [--score <0-100>]
        \\  diagnose [--report-format <text|json>]
        \\
        \\Use '-' as the sole input path to read standard input.
        \\
    );
    return .success;
}

fn detectCommand(context: Context, options: options_mod.Options) !ExitCode {
    if (options.input_count == 0 and !options.explicit_stdin) {
        try context.stderr.writeAll("opsmosaic: detect requires a file or --stdin\n");
        return .usage;
    }
    if (options.explicit_stdin) {
        var input = file_loader.loadStdin(context.allocator, limitsFrom(options)) catch |err| {
            try writeInputError(context.stderr, "<stdin>", err);
            return .input_error;
        };
        defer input.deinit();
        try writeDetection(context.stdout, null, input.bytes);
        return .success;
    }
    var had_error = false;
    for (options.inputSlice()) |path| {
        var input = file_loader.loadPath(context.allocator, path, limitsFrom(options)) catch |err| {
            had_error = true;
            try writeInputError(context.stderr, path, err);
            continue;
        };
        defer input.deinit();
        try writeDetection(context.stdout, path, input.bytes);
    }
    return if (had_error) .input_error else .success;
}

fn writeDetection(writer: anytype, path: ?[]const u8, input: []const u8) !void {
    const decision = detector.detect(path, input);
    try writer.print("{s}\t{s}\tconfidence={d}\treason={s}\n", .{
        path orelse "<stdin>", decision.format.label(), decision.confidence, decision.reason,
    });
}

fn recordsCommand(context: Context, options: options_mod.Options, mode: RecordMode) !ExitCode {
    var session = session_mod.Session.init(context.allocator);
    defer session.deinit();
    const loaded = try loadSession(&session, context, options);
    if (loaded != .success) return loaded;
    if (options.deduplicate) _ = session.removeDuplicates();
    const records = try session.borrowedView(context.allocator);
    defer context.allocator.free(records);

    var selected_count: usize = records.len;
    var selected_owned: ?[]record_mod.Record = null;
    defer if (selected_owned) |slice| context.allocator.free(slice);
    var output_records = records;
    if (mode == .query) {
        const program = query_parser.parse(options.expression.?, .{}) catch |err| {
            try context.stderr.print("opsmosaic: invalid query: {s}\n", .{@errorName(err)});
            return .usage;
        };
        const selected_indices = try context.allocator.alloc(usize, records.len);
        defer context.allocator.free(selected_indices);
        selected_count = try query_eval.filterIndices(&program, records, .{ .case_insensitive_text = options.case_insensitive }, selected_indices);
        const copy = try context.allocator.alloc(record_mod.Record, selected_count);
        for (selected_indices[0..selected_count], 0..) |record_index, index| copy[index] = records[record_index];
        selected_owned = copy;
        output_records = copy;
    }

    if (options.output_path) |path| {
        var file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch |err| {
            try writeInputError(context.stderr, path, err);
            return .input_error;
        };
        defer file.close();
        try writeRecords(file.writer(), output_records, options, mode);
    } else try writeRecords(context.stdout, output_records, options, mode);
    if (mode == .query and selected_count == 0) return .no_matches;
    return .success;
}

fn writeRecords(writer: anytype, records: []const record_mod.Record, options: options_mod.Options, mode: RecordMode) !void {
    if (mode == .inspect) {
        var selected = if (options.columns) |spec| try projection.parse(spec) else projection.defaultOperational();
        for (records) |*record| try projection.writeTextRow(record, &selected, writer);
        return;
    }
    if (mode == .normalize or mode == .query) {
        try json_export.writeJsonLines(records, writer, .{ .pretty = false });
        return;
    }
    switch (options.export_format) {
        .json => try json_export.writeArray(records, writer, .{ .pretty = options.pretty }),
        .jsonl => try json_export.writeJsonLines(records, writer, .{ .pretty = false }),
        .text => {
            var selected = if (options.columns) |spec| try projection.parse(spec) else projection.defaultOperational();
            for (records) |*record| try projection.writeTextRow(record, &selected, writer);
        },
        .csv => {
            var columns_storage: [64][]const u8 = undefined;
            const columns = if (options.columns) |specification| blk: {
                const count = csv_export.parseColumns(specification, &columns_storage);
                if (!csv_export.validateColumns(columns_storage[0..count])) return error.InvalidColumns;
                break :blk columns_storage[0..count];
            } else csv_export.default_columns[0..];
            try csv_export.write(records, writer, columns, .{ .include_header = !options.no_header });
        },
    }
}

fn validateCommand(context: Context, options: options_mod.Options) !ExitCode {
    const schema = schema_mod.builtIn(options.schema_name) orelse {
        try context.stderr.print("opsmosaic: unknown schema '{s}'\n", .{options.schema_name});
        return .usage;
    };
    var session = session_mod.Session.init(context.allocator);
    defer session.deinit();
    const loaded = try loadSession(&session, context, options);
    if (loaded != .success) return loaded;
    const records = try session.borrowedView(context.allocator);
    defer context.allocator.free(records);
    var summary = validation_report.Summary{};
    for (records) |*record| {
        const findings = validation.validate(record, schema, .{
            .unknown_fields_are_errors = options.strict,
            .require_normalized_timestamp = options.strict,
        });
        summary.observe(&findings);
        if (findings.count != 0) {
            try context.stdout.print("{s}:{d}\n", .{ record.source.displayName(), record.source.line });
            try validation_report.writeFindingsText(&findings, context.stdout);
        }
    }
    try summary.writeText(context.stdout);
    try context.stdout.writeByte('\n');
    return if (summary.errors != 0) .validation_failed else .success;
}

fn aggregateCommand(context: Context, options: options_mod.Options) !ExitCode {
    var session = session_mod.Session.init(context.allocator);
    defer session.deinit();
    const loaded = try loadSession(&session, context, options);
    if (loaded != .success) return loaded;
    const records = try session.borrowedView(context.allocator);
    defer context.allocator.free(records);
    const report = aggregation.summarize(records);
    try context.stdout.print("records={d}\n", .{report.record_count});
    try writeCountTable(context.stdout, "severity", &report.by_severity);
    try writeCountTable(context.stdout, "service", &report.by_service);
    try writeCountTable(context.stdout, "format", &report.by_format);
    try writeCountTable(context.stdout, "tag", &report.by_tag);
    try context.stdout.print("http_2xx={d} http_4xx={d} http_5xx={d} error_rate={d:.6}\n", .{
        report.status.success, report.status.client_error, report.status.server_error, report.status.errorRate(),
    });
    const routes = route_metrics.summarize(records);
    if (routes.count != 0 or routes.records_without_route != 0) try route_metrics.writeText(&routes, context.stdout);
    if (options.numeric_field) |field| {
        const numeric = aggregation.numeric(records, field);
        try context.stdout.print("field={s} count={d} missing={d} incompatible={d} sum={d}", .{
            field, numeric.count, numeric.missing, numeric.incompatible, numeric.sum,
        });
        if (numeric.minimum) |minimum| try context.stdout.print(" min={d}", .{minimum});
        if (numeric.maximum) |maximum| try context.stdout.print(" max={d}", .{maximum});
        if (numeric.average()) |average| try context.stdout.print(" avg={d}", .{average});
        try context.stdout.writeByte('\n');
    }
    if (options.bucket_seconds) |seconds| {
        if (seconds == 0) {
            try context.stderr.writeAll("opsmosaic: --bucket-seconds must be positive\n");
            return .usage;
        }
        const width: i128 = @as(i128, @intCast(seconds)) * std.time.ns_per_s;
        const buckets = aggregation.timeBuckets(records, width);
        for (buckets.buckets[0..buckets.count]) |bucket| try context.stdout.print("bucket_start_ns={d} count={d}\n", .{ bucket.start_ns, bucket.count });
        if (buckets.missing != 0) try context.stdout.print("bucket_missing={d}\n", .{buckets.missing});
    }
    return .success;
}

fn correlateCommand(context: Context, options: options_mod.Options) !ExitCode {
    var session = session_mod.Session.init(context.allocator);
    defer session.deinit();
    const loaded = try loadSession(&session, context, options);
    if (loaded != .success) return loaded;
    const records = try session.borrowedView(context.allocator);
    defer context.allocator.free(records);
    const groups = correlation.group(records, .{
        .time_window_ns = @as(i128, @intCast(options.correlation_window_seconds)) * std.time.ns_per_s,
        .required_score = options.correlation_score,
        .configured_field = options.correlation_field,
    });
    try context.stdout.print("groups={d} ungrouped={d} truncated={d}\n", .{ groups.count, groups.ungrouped, groups.truncated });
    for (groups.slice(), 0..) |group, group_index| {
        try context.stdout.print("group {d}:\n", .{group_index + 1});
        for (group.slice()) |record_index| {
            const record = &records[record_index];
            try context.stdout.print("  {s}:{d} format={s} service={s} event={s} request={s} trace={s}\n", .{
                record.source.displayName(), record.source.line, record.source.format.label(),
                record.service orelse "-", record.event_id orelse "-", record.request_id orelse "-", record.trace_id orelse "-",
            });
        }
    }
    return .success;
}

fn diagnoseCommand(context: Context, options: options_mod.Options) !ExitCode {
    var session = session_mod.Session.init(context.allocator);
    defer session.deinit();
    const loaded = try loadSession(&session, context, options);
    if (loaded != .success and session.recordCount() == 0) return loaded;
    const records = try session.borrowedView(context.allocator);
    defer context.allocator.free(records);
    var report = reporting.build(records);
    report.ingestion_inputs = session.stats.inputs;
    report.ingestion_bytes = session.stats.bytes;
    report.ingestion_failures = session.stats.failed;
    switch (options.report_format) {
        .text => try reporting.writeText(report, context.stdout),
        .json => {
            try reporting.writeJson(report, context.stdout);
            try context.stdout.writeByte('\n');
        },
    }
    return if (report.hasOperationalErrors()) .validation_failed else .success;
}

fn loadSession(session: *session_mod.Session, context: Context, options: options_mod.Options) !ExitCode {
    const ingest_options = session_mod.IngestOptions{
        .format = options.format,
        .stream_limits = limitsFrom(options),
        .continue_after_error = options.continue_after_error,
        .deduplicate = options.deduplicate,
    };
    if (options.explicit_stdin or options.input_count == 0) {
        session.ingestStdin(ingest_options) catch |err| {
            try writeInputError(context.stderr, "<stdin>", err);
            return .input_error;
        };
        return .success;
    }
    var had_error = false;
    for (options.inputSlice()) |path| {
        session.ingestPath(path, ingest_options) catch |err| {
            had_error = true;
            try writeInputError(context.stderr, path, err);
            if (!options.continue_after_error) return .input_error;
        };
    }
    if (session.recordCount() == 0 and had_error) return .input_error;
    return .success;
}

fn limitsFrom(options: options_mod.Options) stream.StreamLimits {
    return .{ .max_input_bytes = options.max_input_bytes, .max_line_bytes = options.max_line_bytes };
}

fn writeCountTable(writer: anytype, name: []const u8, table: *const aggregation.CountTable) !void {
    for (table.slice()) |entry| try writer.print("{s}[{s}]={d}\n", .{ name, entry.key, entry.count });
    if (table.overflow != 0) try writer.print("{s}[<overflow>]={d}\n", .{ name, table.overflow });
}

fn writeInputError(writer: anytype, name: []const u8, err: anyerror) !void {
    try writer.print("opsmosaic: {s}: {s}\n", .{ name, @errorName(err) });
}

test "help text is available through the command implementation" {
    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();
    const code = try printHelp(buffer.writer());
    try std.testing.expectEqual(ExitCode.success, code);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "aggregate") != null);
}

test "duplicate module is linked through CLI command graph" {
    var a = @import("../model/record.zig").Record.init(.jsonl);
    var b = @import("../model/record.zig").Record.init(.jsonl);
    a.message = "same";
    b.message = "same";
    try std.testing.expect(duplicate.equivalent(&a, &b, .{}));
    _ = source_mod.SourceFormat.jsonl;
    _ = text_export;
}
