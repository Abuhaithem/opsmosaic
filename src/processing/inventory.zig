const std = @import("std");
const record_mod = @import("../model/record.zig");
const eval = @import("query_eval.zig");

pub const Asset = struct {
    record_index: usize,
    asset_id: []const u8,
    host: ?[]const u8,
    service: ?[]const u8,
    region: ?[]const u8,
    state: ?[]const u8,
    capacity: ?f64,
};

pub const Catalog = struct {
    assets: [2048]Asset = undefined,
    count: usize = 0,
    missing_id: usize = 0,
    duplicate_id: usize = 0,
    truncated: usize = 0,

    pub fn slice(self: *const Catalog) []const Asset {
        return self.assets[0..self.count];
    }

    pub fn find(self: *const Catalog, asset_id: []const u8) ?Asset {
        for (self.slice()) |asset| if (std.mem.eql(u8, asset.asset_id, asset_id)) return asset;
        return null;
    }
};

pub fn build(records: []const record_mod.Record) Catalog {
    var catalog = Catalog{};
    for (records, 0..) |*record, index| {
        if (record.source.format != .csv) continue;
        const asset_id = textField(record, "asset_id") orelse textField(record, "id") orelse {
            catalog.missing_id += 1;
            continue;
        };
        if (catalog.find(asset_id) != null) {
            catalog.duplicate_id += 1;
            continue;
        }
        if (catalog.count >= catalog.assets.len) {
            catalog.truncated += 1;
            continue;
        }
        catalog.assets[catalog.count] = .{
            .record_index = index,
            .asset_id = asset_id,
            .host = record.host orelse textField(record, "hostname"),
            .service = record.service,
            .region = textField(record, "region"),
            .state = textField(record, "state"),
            .capacity = numericField(record, "capacity"),
        };
        catalog.count += 1;
    }
    return catalog;
}

pub const Observation = struct {
    record_index: usize,
    asset_id: ?[]const u8,
    host: ?[]const u8,
    service: ?[]const u8,
};

pub const MatchKind = enum { asset_id, host, service, unmatched, ambiguous };

pub const Reconciliation = struct {
    observations: usize = 0,
    matched_by_asset_id: usize = 0,
    matched_by_host: usize = 0,
    matched_by_service: usize = 0,
    unmatched: usize = 0,
    ambiguous: usize = 0,
    inactive_observations: usize = 0,
    capacity_observed: f64 = 0,
};

pub const Match = struct {
    kind: MatchKind,
    asset: ?Asset = null,
};

pub fn matchObservation(record: *const record_mod.Record, catalog: *const Catalog) Match {
    if (textField(record, "asset_id")) |asset_id| {
        if (catalog.find(asset_id)) |asset| return .{ .kind = .asset_id, .asset = asset };
    }
    if (record.host) |host| {
        var found: ?Asset = null;
        for (catalog.slice()) |asset| {
            const candidate = asset.host orelse continue;
            if (!std.ascii.eqlIgnoreCase(candidate, host)) continue;
            if (found != null) return .{ .kind = .ambiguous };
            found = asset;
        }
        if (found) |asset| return .{ .kind = .host, .asset = asset };
    }
    if (record.service) |service| {
        var found: ?Asset = null;
        for (catalog.slice()) |asset| {
            const candidate = asset.service orelse continue;
            if (!std.ascii.eqlIgnoreCase(candidate, service)) continue;
            if (found != null) return .{ .kind = .ambiguous };
            found = asset;
        }
        if (found) |asset| return .{ .kind = .service, .asset = asset };
    }
    return .{ .kind = .unmatched };
}

pub fn reconcile(records: []const record_mod.Record, catalog: *const Catalog) Reconciliation {
    var result = Reconciliation{};
    for (records) |*record| {
        if (record.source.format == .csv) continue;
        result.observations += 1;
        const matched = matchObservation(record, catalog);
        switch (matched.kind) {
            .asset_id => result.matched_by_asset_id += 1,
            .host => result.matched_by_host += 1,
            .service => result.matched_by_service += 1,
            .unmatched => result.unmatched += 1,
            .ambiguous => result.ambiguous += 1,
        }
        if (matched.asset) |asset| {
            if (asset.state) |state| {
                if (std.ascii.eqlIgnoreCase(state, "retired") or std.ascii.eqlIgnoreCase(state, "maintenance")) result.inactive_observations += 1;
            }
            if (asset.capacity) |capacity| result.capacity_observed += capacity;
        }
    }
    return result;
}

pub const RegionSummary = struct {
    entries: [128]Entry = undefined,
    count: usize = 0,
    missing_region: usize = 0,

    pub const Entry = struct {
        region: []const u8,
        assets: usize = 0,
        active: usize = 0,
        capacity: f64 = 0,
    };

    pub fn observe(self: *RegionSummary, asset: Asset) void {
        const region = asset.region orelse {
            self.missing_region += 1;
            return;
        };
        for (self.entries[0..self.count]) |*entry| {
            if (std.ascii.eqlIgnoreCase(entry.region, region)) {
                updateRegion(entry, asset);
                return;
            }
        }
        if (self.count >= self.entries.len) return;
        self.entries[self.count] = .{ .region = region };
        updateRegion(&self.entries[self.count], asset);
        self.count += 1;
    }
};

pub fn summarizeRegions(catalog: *const Catalog) RegionSummary {
    var result = RegionSummary{};
    for (catalog.slice()) |asset| result.observe(asset);
    return result;
}

fn updateRegion(entry: *RegionSummary.Entry, asset: Asset) void {
    entry.assets += 1;
    if (asset.state == null or std.ascii.eqlIgnoreCase(asset.state.?, "active")) entry.active += 1;
    if (asset.capacity) |capacity| entry.capacity += capacity;
}

fn textField(record: *const record_mod.Record, name: []const u8) ?[]const u8 {
    const value = eval.fieldValue(record, name) orelse return null;
    return value.asText();
}

fn numericField(record: *const record_mod.Record, name: []const u8) ?f64 {
    const value = eval.fieldValue(record, name) orelse return null;
    return value.asDecimal();
}

pub fn writeCatalog(catalog: *const Catalog, writer: anytype) !void {
    for (catalog.slice()) |asset| {
        try writer.print("asset={s} host={s} service={s} region={s} state={s}", .{
            asset.asset_id,
            asset.host orelse "-",
            asset.service orelse "-",
            asset.region orelse "-",
            asset.state orelse "-",
        });
        if (asset.capacity) |capacity| try writer.print(" capacity={d}", .{capacity});
        try writer.writeByte('\n');
    }
    try writer.print("missing_id={d} duplicate_id={d} truncated={d}\n", .{ catalog.missing_id, catalog.duplicate_id, catalog.truncated });
}

test "inventory reconciles observations by host" {
    var records = [_]record_mod.Record{ record_mod.Record.init(.csv), record_mod.Record.init(.syslog) };
    try records[0].addField("asset_id", .{ .text = "edge-01" });
    try records[0].addField("hostname", .{ .text = "edge-a" });
    records[1].host = "EDGE-A";
    const catalog = build(&records);
    const result = reconcile(&records, &catalog);
    try std.testing.expectEqual(@as(usize, 1), result.matched_by_host);
}
