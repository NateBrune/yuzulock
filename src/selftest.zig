//! Known-answer tests run before every lock and unlock, and by `yuzu selftest`.
//!
//! A time-lock is only recoverable if the unlocking build computes exactly
//! what the locking build did, possibly months apart. These checks pin the
//! RandomX implementation to the official RandomX v2 test vectors, and pin
//! yuzu's own step (key and input layout) to values computed independently
//! with the reference C++ RandomX library.

const std = @import("std");
const randomx = @import("randomx");
const puzzle = @import("puzzle.zig");

pub const Result = struct {
    name: []const u8,
    ok: bool,
};

fn hex(comptime s: []const u8) [s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch unreachable;
    return out;
}

/// From RandomX's src/tests/tests.cpp ("Hash test 1a–1c", v2).
const rx_vectors = [_]struct { name: []const u8, input: []const u8, want: [32]u8 }{
    .{ .name = "RandomX v2 test 1a", .input = "This is a test", .want = hex("22ec6b861b3eb23686b2efbad69513c967ecfce80983df66c9c5b4fbfb4cdb6f") },
    .{ .name = "RandomX v2 test 1b", .input = "Lorem ipsum dolor sit amet", .want = hex("9e2c772c12fd48f93c14c97fdc89d556264d9100597023f44d9163e279012ecf") },
    .{ .name = "RandomX v2 test 1c", .input = "sed do eiusmod tempor incididunt ut labore et dolore magna aliqua", .want = hex("4d6b063a1a603751d525f18a171336a4002f2f06df6c17e4b25fe17e17796e42") },
};

/// Two chained yuzu steps from x = bytes 0..31, chain 7, indexes 42 and 43,
/// with the key for salt = 16 × 0xa5, computed with the reference library
/// (librandomx v2.0.1, randomx_calculate_hash with RANDOMX_FLAG_V2).
const step_vectors = [_]struct { name: []const u8, want: [32]u8 }{
    .{ .name = "yuzu step 1 (reference RandomX)", .want = hex("533660f9f3003cc53e95fcdd9d541bb13c6cae50ea7a2ab5cac8bc2f54a10846") },
    .{ .name = "yuzu step 2 (reference RandomX)", .want = hex("02d6aaa19fb58a802049cf2f36a4333806cbb298baece2cbf6b9367ed73bebb6") },
};

pub const count = rx_vectors.len + step_vectors.len;

/// Runs every check (light mode, about 2 seconds); fills `results` and
/// returns whether all passed.
pub fn run(gpa: std.mem.Allocator, io: std.Io, results: *[count]Result) !bool {
    _ = io;
    var all = true;
    var i: usize = 0;

    const cache = try randomx.Cache.create(gpa, .{ .huge_pages = false });
    defer cache.destroy(gpa);
    const vm = try randomx.Vm.create(gpa, .{ .light = cache }, .{ .huge_pages = false });
    defer vm.destroy(gpa);

    cache.init("test key 000");
    for (rx_vectors) |v| {
        var out: [32]u8 = undefined;
        vm.hash(v.input, &out);
        const ok = std.mem.eql(u8, &out, &v.want);
        results[i] = .{ .name = v.name, .ok = ok };
        all = all and ok;
        i += 1;
    }

    const key = puzzle.rxKey(@splat(0xa5));
    cache.init(&key);
    var stepper: puzzle.Stepper = .{ .gpa = gpa, .vm = vm };
    var x: puzzle.Hash = undefined;
    for (&x, 0..) |*b, j| b.* = @intCast(j);
    for (step_vectors, 0..) |v, k| {
        stepper.step(&x, 7, 42 + k);
        const ok = std.mem.eql(u8, &x, &v.want);
        results[i] = .{ .name = v.name, .ok = ok };
        all = all and ok;
        i += 1;
    }
    return all;
}

/// Convenience for callers that only need pass/fail.
pub fn check(gpa: std.mem.Allocator, io: std.Io) !void {
    var results: [count]Result = undefined;
    if (!try run(gpa, io, &results)) return error.SelfTestFailed;
}
