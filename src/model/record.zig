const std = @import("std");
const value_mod = @import("value.zig");
const field_mod = @import("field.zig");
const source_mod = @import("source_info.zig");
const diag_mod = @import("../diagnostics/diagnostic.zig");

pub const Value = value_mod.Value;
pub const Field = field_mod.Field;
pub const SourceInfo = source_mod.SourceInfo;
pub const SourceFormat = source_mod.SourceFormat;
pub const Diagnostic = diag_mod.Diagnostic;
pub const DiagnosticBuffer = diag_mod.DiagnosticBuffer;

pub const Severity = enum(u8) {
    trace = 0,
    debug = 1,
    info = 2,
    notice = 3,
    warning = 4,
    @"error" = 5,
    critical = 6,
    alert = 7,
    emergency = 8,
    unknown = 255,

    pub fn label(self: Severity) []const u8 {
        return switch (self) {
            .trace => "trace",
            .debug => "debug",
            .info => "info",
            .notice => "notice",
            .warning => "warning",
            .@"error" => "error",
            .critical => "critical",
            .alert => "alert",
            .emergency => "emergency",
            .unknown => "unknown",
        };
    }

    pub fn rank(self: Severity) u8 {
        return switch (self) {
            .unknown => 0,
            else => @intFromEnum(self),
        };
    }
};

pub const NetworkAttributes = struct {
    source_address: ?[]const u8 = null,
    destination_address: ?[]const u8 = null,
    source_port: ?u16 = null,
    destination_port: ?u16 = null,
    protocol: ?[]const u8 = null,
    method: ?[]const u8 = null,
    path: ?[]const u8 = null,
    status: ?u16 = null,
    bytes: ?u64 = null,
};

pub const Limits = struct {
    max_fields: usize = 64,
    max_tags: usize = 24,
    max_warnings: usize = 64,
    max_line_bytes: usize = 1024 * 1024,
    max_value_bytes: usize = 256 * 1024,
};

