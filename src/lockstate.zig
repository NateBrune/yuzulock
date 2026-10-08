//! Saved progress of an unfinished lock, so a long lock survives a crash,
//! reboot or Ctrl+C.
//!
//! It holds every chain's seed, so anyone who reads it can skip the work. It
//! is written owner-only (0600) and deleted as soon as the lock completes.

const std = @import("std");
const puzzle = @import("puzzle.zig");
const Blake2b256 = std.crypto.hash.blake2.Blake2b256;

pub const magic = "YUZULKST".*;
pub const version: u16 = 2;
const fixed_len = 8 + 2 + 2 + 4 + 4 + 8 + 8 + 8 + 8 + 16 + 2;
const chain_len = 32 + 8 + 32;

pub const Chain = struct {
    seed: puzzle.Hash,
    /// Steps already applied to `state`.
    index: u64,
    state: puzzle.Hash,
};

pub const LockState = struct {
    /// Page kind during the benchmark (puzzle.BenchPages), for the header.
    bench_pages: u8,
    iterations: u64,
    target_seconds: u64,
    rate_millis: u64,
    created: i64,
    salt: [16]u8,
    /// The input path the lock was started with, to catch mismatched resumes.
    input: []const u8,
    chains: []Chain,

    pub fn doneSteps(self: LockState) u64 {
        var n: u64 = 0;
        for (self.chains) |c| n += c.index;
        return n;
    }

    pub fn encode(self: LockState, gpa: std.mem.Allocator) ![]u8 {
        if (self.input.len > std.math.maxInt(u16)) return error.NameTooLong;
        const len = fixed_len + self.input.len + self.chains.len * chain_len + 32;
        const buf = try gpa.alloc(u8, len);
        var w: std.Io.Writer = .fixed(buf);
        w.writeAll(&magic) catch unreachable;
        w.writeInt(u16, version, .little) catch unreachable;
        w.writeInt(u16, 0, .little) catch unreachable;
        w.writeInt(u32, self.bench_pages, .little) catch unreachable;
        w.writeInt(u32, @intCast(self.chains.len), .little) catch unreachable;
        w.writeInt(u64, self.iterations, .little) catch unreachable;
        w.writeInt(u64, self.target_seconds, .little) catch unreachable;
        w.writeInt(u64, self.rate_millis, .little) catch unreachable;
        w.writeInt(i64, self.created, .little) catch unreachable;
        w.writeAll(&self.salt) catch unreachable;
        w.writeInt(u16, @intCast(self.input.len), .little) catch unreachable;
        w.writeAll(self.input) catch unreachable;
        for (self.chains) |c| {
            w.writeAll(&c.seed) catch unreachable;
            w.writeInt(u64, c.index, .little) catch unreachable;
            w.writeAll(&c.state) catch unreachable;
        }
        var sum: puzzle.Hash = undefined;
        Blake2b256.hash(buf[0 .. len - 32], &sum, .{});
        w.writeAll(&sum) catch unreachable;
        std.debug.assert(w.end == len);
        return buf;
    }

    pub fn decode(gpa: std.mem.Allocator, buf: []const u8) !LockState {
        if (buf.len < fixed_len + 32) return error.CorruptLockState;
        var sum: puzzle.Hash = undefined;
        Blake2b256.hash(buf[0 .. buf.len - 32], &sum, .{});
        if (!std.mem.eql(u8, &sum, buf[buf.len - 32 ..])) return error.CorruptLockState;

        var r: std.Io.Reader = .fixed(buf[0 .. buf.len - 32]);
        const m = r.takeArray(8) catch return error.CorruptLockState;
        if (!std.mem.eql(u8, m, &magic)) return error.CorruptLockState;
        if ((r.takeInt(u16, .little) catch return error.CorruptLockState) != version) return error.UnsupportedVersion;
        _ = r.takeInt(u16, .little) catch return error.CorruptLockState;

        var s: LockState = undefined;
        s.bench_pages = @truncate(r.takeInt(u32, .little) catch return error.CorruptLockState);
        const n = r.takeInt(u32, .little) catch return error.CorruptLockState;
        s.iterations = r.takeInt(u64, .little) catch return error.CorruptLockState;
        s.target_seconds = r.takeInt(u64, .little) catch return error.CorruptLockState;
        s.rate_millis = r.takeInt(u64, .little) catch return error.CorruptLockState;
        s.created = r.takeInt(i64, .little) catch return error.CorruptLockState;
        s.salt = (r.takeArray(16) catch return error.CorruptLockState).*;
        const name_len = r.takeInt(u16, .little) catch return error.CorruptLockState;
        if (n == 0 or n > puzzle.max_chains or s.iterations == 0 or
            buf.len != fixed_len + name_len + n * chain_len + 32)
            return error.CorruptLockState;

        s.input = try gpa.dupe(u8, r.take(name_len) catch unreachable);
        errdefer gpa.free(s.input);
        s.chains = try gpa.alloc(Chain, n);
        for (s.chains) |*c| {
            c.seed = (r.takeArray(32) catch unreachable).*;
            c.index = r.takeInt(u64, .little) catch unreachable;
            c.state = (r.takeArray(32) catch unreachable).*;
            if (c.index > s.iterations) {
                gpa.free(s.chains);
                return error.CorruptLockState;
            }
        }
        return s;
    }

    pub fn deinit(self: *LockState, gpa: std.mem.Allocator) void {
        std.crypto.secureZero(u8, std.mem.sliceAsBytes(self.chains));
        gpa.free(self.chains);
        gpa.free(self.input);
        self.* = undefined;
    }
};
