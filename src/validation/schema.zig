const std = @import("std");
const value_mod = @import("../model/value.zig");
const source_mod = @import("../model/source_info.zig");

pub const Requirement = enum { optional, required, recommended };

pub const FieldConstraint = struct {
    name: []const u8,
    kind: ?value_mod.ValueKind = null,
    requirement: Requirement = .optional,
    min_integer: ?i64 = null,
    max_integer: ?i64 = null,
    min_decimal: ?f64 = null,
    max_decimal: ?f64 = null,
    min_length: ?usize = null,
    max_length: ?usize = null,
    allowed_values: []const []const u8 = &.{},
    allow_empty: bool = true,

    pub fn validatesKind(self: FieldConstraint, value: value_mod.Value) bool {
        if (self.kind) |expected| return value.kind() == expected;
        return true;
    }

    pub fn validatesRange(self: FieldConstraint, value: value_mod.Value) bool {
        switch (value) {
            .integer => |v| {
                if (self.min_integer) |minimum| if (v < minimum) return false;
                if (self.max_integer) |maximum| if (v > maximum) return false;
            },
            .decimal => |v| {
                if (self.min_decimal) |minimum| if (v < minimum) return false;
                if (self.max_decimal) |maximum| if (v > maximum) return false;
            },
            .text => |v| {
                if (!self.allow_empty and v.len == 0) return false;
                if (self.min_length) |minimum| if (v.len < minimum) return false;
                if (self.max_length) |maximum| if (v.len > maximum) return false;
            },
            else => {},
        }
        return true;
    }

    pub fn validatesAllowed(self: FieldConstraint, value: value_mod.Value) bool {
        if (self.allowed_values.len == 0) return true;
        const text = value.asText() orelse return false;
        for (self.allowed_values) |allowed| { if (std.ascii.eqlIgnoreCase(text, allowed)) return true; }
        return false;
    }
};

pub const Schema = struct {
    name: []const u8,
    description: []const u8,
    formats: []const source_mod.SourceFormat = &.{},
    fields: []const FieldConstraint,
    allow_unknown_fields: bool = true,
    require_timestamp: bool = false,
    require_host: bool = false,
    require_service: bool = false,
    require_message: bool = false,

    pub fn acceptsFormat(self: Schema, format: source_mod.SourceFormat) bool {
        if (self.formats.len == 0) return true;
        for (self.formats) |candidate| { if (candidate == format) return true; }
        return false;
    }

    pub fn findConstraint(self: Schema, name: []const u8) ?FieldConstraint {
        for (self.fields) |constraint| { if (std.mem.eql(u8, constraint.name, name)) return constraint; }
        return null;
    }
};

const service_event_fields = [_]FieldConstraint{
    .{ .name = "region", .kind = .text, .requirement = .recommended, .max_length = 64, .allow_empty = false },
    .{ .name = "duration_ms", .requirement = .optional, .min_decimal = 0 },
    .{ .name = "attempt", .kind = .integer, .requirement = .optional, .min_integer = 1, .max_integer = 1000 },
    .{ .name = "environment", .kind = .text, .requirement = .recommended, .allowed_values = &.{ "dev", "test", "staging", "prod", "production" } },
};

const http_event_fields = [_]FieldConstraint{
    .{ .name = "status", .kind = .integer, .requirement = .required, .min_integer = 100, .max_integer = 599 },
    .{ .name = "bytes", .kind = .integer, .requirement = .optional, .min_integer = 0 },
    .{ .name = "duration_ms", .requirement = .optional, .min_decimal = 0 },
    .{ .name = "user_agent", .kind = .text, .requirement = .optional, .max_length = 4096 },
};

const inventory_fields = [_]FieldConstraint{
    .{ .name = "asset_id", .kind = .text, .requirement = .required, .max_length = 128, .allow_empty = false },
    .{ .name = "region", .kind = .text, .requirement = .required, .max_length = 64, .allow_empty = false },
    .{ .name = "capacity", .requirement = .optional, .min_decimal = 0 },
    .{ .name = "state", .kind = .text, .requirement = .recommended, .allowed_values = &.{ "active", "standby", "maintenance", "retired" } },
};

const deployment_fields = [_]FieldConstraint{
    .{ .name = "name", .kind = .text, .requirement = .required, .max_length = 128, .allow_empty = false },
    .{ .name = "replicas", .kind = .integer, .requirement = .optional, .min_integer = 0, .max_integer = 100000 },
    .{ .name = "image", .kind = .text, .requirement = .recommended, .max_length = 1024, .allow_empty = false },
    .{ .name = "environment", .kind = .text, .requirement = .recommended, .max_length = 64 },
};

pub const service_event = Schema{
    .name = "service-event",
    .description = "Normalized application or infrastructure event",
    .formats = &.{ .syslog, .rfc5424, .jsonl },
    .fields = &service_event_fields,
    .require_timestamp = true,
    .require_host = true,
    .require_service = true,
    .require_message = true,
};

pub const http_event = Schema{
    .name = "http-event",
    .description = "HTTP access observation",
    .formats = &.{.access_log},
    .fields = &http_event_fields,
    .require_timestamp = true,
    .require_message = true,
};

pub const inventory = Schema{
    .name = "inventory",
    .description = "CSV infrastructure inventory row",
    .formats = &.{.csv},
    .fields = &inventory_fields,
};

pub const deployment = Schema{
    .name = "deployment",
    .description = "Safe-subset deployment manifest",
    .formats = &.{.manifest},
    .fields = &deployment_fields,
    .require_service = true,
};

pub fn builtIn(name: []const u8) ?Schema {
    if (std.ascii.eqlIgnoreCase(name, service_event.name)) return service_event;
    if (std.ascii.eqlIgnoreCase(name, http_event.name)) return http_event;
    if (std.ascii.eqlIgnoreCase(name, inventory.name)) return inventory;
    if (std.ascii.eqlIgnoreCase(name, deployment.name)) return deployment;
    return null;
}

pub fn builtInNames() []const []const u8 {
    return &.{ service_event.name, http_event.name, inventory.name, deployment.name };
}

test "built-in schemas are discoverable" {
    try std.testing.expectEqualStrings("http-event", builtIn("HTTP-EVENT").?.name);
}