pub const Record = struct {
    source: SourceInfo = .{},
    timestamp_unix_ns: ?i128 = null,
    timestamp_text: ?[]const u8 = null,
    severity: Severity = .unknown,
    host: ?[]const u8 = null,
    service: ?[]const u8 = null,
    process_id: ?[]const u8 = null,
    event_id: ?[]const u8 = null,
    request_id: ?[]const u8 = null,
    trace_id: ?[]const u8 = null,
    message: []const u8 = "",
    network: NetworkAttributes = .{},
    fields: [64]Field = undefined,
    field_count: usize = 0,
    tags: [24][]const u8 = undefined,
    tag_count: usize = 0,
    warnings: DiagnosticBuffer = .{},
    recovered: bool = false,

    pub fn init(format: SourceFormat) Record {
        return .{ .source = .{ .format = format } };
    }

    pub fn clear(self: *Record, format: SourceFormat) void {
        self.* = init(format);
    }

    pub fn fieldSlice(self: *const Record) []const Field {
        return self.fields[0..self.field_count];
    }

    pub fn tagSlice(self: *const Record) []const []const u8 {
        return self.tags[0..self.tag_count];
    }

    pub fn addField(self: *Record, key: []const u8, value: Value) error{TooManyFields}!void {
        if (self.field_count == self.fields.len) return error.TooManyFields;
        self.fields[self.field_count] = .{ .key = key, .value = value };
        self.field_count += 1;
    }

    pub fn putField(self: *Record, key: []const u8, value: Value) error{TooManyFields}!void {
        var index: usize = 0;
        while (index < self.field_count) : (index += 1) {
            if (std.mem.eql(u8, self.fields[index].key, key)) {
                self.fields[index].value = value;
                return;
            }
        }
        try self.addField(key, value);
    }

    pub fn getField(self: *const Record, key: []const u8) ?Value {
        if (std.mem.eql(u8, key, "timestamp")) {
            if (self.timestamp_text) |v| return .{ .text = v };
        }
        if (std.mem.eql(u8, key, "severity")) return .{ .text = self.severity.label() };
        if (std.mem.eql(u8, key, "host")) if (self.host) |v| return .{ .text = v };
        if (std.mem.eql(u8, key, "service")) if (self.service) |v| return .{ .text = v };
        if (std.mem.eql(u8, key, "process_id")) if (self.process_id) |v| return .{ .text = v };
        if (std.mem.eql(u8, key, "event_id")) if (self.event_id) |v| return .{ .text = v };
        if (std.mem.eql(u8, key, "request_id")) if (self.request_id) |v| return .{ .text = v };
        if (std.mem.eql(u8, key, "trace_id")) if (self.trace_id) |v| return .{ .text = v };
        if (std.mem.eql(u8, key, "message")) return .{ .text = self.message };
        if (std.mem.eql(u8, key, "source_address")) if (self.network.source_address) |v| return .{ .text = v };
        if (std.mem.eql(u8, key, "destination_address")) if (self.network.destination_address) |v| return .{ .text = v };
        if (std.mem.eql(u8, key, "method")) if (self.network.method) |v| return .{ .text = v };
        if (std.mem.eql(u8, key, "path")) if (self.network.path) |v| return .{ .text = v };
        if (std.mem.eql(u8, key, "status")) if (self.network.status) |v| return .{ .integer = @intCast(v) };
        if (std.mem.eql(u8, key, "bytes")) if (self.network.bytes) |v| {
            if (v <= std.math.maxInt(i64)) return .{ .integer = @intCast(v) };
            return .{ .decimal = @floatFromInt(v) };
        };
        return field_mod.find(self.fieldSlice(), key);
    }

    pub fn hasTag(self: *const Record, tag: []const u8) bool {
        for (self.tagSlice()) |candidate| {
            if (std.mem.eql(u8, candidate, tag)) return true;
        }
        return false;
    }

    pub fn addTag(self: *Record, tag: []const u8) error{TooManyTags}!void {
        if (tag.len == 0 or self.hasTag(tag)) return;
        if (self.tag_count == self.tags.len) return error.TooManyTags;
        self.tags[self.tag_count] = tag;
        self.tag_count += 1;
    }

    pub fn identityHash(self: *const Record) u64 {
        var hasher = std.hash.Wyhash.init(0x4f50534d4f534149);
        hasher.update(self.source.format.label());
        if (self.timestamp_text) |v| hasher.update(v);
        if (self.host) |v| hasher.update(v);
        if (self.service) |v| hasher.update(v);
        if (self.event_id) |v| hasher.update(v);
        hasher.update(self.message);
        for (self.fieldSlice()) |field| {
            hasher.update(field.key);
            const digest = field.value.hash();
            hasher.update(std.mem.asBytes(&digest));
        }
        return hasher.final();
    }

    pub fn semanticEqual(self: *const Record, other: *const Record) bool {
        if (self.severity != other.severity) return false;
        if (!optionalTextEqual(self.host, other.host)) return false;
        if (!optionalTextEqual(self.service, other.service)) return false;
        if (!optionalTextEqual(self.event_id, other.event_id)) return false;
        if (!std.mem.eql(u8, self.message, other.message)) return false;
        if (self.field_count != other.field_count) return false;
        for (self.fieldSlice()) |field| {
            const rhs = other.getField(field.key) orelse return false;
            if (!field.value.eql(rhs)) return false;
        }
        return true;
    }

    pub fn copyCoreFrom(self: *Record, other: *const Record) void {
        self.timestamp_unix_ns = other.timestamp_unix_ns;
        self.timestamp_text = other.timestamp_text;
        self.severity = other.severity;
        self.host = other.host;
        self.service = other.service;
        self.process_id = other.process_id;
        self.event_id = other.event_id;
        self.request_id = other.request_id;
        self.trace_id = other.trace_id;
        self.message = other.message;
        self.network = other.network;
    }

    pub fn validateInternal(self: *const Record) bool {
        if (self.field_count > self.fields.len) return false;
        if (self.tag_count > self.tags.len) return false;
        if (self.warnings.count > self.warnings.entries.len) return false;
        return true;
    }
};

