//! The time-lock puzzle: a sequential chain of RandomX v2 hashes.
//!
//! Locking splits the total work into `chains` independent chains that are
//! computed in parallel, one per thread. The output of chain `j` encrypts the
//! seed of chain `j + 1`, so whoever unlocks has to walk every chain in order,
//! on a single thread: lock time ≈ T / threads, unlock time ≈ T.
//!
//! Every step is `x = RandomX_v2(key = "yuzu/rx2" ‖ salt, input = x ‖ chain ‖ index)`.
//! RandomX runs random programs designed so that a general-purpose CPU is
//! close to the best possible hardware for them, which keeps the speedup of
//! specialized hardware small. Fast mode reads a 2 GiB dataset shared by all
//! threads; light mode computes dataset items from the 256 MiB cache instead
//! (the same results, several times slower).

const std = @import("std");
const Io = std.Io;
const randomx = @import("randomx");
const Blake2b256 = std.crypto.hash.blake2.Blake2b256;
const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;
const XChaCha = std.crypto.aead.chacha_poly.XChaCha20Poly1305;

pub const Hash = [32]u8;
pub const Check = [16]u8;

pub const max_chains = 1024;
pub const default_chunk_size = 1024 * 1024;

/// Algorithm id stored in the header.
pub const algorithm_randomx_v2: u16 = 1;
const key_prefix = "yuzu/rx2";

/// RAM for fast mode (dataset + cache) and per extra thread (scratchpad + JIT).
pub const fast_mode_bytes: u64 = randomx.Dataset.size + randomx.config.cache_size;
pub const light_mode_bytes: u64 = randomx.config.cache_size;
pub const per_thread_bytes: u64 = randomx.config.scratchpad_l3 + 128 * 1024;
/// 2 MiB huge pages the dataset needs to sit on explicit huge pages.
pub const dataset_huge_pages: u64 = (randomx.Dataset.size + (2 << 20) - 1) / (2 << 20);

pub const Mode = enum { fast, light };

/// How the dataset (fast) or cache (light) memory is backed, as recorded in
/// the header for the benchmark run. `none` when no benchmark was run.
pub const BenchPages = enum(u8) { normal = 0, transparent = 1, explicit = 2, none = 0xff, _ };

/// The RandomX state for one file, shared by all of its threads.
pub const Engine = struct {
    gpa: std.mem.Allocator,
    mode: Mode,
    cache: *randomx.Cache,
    dataset: ?*randomx.Dataset,

    /// Builds the cache for this file's key and, in fast mode, the dataset
    /// (using `threads` threads). The dataset is allocated first so a small
    /// huge page pool goes to it.
    pub fn init(gpa: std.mem.Allocator, salt: [16]u8, mode: Mode, threads: usize) !Engine {
        if (!randomx.hasHardwareAes()) return error.AesNotSupported;
        var dataset: ?*randomx.Dataset = null;
        errdefer if (dataset) |ds| ds.destroy(gpa);
        if (mode == .fast) dataset = try randomx.Dataset.create(gpa, .{});
        const cache = try randomx.Cache.create(gpa, .{});
        errdefer cache.destroy(gpa);
        const key = rxKey(salt);
        cache.init(&key);
        if (dataset) |ds| try ds.init(cache, threads);
        return .{ .gpa = gpa, .mode = mode, .cache = cache, .dataset = dataset };
    }

    pub fn deinit(self: *Engine) void {
        if (self.dataset) |ds| ds.destroy(self.gpa);
        self.cache.destroy(self.gpa);
        self.* = undefined;
    }

    /// Page kind of the memory the hashing reads most: the dataset in fast
    /// mode, the cache in light mode.
    pub fn pages(self: *const Engine) BenchPages {
        const kind = if (self.dataset) |ds| ds.region.kind else self.cache.region.kind;
        return switch (kind) {
            .normal => .normal,
            .transparent => .transparent,
            .explicit => .explicit,
        };
    }

    /// A VM for one thread.
    pub fn stepper(self: *const Engine) !Stepper {
        const source: randomx.Source = if (self.dataset) |ds| .{ .fast = ds } else .{ .light = self.cache };
        return .{ .gpa = self.gpa, .vm = try randomx.Vm.create(self.gpa, source, .{}) };
    }
};

