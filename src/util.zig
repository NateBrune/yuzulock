const std = @import("std");
const Io = std.Io;

/// Parses durations like "90", "45s", "15m", "2h30m", "3d", "1w".
/// A bare number is seconds.
pub fn parseDuration(text: []const u8) !u64 {
    const s = std.mem.trim(u8, text, " \t");
    if (s.len == 0) return error.InvalidDuration;
    var total: u64 = 0;
    var i: usize = 0;
    while (i < s.len) {
        const start = i;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        if (i == start) return error.InvalidDuration;
        const n = std.fmt.parseInt(u64, s[start..i], 10) catch return error.InvalidDuration;
        const unit: u64 = if (i == s.len) 1 else switch (std.ascii.toLower(s[i])) {
            's' => 1,
            'm' => 60,
            'h' => 3600,
            'd' => 86400,
            'w' => 7 * 86400,
            else => return error.InvalidDuration,
        };
        if (i < s.len) i += 1;
        total = std.math.add(u64, total, std.math.mul(u64, n, unit) catch return error.InvalidDuration) catch
            return error.InvalidDuration;
    }
    if (total == 0) return error.InvalidDuration;
    return total;
}

pub fn fmtDuration(buf: []u8, seconds: u64) []const u8 {
    const d = seconds / 86400;
    const h = (seconds % 86400) / 3600;
    const m = (seconds % 3600) / 60;
    const s = seconds % 60;
    return (if (d > 0)
        std.fmt.bufPrint(buf, "{d}d {d}h {d}m", .{ d, h, m })
    else if (h > 0)
        std.fmt.bufPrint(buf, "{d}h {d}m {d}s", .{ h, m, s })
    else if (m > 0)
        std.fmt.bufPrint(buf, "{d}m {d}s", .{ m, s })
    else
        std.fmt.bufPrint(buf, "{d}s", .{s})) catch buf[0..0];
}

pub fn fmtSizeKib(buf: []u8, kib: u64) []const u8 {
    return (if (kib >= 1024 * 1024 and kib % (1024 * 1024) == 0)
        std.fmt.bufPrint(buf, "{d} GiB", .{kib / (1024 * 1024)})
    else if (kib >= 1024 * 1024)
        std.fmt.bufPrint(buf, "{d:.1} GiB", .{@as(f64, @floatFromInt(kib)) / (1024 * 1024)})
    else if (kib >= 1024)
        std.fmt.bufPrint(buf, "{d:.0} MiB", .{@as(f64, @floatFromInt(kib)) / 1024})
    else
        std.fmt.bufPrint(buf, "{d} KiB", .{kib})) catch buf[0..0];
}

/// Memory available in KiB, or null if unknown. Free reserved huge pages
/// (which MemAvailable leaves out) are added only when there are at least
/// `usable_huge_pages` of them: a pool too small for the allocation that
/// would use it is just memory nobody else can have.
pub fn availableMemKib(io: Io, usable_huge_pages: u64) ?u64 {
    var buf: [8192]u8 = undefined;
    const data = Io.Dir.cwd().readFile(io, "/proc/meminfo", &buf) catch return null;
    const avail = meminfoField(data, "MemAvailable:") orelse return null;
    const huge_free = meminfoField(data, "HugePages_Free:") orelse 0;
    const huge_size = meminfoField(data, "Hugepagesize:") orelse 2048;
    return if (huge_free >= usable_huge_pages) avail + huge_free * huge_size else avail;
}

/// Reserved explicit huge pages (count), or 0 if unknown.
pub fn totalHugePages(io: Io) u64 {
    var buf: [8192]u8 = undefined;
    const data = Io.Dir.cwd().readFile(io, "/proc/meminfo", &buf) catch return 0;
    return meminfoField(data, "HugePages_Total:") orelse 0;
}

/// Free explicit huge pages (count), or 0 if unknown.
pub fn freeHugePages(io: Io) u64 {
    var buf: [8192]u8 = undefined;
    const data = Io.Dir.cwd().readFile(io, "/proc/meminfo", &buf) catch return 0;
    return meminfoField(data, "HugePages_Free:") orelse 0;
}

fn meminfoField(data: []const u8, name: []const u8) ?u64 {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, name)) continue;
        var it = std.mem.tokenizeAny(u8, line[name.len..], " \tkB");
        return std.fmt.parseInt(u64, it.next() orelse return null, 10) catch null;
    }
    return null;
}

