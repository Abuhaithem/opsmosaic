const std = @import("std");

pub const SourceFormat = enum {
    unknown,
    syslog,
    rfc5424,
    jsonl,
    csv,
    ini,
    access_log,
    dns_zone,
    env_file,
    manifest,

    pub fn label(self: SourceFormat) []const u8 {
        return switch (self) {
            .unknown => "unknown",
            .syslog => "syslog",
            .rfc5424 => "rfc5424",
            .jsonl => "jsonl",
            .csv => "csv",
            .ini => "ini",
            .access_log => "access-log",
            .dns_zone => "dns-zone",
            .env_file => "env",
            .manifest => "manifest",
        };
    }

    pub fn fromLabel(label_raw: []const u8) ?SourceFormat {
        const name = std.mem.trim(u8, label_raw, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(name, "auto")) return .unknown;
        if (std.ascii.eqlIgnoreCase(name, "syslog")) return .syslog;
        if (std.ascii.eqlIgnoreCase(name, "rfc5424")) return .rfc5424;
        if (std.ascii.eqlIgnoreCase(name, "jsonl") or std.ascii.eqlIgnoreCase(name, "json-lines")) return .jsonl;
        if (std.ascii.eqlIgnoreCase(name, "csv")) return .csv;
        if (std.ascii.eqlIgnoreCase(name, "ini")) return .ini;
        if (std.ascii.eqlIgnoreCase(name, "access") or std.ascii.eqlIgnoreCase(name, "access-log")) return .access_log;
        if (std.ascii.eqlIgnoreCase(name, "dns") or std.ascii.eqlIgnoreCase(name, "dns-zone")) return .dns_zone;
        if (std.ascii.eqlIgnoreCase(name, "env") or std.ascii.eqlIgnoreCase(name, "dotenv")) return .env_file;
        if (std.ascii.eqlIgnoreCase(name, "manifest") or std.ascii.eqlIgnoreCase(name, "yaml")) return .manifest;
        return null;
    }
};

pub const SourceInfo = struct {
    format: SourceFormat = .unknown,
    path: ?[]const u8 = null,
    line: usize = 1,
    column: usize = 1,
    byte_offset: usize = 0,

    pub fn displayName(self: SourceInfo) []const u8 {
        return self.path orelse "<stdin>";
    }

    pub fn nextLine(self: *SourceInfo, consumed: usize) void {
        self.line += 1;
        self.column = 1;
        self.byte_offset += consumed;
    }

    pub fn advanceColumn(self: *SourceInfo, consumed: usize) void {
        self.column += consumed;
        self.byte_offset += consumed;
    }
};

pub fn extensionHint(path: []const u8) SourceFormat {
    const ext = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".jsonl") or std.ascii.eqlIgnoreCase(ext, ".ndjson")) return .jsonl;
    if (std.ascii.eqlIgnoreCase(ext, ".csv")) return .csv;
    if (std.ascii.eqlIgnoreCase(ext, ".ini") or std.ascii.eqlIgnoreCase(ext, ".conf")) return .ini;
    if (std.ascii.eqlIgnoreCase(ext, ".env")) return .env_file;
    if (std.ascii.eqlIgnoreCase(ext, ".zone") or std.ascii.eqlIgnoreCase(ext, ".dns")) return .dns_zone;
    if (std.ascii.eqlIgnoreCase(ext, ".yaml") or std.ascii.eqlIgnoreCase(ext, ".yml")) return .manifest;
    if (std.ascii.eqlIgnoreCase(ext, ".log")) return .unknown;
    return .unknown;
}

test "source formats accept operator friendly aliases" {
    try std.testing.expectEqual(SourceFormat.access_log, SourceFormat.fromLabel("access").?);
    try std.testing.expectEqual(SourceFormat.env_file, extensionHint("service.env"));
}