/// The RandomX key for a file: a fixed prefix plus the file's salt.
pub fn rxKey(salt: [16]u8) [key_prefix.len + 16]u8 {
    var k: [key_prefix.len + 16]u8 = undefined;
    @memcpy(k[0..key_prefix.len], key_prefix);
    @memcpy(k[key_prefix.len..], &salt);
    return k;
}

/// One thread's hasher.
pub const Stepper = struct {
    gpa: std.mem.Allocator,
    vm: *randomx.Vm,

    pub fn deinit(self: *Stepper) void {
        self.vm.destroy(self.gpa);
        self.* = undefined;
    }

    pub fn step(self: *Stepper, x: *Hash, chain: u32, index: u64) void {
        var input: [32 + 4 + 8]u8 = undefined;
        @memcpy(input[0..32], x);
        std.mem.writeInt(u32, input[32..36], chain, .little);
        std.mem.writeInt(u64, input[36..44], index, .little);
        self.vm.hash(&input, x);
    }
};

fn derive(out: []u8, salt: [16]u8, chain_output: Hash, comptime label: []const u8) void {
    const prk = HkdfSha256.extract(&salt, &chain_output);
    HkdfSha256.expand(out, "yuzu v1 " ++ label, prk);
}

/// Key that hides the next chain's seed.
pub fn linkKey(salt: [16]u8, output: Hash) Hash {
    var k: Hash = undefined;
    derive(&k, salt, output, "link");
    return k;
}

/// Public value that lets the unlocker confirm a chain was computed correctly.
pub fn checkValue(salt: [16]u8, output: Hash) Check {
    var c: Check = undefined;
    derive(&c, salt, output, "check");
    return c;
}

/// The file encryption key, derived from the last chain's output.
pub fn fileKey(salt: [16]u8, output: Hash) Hash {
    var k: Hash = undefined;
    derive(&k, salt, output, "file");
    return k;
}

pub fn xorHash(a: Hash, b: Hash) Hash {
    var r: Hash = undefined;
    for (&r, a, b) |*o, x, y| o.* = x ^ y;
    return r;
}

// ---------------------------------------------------------------------------
// File header
// ---------------------------------------------------------------------------

pub const magic = "YUZULOCK".*;
pub const format_version: u16 = 3;
const fixed_len = 8 + 2 + 2 + 4 + 4 + 8 + 8 + 8 + 8 + 16 + 32 + 16 + 4;