pub fn exists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Writes `data` to `path` atomically, replacing any existing file.
pub fn writeFileAtomic(io: Io, path: []const u8, data: []const u8) !void {
    var af = try Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true, .permissions = .fromMode(0o600) });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, data);
    try af.replace(io);
}

pub fn nowNs(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

/// CPU facts from /sys (Linux) used to pick a RandomX thread count.
pub const CpuTopology = struct {
    logical: u32,
    /// Distinct (package, core) pairs; null if unknown.
    physical: ?u32,
    /// Total L3 cache across distinct L3 instances (e.g. per Ryzen CCD); null if unknown.
    l3_bytes: ?u64,
};

pub fn cpuTopology(io: Io) CpuTopology {
    const logical: u32 = @intCast(std.Thread.getCpuCount() catch 1);
    var cores: [512]u64 = undefined;
    var n_cores: usize = 0;
    var l3_ids: [64]u64 = undefined;
    var n_l3: usize = 0;
    var l3_size: ?u64 = null;
    var topology_ok = true;

    var cpu: u32 = 0;
    while (cpu < logical and cpu < 4096) : (cpu += 1) {
        var path_buf: [128]u8 = undefined;
        const pkg = readSysNumber(io, &path_buf, "/sys/devices/system/cpu/cpu{d}/topology/physical_package_id", cpu);
        const core = readSysNumber(io, &path_buf, "/sys/devices/system/cpu/cpu{d}/topology/core_id", cpu);
        if (pkg != null and core != null) {
            const key = (pkg.? << 32) | core.?;
            if (std.mem.indexOfScalar(u64, cores[0..n_cores], key) == null and n_cores < cores.len) {
                cores[n_cores] = key;
                n_cores += 1;
            }
        } else topology_ok = false;

        // The L3 is normally cache/index3; check its level to be sure.
        if (readSysNumber(io, &path_buf, "/sys/devices/system/cpu/cpu{d}/cache/index3/level", cpu) == 3) {
            const id = readSysNumber(io, &path_buf, "/sys/devices/system/cpu/cpu{d}/cache/index3/id", cpu) orelse 0;
            if (std.mem.indexOfScalar(u64, l3_ids[0..n_l3], id) == null and n_l3 < l3_ids.len) {
                l3_ids[n_l3] = id;
                n_l3 += 1;
            }
            if (l3_size == null) l3_size = readSysSize(io, &path_buf, "/sys/devices/system/cpu/cpu{d}/cache/index3/size", cpu);
        }
    }
    return .{
        .logical = logical,
        .physical = if (topology_ok and n_cores > 0) @intCast(n_cores) else null,
        .l3_bytes = if (l3_size) |size| size * @max(n_l3, 1) else null,
    };
}

fn readSysText(io: Io, path_buf: []u8, comptime fmt: []const u8, cpu: u32, out: []u8) ?[]const u8 {
    const path = std.fmt.bufPrint(path_buf, fmt, .{cpu}) catch return null;
    const data = Io.Dir.cwd().readFile(io, path, out) catch return null;
    return std.mem.trim(u8, data, " \n\t");
}

fn readSysNumber(io: Io, path_buf: []u8, comptime fmt: []const u8, cpu: u32) ?u64 {
    var buf: [32]u8 = undefined;
    const text = readSysText(io, path_buf, fmt, cpu, &buf) orelse return null;
    return std.fmt.parseInt(u64, text, 10) catch null;
}

/// Parses sizes like "3072K" or "32M" from sysfs cache entries.
fn readSysSize(io: Io, path_buf: []u8, comptime fmt: []const u8, cpu: u32) ?u64 {
    var buf: [32]u8 = undefined;
    const text = readSysText(io, path_buf, fmt, cpu, &buf) orelse return null;
    if (text.len == 0) return null;
    const mult: u64 = switch (text[text.len - 1]) {
        'K' => 1024,
        'M' => 1024 * 1024,
        'G' => 1024 * 1024 * 1024,
        else => 1,
    };
    const digits = if (mult == 1) text else text[0 .. text.len - 1];
    return (std.fmt.parseInt(u64, digits, 10) catch return null) * mult;
}