fn optionalTextEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

pub const OwnedRecord = struct {
    arena: std.heap.ArenaAllocator,
    record: Record,

    pub fn init(allocator: std.mem.Allocator, format: SourceFormat) OwnedRecord {
        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .record = Record.init(format),
        };
    }

    pub fn deinit(self: *OwnedRecord) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn cloneFrom(allocator: std.mem.Allocator, source: *const Record) !OwnedRecord {
        var owned = OwnedRecord.init(allocator, source.source.format);
        errdefer owned.deinit();
        const alloc = owned.arena.allocator();
        owned.record.source = source.source;
        if (source.source.path) |path| owned.record.source.path = try alloc.dupe(u8, path);
        owned.record.timestamp_unix_ns = source.timestamp_unix_ns;
        if (source.timestamp_text) |v| owned.record.timestamp_text = try alloc.dupe(u8, v);
        owned.record.severity = source.severity;
        if (source.host) |v| owned.record.host = try alloc.dupe(u8, v);
        if (source.service) |v| owned.record.service = try alloc.dupe(u8, v);
        if (source.process_id) |v| owned.record.process_id = try alloc.dupe(u8, v);
        if (source.event_id) |v| owned.record.event_id = try alloc.dupe(u8, v);
        if (source.request_id) |v| owned.record.request_id = try alloc.dupe(u8, v);
        if (source.trace_id) |v| owned.record.trace_id = try alloc.dupe(u8, v);
        owned.record.message = try alloc.dupe(u8, source.message);
        owned.record.network = source.network;
        if (source.network.source_address) |v| owned.record.network.source_address = try alloc.dupe(u8, v);
        if (source.network.destination_address) |v| owned.record.network.destination_address = try alloc.dupe(u8, v);
        if (source.network.protocol) |v| owned.record.network.protocol = try alloc.dupe(u8, v);
        if (source.network.method) |v| owned.record.network.method = try alloc.dupe(u8, v);
        if (source.network.path) |v| owned.record.network.path = try alloc.dupe(u8, v);
        for (source.fieldSlice()) |field| {
            const key = try alloc.dupe(u8, field.key);
            const value = switch (field.value) {
                .text => |v| Value{ .text = try alloc.dupe(u8, v) },
                .integer => |v| Value{ .integer = v },
                .decimal => |v| Value{ .decimal = v },
                .boolean => |v| Value{ .boolean = v },
                .null_value => Value{ .null_value = {} },
            };
            try owned.record.addField(key, value);
        }
        for (source.tagSlice()) |tag| try owned.record.addTag(try alloc.dupe(u8, tag));
        return owned;
    }
};

pub const RecordBatch = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayList(OwnedRecord),

    pub fn init(allocator: std.mem.Allocator) RecordBatch {
        return .{ .allocator = allocator, .records = std.ArrayList(OwnedRecord).init(allocator) };
    }

    pub fn deinit(self: *RecordBatch) void {
        for (self.records.items) |*record| record.deinit();
        self.records.deinit();
    }

    pub fn appendClone(self: *RecordBatch, record: *const Record) !void {
        var owned = try OwnedRecord.cloneFrom(self.allocator, record);
        errdefer owned.deinit();
        try self.records.append(owned);
    }

    pub fn slice(self: *const RecordBatch) []const OwnedRecord {
        return self.records.items;
    }
};

test "owned records outlive borrowed input" {
    var source = Record.init(.jsonl);
    source.host = "edge-01";
    source.message = "probe succeeded";
    try source.addField("latency_ms", .{ .integer = 18 });
    var owned = try OwnedRecord.cloneFrom(std.testing.allocator, &source);
    defer owned.deinit();
    try std.testing.expectEqualStrings("edge-01", owned.record.host.?);
    try std.testing.expectEqual(@as(i64, 18), owned.record.getField("latency_ms").?.integer);
}