pub const Header = struct {
    /// Page kind used while benchmarking, informational.
    bench_pages: BenchPages,
    chains: u32,
    /// Steps per chain.
    iterations: u64,
    /// Requested lock duration, informational.
    target_seconds: u64,
    /// Benchmarked single-thread speed on the locking machine, steps/s × 1000.
    rate_millis: u64,
    /// Unix seconds at lock time.
    created: i64,
    salt: [16]u8,
    /// Seed of chain 0, stored in the clear.
    seed: Hash,
    nonce_prefix: [16]u8,
    chunk_size: u32,
    /// `chains - 1` encrypted seeds for chains 1..n.
    links: []Hash,
    /// One check value per chain.
    checks: []Check,

    pub fn totalSteps(self: Header) u64 {
        return self.iterations * self.chains;
    }

    pub fn encodedLen(self: Header) usize {
        return fixed_len + self.links.len * 32 + self.checks.len * 16;
    }

    pub fn encode(self: Header, gpa: std.mem.Allocator) ![]u8 {
        const buf = try gpa.alloc(u8, self.encodedLen());
        var w: Io.Writer = .fixed(buf);
        w.writeAll(&magic) catch unreachable;
        w.writeInt(u16, format_version, .little) catch unreachable;
        w.writeInt(u16, algorithm_randomx_v2, .little) catch unreachable;
        w.writeInt(u32, @intFromEnum(self.bench_pages), .little) catch unreachable;
        w.writeInt(u32, self.chains, .little) catch unreachable;
        w.writeInt(u64, self.iterations, .little) catch unreachable;
        w.writeInt(u64, self.target_seconds, .little) catch unreachable;
        w.writeInt(u64, self.rate_millis, .little) catch unreachable;
        w.writeInt(i64, self.created, .little) catch unreachable;
        w.writeAll(&self.salt) catch unreachable;
        w.writeAll(&self.seed) catch unreachable;
        w.writeAll(&self.nonce_prefix) catch unreachable;
        w.writeInt(u32, self.chunk_size, .little) catch unreachable;
        for (self.links) |l| w.writeAll(&l) catch unreachable;
        for (self.checks) |c| w.writeAll(&c) catch unreachable;
        std.debug.assert(w.end == buf.len);
        return buf;
    }

    /// Reads a header; `raw` receives the exact encoded bytes (for the digest).
    pub fn read(gpa: std.mem.Allocator, r: *Io.Reader, raw: *[]u8) !Header {
        var fixed: [fixed_len]u8 = undefined;
        r.readSliceAll(&fixed) catch |e| return if (e == error.EndOfStream) error.NotAYuzuFile else e;
        var fr: Io.Reader = .fixed(&fixed);
        const m = fr.takeArray(8) catch unreachable;
        if (!std.mem.eql(u8, m, &magic)) return error.NotAYuzuFile;
        const version = fr.takeInt(u16, .little) catch unreachable;
        if (version != format_version) return error.UnsupportedVersion;
        if ((fr.takeInt(u16, .little) catch unreachable) != algorithm_randomx_v2) return error.UnsupportedVersion;

        var h: Header = undefined;
        h.bench_pages = @enumFromInt(@as(u8, @truncate(fr.takeInt(u32, .little) catch unreachable)));
        h.chains = fr.takeInt(u32, .little) catch unreachable;
        h.iterations = fr.takeInt(u64, .little) catch unreachable;
        h.target_seconds = fr.takeInt(u64, .little) catch unreachable;
        h.rate_millis = fr.takeInt(u64, .little) catch unreachable;
        h.created = fr.takeInt(i64, .little) catch unreachable;
        h.salt = (fr.takeArray(16) catch unreachable).*;
        h.seed = (fr.takeArray(32) catch unreachable).*;
        h.nonce_prefix = (fr.takeArray(16) catch unreachable).*;
        h.chunk_size = fr.takeInt(u32, .little) catch unreachable;

        if (h.chains == 0 or h.chains > max_chains or h.iterations == 0 or
            h.chunk_size == 0 or h.chunk_size > 64 * 1024 * 1024)
            return error.CorruptHeader;

        h.links = try gpa.alloc(Hash, h.chains - 1);
        errdefer gpa.free(h.links);
        h.checks = try gpa.alloc(Check, h.chains);
        errdefer gpa.free(h.checks);
        for (h.links) |*l| try r.readSliceAll(l);
        for (h.checks) |*c| try r.readSliceAll(c);

        raw.* = try h.encode(gpa);
        return h;
    }

    pub fn deinit(self: *Header, gpa: std.mem.Allocator) void {
        gpa.free(self.links);
        gpa.free(self.checks);
        self.* = undefined;
    }
};

pub fn digest(encoded_header: []const u8) Hash {
    var d: Hash = undefined;
    Blake2b256.hash(encoded_header, &d, .{});
    return d;
}

// ---------------------------------------------------------------------------
// Chunked authenticated encryption (STREAM construction)
// ---------------------------------------------------------------------------
//
// Chunk 0 holds metadata (the original file name). Every following chunk is
// `chunk_size` bytes of plaintext, except the final one, which is always
// shorter (possibly empty) and has the top bit of its counter set, so
// truncating or reordering chunks fails authentication.

pub const tag_len = XChaCha.tag_length;
const last_flag: u64 = 1 << 63;

fn chunkNonce(prefix: [16]u8, counter: u64, last: bool) [24]u8 {
    var n: [24]u8 = undefined;
    @memcpy(n[0..16], &prefix);
    std.mem.writeInt(u64, n[16..24], counter | (if (last) last_flag else 0), .little);
    return n;
}

pub const max_name_len = 4096;

pub fn encryptStream(
    gpa: std.mem.Allocator,
    key: Hash,
    h: Header,
    ad: Hash,
    name: []const u8,
    in: *Io.Reader,
    out: *Io.Writer,
) !void {
    const plain = try gpa.alloc(u8, h.chunk_size);
    defer gpa.free(plain);
    const cipher = try gpa.alloc(u8, h.chunk_size);
    defer gpa.free(cipher);
    var tag: [tag_len]u8 = undefined;

    // Metadata chunk.
    var meta_buf: [2 + max_name_len]u8 = undefined;
    const n = @min(name.len, max_name_len);
    std.mem.writeInt(u16, meta_buf[0..2], @intCast(n), .little);
    @memcpy(meta_buf[2..][0..n], name[0..n]);
    const meta = meta_buf[0 .. 2 + n];
    var meta_c: [meta_buf.len]u8 = undefined;
    XChaCha.encrypt(meta_c[0..meta.len], &tag, meta, &ad, chunkNonce(h.nonce_prefix, 0, false), key);
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(meta.len), .little);
    try out.writeAll(&len_buf);
    try out.writeAll(meta_c[0..meta.len]);
    try out.writeAll(&tag);

    var counter: u64 = 1;
    while (true) : (counter += 1) {
        const got = try in.readSliceShort(plain);
        const last = got < plain.len;
        XChaCha.encrypt(cipher[0..got], &tag, plain[0..got], &ad, chunkNonce(h.nonce_prefix, counter, last), key);
        try out.writeAll(cipher[0..got]);
        try out.writeAll(&tag);
        if (last) break;
    }
    std.crypto.secureZero(u8, plain);
}

/// Decrypts only the metadata chunk and returns the stored file name.
pub fn decryptName(key: Hash, h: Header, ad: Hash, in: *Io.Reader, name_out: []u8) ![]u8 {
    var len_buf: [4]u8 = undefined;
    try in.readSliceAll(&len_buf);
    const len = std.mem.readInt(u32, &len_buf, .little);
    if (len < 2 or len > 2 + max_name_len) return error.CorruptFile;
    var c: [2 + max_name_len]u8 = undefined;
    var m: [2 + max_name_len]u8 = undefined;
    try in.readSliceAll(c[0..len]);
    var tag: [tag_len]u8 = undefined;
    try in.readSliceAll(&tag);
    XChaCha.decrypt(m[0..len], c[0..len], tag, &ad, chunkNonce(h.nonce_prefix, 0, false), key) catch
        return error.WrongKeyOrCorrupt;
    const n = std.mem.readInt(u16, m[0..2], .little);
    if (2 + @as(usize, n) != len or n > name_out.len) return error.CorruptFile;
    @memcpy(name_out[0..n], m[2..][0..n]);
    return name_out[0..n];
}

/// Decrypts the data chunks that follow the metadata chunk.
pub fn decryptData(gpa: std.mem.Allocator, key: Hash, h: Header, ad: Hash, in: *Io.Reader, out: *Io.Writer) !void {
    const cipher = try gpa.alloc(u8, @as(usize, h.chunk_size) + tag_len);
    defer gpa.free(cipher);
    const plain = try gpa.alloc(u8, h.chunk_size);
    defer gpa.free(plain);

    var counter: u64 = 1;
    while (true) : (counter += 1) {
        const got = try in.readSliceShort(cipher);
        if (got < tag_len) return error.Truncated;
        const last = got < cipher.len;
        const body = got - tag_len;
        XChaCha.decrypt(plain[0..body], cipher[0..body], cipher[body..got][0..tag_len].*, &ad, chunkNonce(h.nonce_prefix, counter, last), key) catch
            return error.WrongKeyOrCorrupt;
        try out.writeAll(plain[0..body]);
        if (last) break;
    }
    var extra: [1]u8 = undefined;
    if (try in.readSliceShort(&extra) != 0) return error.TrailingData;
    std.crypto.secureZero(u8, plain);
}

// ---------------------------------------------------------------------------
// Unlock progress checkpoint
// ---------------------------------------------------------------------------

pub const progress_magic = "YUZUPROG".*;
pub const progress_len = 8 + 32 + 4 + 8 + 32;

pub const Checkpoint = struct {
    /// Digest of the header this checkpoint belongs to.
    file_digest: Hash,
    chain: u32,
    /// Steps already applied to `state` in `chain`.
    index: u64,
    state: Hash,

    pub fn encode(self: Checkpoint) [progress_len]u8 {
        var buf: [progress_len]u8 = undefined;
        @memcpy(buf[0..8], &progress_magic);
        @memcpy(buf[8..40], &self.file_digest);
        std.mem.writeInt(u32, buf[40..44], self.chain, .little);
        std.mem.writeInt(u64, buf[44..52], self.index, .little);
        @memcpy(buf[52..84], &self.state);
        return buf;
    }

    pub fn decode(buf: []const u8) ?Checkpoint {
        if (buf.len != progress_len or !std.mem.eql(u8, buf[0..8], &progress_magic)) return null;
        return .{
            .file_digest = buf[8..40].*,
            .chain = std.mem.readInt(u32, buf[40..44], .little),
            .index = std.mem.readInt(u64, buf[44..52], .little),
            .state = buf[52..84].*,
        };
    }
};
