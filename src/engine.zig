//! Lock and unlock jobs. Each job runs on a background thread and reports
//! through a `Status` that the UI polls.

const std = @import("std");
const Io = std.Io;
const puzzle = @import("puzzle.zig");
const util = @import("util.zig");
const selftest = @import("selftest.zig");
const lockstate = @import("lockstate.zig");

pub const max_lanes = puzzle.max_chains;
const bench_ns: i96 = 3 * std.time.ns_per_s;
const bench_min_steps = 20;
/// Headroom left free on top of RandomX's own memory.
const ram_margin_bytes: u64 = 128 * 1024 * 1024;
const checkpoint_interval_ns: i96 = 10 * std.time.ns_per_s;

pub const Phase = enum(u8) { starting, preparing, benchmarking, hashing, writing, done, failed, canceled };

/// Shared between the job thread and the UI. Plain fields are written by the
/// job before it publishes a later phase (release) and read by the UI after
/// observing that phase (acquire).
pub const Status = struct {
    phase_raw: std.atomic.Value(u8) = .init(@intFromEnum(Phase.starting)),
    cancel: std.atomic.Value(bool) = .init(false),
    done_steps: std.atomic.Value(u64) = .init(0),
    current_chain: std.atomic.Value(u32) = .init(0),
    lane_done: [max_lanes]std.atomic.Value(u64) = @splat(.init(0)),

    is_lock: bool = true,
    /// RandomX mode and how its main memory is backed (set before `hashing`).
    mode: puzzle.Mode = .fast,
    /// Light mode was asked for rather than forced by low RAM.
    light_requested: bool = false,
    pages: puzzle.BenchPages = .none,
    /// This run measured the machine's speed (a new timed lock).
    benchmarked: bool = false,
    /// Why the lock uses this many threads (miners' rule), shown to the user.
    threads_note_buf: [200]u8 = undefined,
    threads_note_len: usize = 0,
    chains: u32 = 0,
    iterations: u64 = 0,
    total_steps: u64 = 0,
    resumed_steps: u64 = 0,
    /// Lock threads asked for, and how many fit in free RAM (`avail_kib`).
    requested_threads: u32 = 0,
    ram_threads: u32 = 0,
    avail_kib: u64 = 0,
    /// A `.lockstate` file exists for this lock (so pausing keeps progress).
    lock_state_saved: bool = false,
    /// Single-thread steps/s × 1000 used for the estimate.
    rate_millis: u64 = 0,
    message_buf: [1024]u8 = undefined,
    message_len: usize = 0,

    pub fn phase(self: *const Status) Phase {
        return @enumFromInt(self.phase_raw.load(.acquire));
    }

    pub fn setPhase(self: *Status, p: Phase) void {
        self.phase_raw.store(@intFromEnum(p), .release);
    }

    pub fn message(self: *const Status) []const u8 {
        return self.message_buf[0..self.message_len];
    }

    fn finish(self: *Status, p: Phase, comptime fmt: []const u8, args: anytype) void {
        const m = std.fmt.bufPrint(&self.message_buf, fmt, args) catch blk: {
            const tail = "…";
            @memcpy(self.message_buf[self.message_buf.len - tail.len ..], tail);
            break :blk self.message_buf[0..];
        };
        self.message_len = m.len;
        self.setPhase(p);
    }

    /// Explains a lock running on fewer threads than requested because of
    /// free RAM, or null when it isn't.
    pub fn threadNote(self: *const Status, buf: []u8) ?[]const u8 {
        if (!self.is_lock or self.ram_threads >= self.requested_threads) return null;
        var b: [32]u8 = undefined;
        return std.fmt.bufPrint(buf, "Using {d} of {d} threads: that is all that fits in free RAM ({s} free).", .{
            self.ram_threads,
            self.requested_threads,
            util.fmtSizeKib(&b, self.avail_kib),
        }) catch null;
    }

    /// How the thread count was chosen, or null.
    pub fn threadsChoiceNote(self: *const Status) ?[]const u8 {
        return if (self.threads_note_len > 0) self.threads_note_buf[0..self.threads_note_len] else null;
    }

    /// Warnings about RandomX's mode and pages, or null when there are none.
    pub fn speedNote(self: *const Status) ?[]const u8 {
        if (self.mode == .light and self.light_requested)
            return "Light mode as requested: several times slower than fast mode.";
        if (self.mode == .light) return if (self.is_lock)
            "Not enough free RAM for RandomX's 2 GiB dataset, so this runs in light mode, several times slower."
        else
            "Not enough free RAM for RandomX's 2 GiB dataset, so unlocking runs in light mode, several times slower. About 2.4 GiB free makes it fast.";
        if (self.is_lock and self.benchmarked and self.pages != .explicit and self.pages != .none)
            return "The dataset is not on explicit huge pages, so this machine hashes up to ~45% slower than one with them, and the lock may open sooner than requested. For accurate timing reserve them first: sudo sysctl vm.nr_hugepages=1250";
        return null;
    }

    pub fn requestCancel(self: *Status) void {
        self.cancel.store(true, .monotonic);
    }

    pub fn isFinished(self: *const Status) bool {
        return switch (self.phase()) {
            .done, .failed, .canceled => true,
            else => false,
        };
    }
};

pub const LockOptions = struct {
    path: []const u8,
    seconds: u64,
    /// 0 = automatic.
    threads: u32 = 0,
    /// Skip benchmarking and use exactly this many total steps.
    steps: ?u64 = null,
    output: ?[]const u8 = null,
    remove_original: bool = false,
    force: bool = false,
};

pub const UnlockOptions = struct {
    path: []const u8,
    output: ?[]const u8 = null,
    force: bool = false,
    /// Use RandomX light mode even when the dataset would fit.
    light: bool = false,
};

// ---------------------------------------------------------------------------

/// Measures single-thread steps per second × 1000 on `engine`.
pub fn benchmark(engine: *const puzzle.Engine, io: Io, cancel: ?*const std.atomic.Value(bool)) !u64 {
    var s = try engine.stepper();
    defer s.deinit();
    var x: puzzle.Hash = @splat(0);
    // Warm-up steps, so first-touch page faults are not counted.
    for (0..3) |k| s.step(&x, 0, k);
    const start = util.nowNs(io);
    var steps: u64 = 0;
    var elapsed: i96 = 0;
    while (elapsed < bench_ns or steps < bench_min_steps) {
        if (cancel) |c| if (c.load(.monotonic)) return error.Canceled;
        s.step(&x, 0, steps + 3);
        steps += 1;
        elapsed = util.nowNs(io) - start;
    }
    const rate = @as(u128, steps) * 1000 * std.time.ns_per_s / @as(u128, @intCast(elapsed));
    return @intCast(@max(rate, 1));
}

/// Fast mode if the dataset (plus `threads` VMs) fits in free RAM.
pub fn chooseMode(io: Io, threads: u32) puzzle.Mode {
    const avail_kib = util.availableMemKib(io, puzzle.dataset_huge_pages) orelse return .fast;
    const need = puzzle.fast_mode_bytes + @as(u64, threads) * puzzle.per_thread_bytes + ram_margin_bytes;
    return if (avail_kib * 1024 >= need) .fast else .light;
}

/// Threads whose VMs fit next to the mode's shared memory.
fn threadsThatFit(io: Io, mode: puzzle.Mode, wanted: u32, st: *Status) !u32 {
    const avail_kib = util.availableMemKib(io, puzzle.dataset_huge_pages) orelse return wanted;
    st.avail_kib = avail_kib;
    const base = (if (mode == .fast) puzzle.fast_mode_bytes else puzzle.light_mode_bytes) + ram_margin_bytes;
    const avail = avail_kib * 1024;
    if (avail < base + puzzle.per_thread_bytes) return error.NotEnoughMemory;
    return @intCast(@min(wanted, (avail - base) / puzzle.per_thread_bytes));
}

/// The automatic lock thread count, following the RandomX miners' rule: one
/// thread per physical core, and at most one per 2 MiB of L3 cache, since each
/// thread's 2 MiB scratchpad should stay in L3. Hyperthreads and threads that
/// spill out of L3 add little speed but plenty of heat.
pub const AutoThreads = struct {
    threads: u32,
    topology: util.CpuTopology,

    /// Why this CPU suits `threads` threads, e.g. "2 physical cores and 3 MiB
    /// of L3 cache, which fits 1 RandomX scratchpad (2 MiB each)".
    pub fn reason(self: AutoThreads, buf: []u8) []const u8 {
        const t = self.topology;
        var b: [32]u8 = undefined;
        if (t.physical == null or t.l3_bytes == null)
            return std.fmt.bufPrint(buf, "CPU cache size unknown, so one per CPU, up to {d}", .{fallback_max_threads}) catch "";
        return std.fmt.bufPrint(buf, "{d} physical core{s} and {s} of L3 cache, which fits {d} RandomX scratchpad{s} (2 MiB each)", .{
            t.physical.?,
            if (t.physical.? == 1) "" else "s",
            util.fmtSizeKib(&b, t.l3_bytes.? / 1024),
            t.l3_bytes.? / scratchpad_bytes,
            if (t.l3_bytes.? / scratchpad_bytes == 1) "" else "s",
        }) catch "";
    }
};

const scratchpad_bytes = 2 * 1024 * 1024;
const fallback_max_threads = 8;

pub fn autoThreads(io: Io) AutoThreads {
    const t = util.cpuTopology(io);
    const n: u64 = if (t.physical != null and t.l3_bytes != null)
        @min(t.physical.?, t.l3_bytes.? / scratchpad_bytes)
    else
        @min(t.logical, fallback_max_threads);
    return .{ .threads = @intCast(std.math.clamp(n, 1, max_lanes)), .topology = t };
}

/// Reminder to give reserved huge pages back once a job is done, or "".
fn hugePageReminder(io: Io, buf: []u8) []const u8 {
    const total = util.totalHugePages(io);
    if (total == 0) return "";
    return std.fmt.bufPrint(buf, "\n{d} huge pages ({d} MiB) are still reserved. Release them when you're done: sudo sysctl vm.nr_hugepages=0", .{ total, total * 2 }) catch "";
}

pub fn describeError(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "file not found",
        error.AccessDenied, error.PermissionDenied => "permission denied",
        error.IsDir, error.NotAFile => "not a regular file",
        error.OutputExists => "output file already exists (use --force to overwrite or -o to pick another name)",
        error.NotEnoughMemory => "not enough free RAM (RandomX needs about 2.4 GiB, or 300 MiB in light mode)",
        error.NeedFastModeForTimedLock => "timed locks need about 2.4 GiB of free RAM for RandomX's dataset, so the speed measurement matches a fast unlocker; free some memory, or give an explicit --steps",
        error.AesNotSupported => "this CPU has no hardware AES, which RandomX requires",
        error.OutOfMemory => "out of memory",
        error.NotAYuzuFile => "not a yuzu file",
        error.UnsupportedVersion => "file was made by an unsupported yuzu version",
        error.CorruptHeader, error.CorruptFile, error.Truncated, error.TrailingData => "file is corrupt or truncated",
        error.ChainCheckFailed => "chain verification failed (corrupt file or bad checkpoint; delete the .progress file to restart)",
        error.WrongKeyOrCorrupt => "decryption failed: file is corrupt or was modified",
        error.Canceled => "canceled",
        error.LockStateMismatch => "an unfinished lock of a different input already uses this output name (use -o, or delete its .lockstate file)",
        error.CorruptLockState => "the saved lock progress is corrupt; delete the .lockstate file to start over",
        error.SelfTestFailed => "RandomX self-test failed: this build does not hash correctly (run `yuzu selftest`)",
        else => @errorName(err),
    };
}

// ---------------------------------------------------------------------------
// Lock
// ---------------------------------------------------------------------------

pub fn runLock(gpa: std.mem.Allocator, io: Io, opts: LockOptions, st: *Status) void {
    st.is_lock = true;
    lockImpl(gpa, io, opts, st) catch |err| {
        var sp_buf: [std.fs.max_path_bytes]u8 = undefined;
        const sp = lockStatePath(&sp_buf, opts) catch "the .lockstate file";
        if (err == error.Canceled and st.lock_state_saved)
            st.finish(.canceled, "Paused. Lock progress saved to {s}; run the same lock command again to resume.\nThat file holds the secret seeds: anyone who copies it can skip the work. Delete it to abandon the lock.", .{sp})
        else if (err == error.Canceled)
            st.finish(.canceled, "Lock canceled. Nothing was written.", .{})
        else if (st.lock_state_saved)
            st.finish(.failed, "Lock failed: {s}\nProgress is saved in {s}; fix the problem and run the same lock command to resume.", .{ describeError(err), sp })
        else
            st.finish(.failed, "Lock failed: {s}", .{describeError(err)});
    };
}

fn outputPath(buf: []u8, o: LockOptions) ![]const u8 {
    return o.output orelse try std.fmt.bufPrint(buf, "{s}.yuzu", .{o.path});
}

/// Where an unfinished lock of `o` keeps its progress.
pub fn lockStatePath(buf: []u8, o: LockOptions) ![]const u8 {
    var out_buf: [std.fs.max_path_bytes]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}.lockstate", .{try outputPath(&out_buf, o)});
}

const lock_save_interval_ns: i96 = 10 * std.time.ns_per_s;

/// One chain's progress, shared between its worker and the checkpointer.
const LaneSnap = struct {
    busy: std.atomic.Value(bool) = .init(false),
    index: u64,
    state: puzzle.Hash,

    fn acquire(self: *LaneSnap) void {
        while (self.busy.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }
    fn release(self: *LaneSnap) void {
        self.busy.store(false, .release);
    }
    fn set(self: *LaneSnap, index: u64, state: puzzle.Hash) void {
        self.acquire();
        defer self.release();
        self.index = index;
        self.state = state;
    }
    fn get(self: *LaneSnap) struct { u64, puzzle.Hash } {
        self.acquire();
        defer self.release();
        return .{ self.index, self.state };
    }
};

const Pool = struct {
    engine: *const puzzle.Engine,
    st: *Status,
    iterations: u64,
    lanes: []LaneSnap,
    next: std.atomic.Value(u32) = .init(0),
    finished: std.atomic.Value(u32) = .init(0),
};

fn lockImpl(gpa: std.mem.Allocator, io: Io, o: LockOptions, st: *Status) !void {
    // A lock made with a miscomputing hash could never be opened.
    try selftest.check(gpa, io);
    const cwd = Io.Dir.cwd();
    const stat = try cwd.statFile(io, o.path, .{});
    if (stat.kind != .file) return error.NotAFile;

    var out_buf: [std.fs.max_path_bytes]u8 = undefined;
    const out_path = try outputPath(&out_buf, o);
    // Fail now rather than after hours of hashing.
    if (!o.force and util.exists(io, out_path)) return error.OutputExists;
    var sp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const state_path = try lockStatePath(&sp_buf, o);

    // Resume an unfinished lock of this file, or start a new one.
    var ls: lockstate.LockState = undefined;
    var have_ls = false;
    defer if (have_ls) ls.deinit(gpa);
    var resumed = false;
    if (cwd.readFileAlloc(io, state_path, gpa, .limited(16 * 1024 * 1024))) |data| {
        defer {
            std.crypto.secureZero(u8, data);
            gpa.free(data);
        }
        ls = try lockstate.LockState.decode(gpa, data);
        have_ls = true;
        if (!std.mem.eql(u8, ls.input, o.path)) return error.LockStateMismatch;
        resumed = true;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    // All threads share one RandomX dataset; each adds only a VM.
    const auto = autoThreads(io);
    var threads: u32 = if (o.threads == 0) auto.threads else @min(o.threads, max_lanes);
    {
        var rb: [160]u8 = undefined;
        const note = if (o.threads == 0)
            std.fmt.bufPrint(&st.threads_note_buf, "Auto picks {d} thread{s}: {s}.", .{ auto.threads, if (auto.threads == 1) "" else "s", auto.reason(&rb) }) catch ""
        else if (threads > auto.threads)
            std.fmt.bufPrint(&st.threads_note_buf, "{d} threads requested, but this CPU suits {d}: {s}. Extra threads add little speed.", .{ threads, auto.threads, auto.reason(&rb) }) catch ""
        else
            "";
        st.threads_note_len = note.len;
    }
    st.requested_threads = threads;
    const mode = chooseMode(io, threads);
    // A light-mode benchmark would be several times too slow, making every
    // timed lock far too short for anyone unlocking in fast mode.
    if (mode == .light and !resumed and o.steps == null) return error.NeedFastModeForTimedLock;
    threads = try threadsThatFit(io, mode, threads, st);
    st.ram_threads = threads;
    st.mode = mode;

    var salt: [16]u8 = undefined;
    if (resumed) salt = ls.salt else io.random(&salt);
    st.setPhase(.preparing);
    var engine = try puzzle.Engine.init(gpa, salt, mode, std.Thread.getCpuCount() catch 1);
    defer engine.deinit();
    st.pages = engine.pages();

    if (!resumed) {
        var rate: u64 = 0;
        var total: u64 = undefined;
        var bench_pages: puzzle.BenchPages = .none;
        if (o.steps) |s| {
            total = @max(s, 1);
        } else {
            st.setPhase(.benchmarking);
            rate = try benchmark(&engine, io, &st.cancel);
            bench_pages = engine.pages();
            st.benchmarked = true;
            total = @max(1, std.math.divCeil(u64, o.seconds * rate, 1000) catch unreachable);
        }
        const chains: u32 = @intCast(@min(threads, total));
        const input = try gpa.dupe(u8, o.path);
        errdefer if (!have_ls) gpa.free(input);
        const chain_list = try gpa.alloc(lockstate.Chain, chains);
        ls = .{
            .bench_pages = @intFromEnum(bench_pages),
            .iterations = std.math.divCeil(u64, total, chains) catch unreachable,
            .target_seconds = o.seconds,
            .rate_millis = rate,
            .created = @intCast(Io.Clock.real.now(io).toSeconds()),
            .salt = salt,
            .input = input,
            .chains = chain_list,
        };
        have_ls = true;
        for (ls.chains) |*c| {
            io.random(&c.seed);
            c.state = c.seed;
            c.index = 0;
        }
        try saveLockState(gpa, io, state_path, ls);
        st.lock_state_saved = true;
    } else {
        st.lock_state_saved = true;
        st.resumed_steps = ls.doneSteps();
    }

    const chains: u32 = @intCast(ls.chains.len);
    const iterations = ls.iterations;
    threads = @min(threads, chains);
    st.chains = chains;
    st.iterations = iterations;
    st.total_steps = iterations * chains;
    st.rate_millis = ls.rate_millis;
    st.done_steps.store(st.resumed_steps, .monotonic);
    for (ls.chains, 0..) |c, j| st.lane_done[j].store(c.index, .monotonic);
    st.setPhase(.hashing);

    // Threads take chains from a queue, so a resumed lock can use fewer
    // threads than it started with.
    const lanes = try gpa.alloc(LaneSnap, chains);
    defer {
        std.crypto.secureZero(u8, std.mem.sliceAsBytes(lanes));
        gpa.free(lanes);
    }
    for (lanes, ls.chains) |*l, c| l.* = .{ .index = c.index, .state = c.state };
    var pool: Pool = .{ .engine = &engine, .st = st, .iterations = iterations, .lanes = lanes };

    const errs = try gpa.alloc(?anyerror, threads);
    defer gpa.free(errs);
    @memset(errs, null);
    const handles = try gpa.alloc(std.Thread, threads);
    defer gpa.free(handles);
    var spawned: u32 = 0;
    defer for (handles[0..spawned]) |h| h.join();
    for (0..threads) |t| {
        handles[t] = std.Thread.spawn(.{}, poolWorker, .{ &pool, &errs[t] }) catch |err| {
            st.requestCancel();
            return err;
        };
        spawned += 1;
    }

    // Checkpoint while the workers run.
    var last_save = util.nowNs(io);
    while (pool.finished.load(.acquire) < spawned) {
        io.sleep(.fromMilliseconds(200), .awake) catch {};
        if (util.nowNs(io) - last_save >= lock_save_interval_ns) {
            snapshot(&ls, lanes);
            saveLockState(gpa, io, state_path, ls) catch {};
            last_save = util.nowNs(io);
        }
    }
    for (handles[0..spawned]) |h| h.join();
    spawned = 0;

    snapshot(&ls, lanes);
    try saveLockState(gpa, io, state_path, ls);
    for (errs) |e| if (e) |err| return err;
    if (st.cancel.load(.monotonic)) return error.Canceled;

    // Chain j's output hides chain j+1's seed.
    var header: puzzle.Header = .{
        .bench_pages = @enumFromInt(ls.bench_pages),
        .chains = chains,
        .iterations = iterations,
        .target_seconds = ls.target_seconds,
        .rate_millis = ls.rate_millis,
        .created = ls.created,
        .salt = ls.salt,
        .seed = ls.chains[0].seed,
        .nonce_prefix = undefined,
        .chunk_size = puzzle.default_chunk_size,
        .links = try gpa.alloc(puzzle.Hash, chains - 1),
        .checks = try gpa.alloc(puzzle.Check, chains),
    };
    defer header.deinit(gpa);
    io.random(&header.nonce_prefix);
    for (header.links, 0..) |*l, j| l.* = puzzle.xorHash(ls.chains[j + 1].seed, puzzle.linkKey(ls.salt, ls.chains[j].state));
    for (header.checks, ls.chains) |*c, ch| c.* = puzzle.checkValue(ls.salt, ch.state);
    var key = puzzle.fileKey(ls.salt, ls.chains[chains - 1].state);
    defer std.crypto.secureZero(u8, &key);

    st.setPhase(.writing);
    const encoded = try header.encode(gpa);
    defer gpa.free(encoded);
    const ad = puzzle.digest(encoded);

    var in_file = try cwd.openFile(io, o.path, .{});
    defer in_file.close(io);
    var in_buf: [64 * 1024]u8 = undefined;
    var in_reader = in_file.reader(io, &in_buf);

    var af = try cwd.createFileAtomic(io, out_path, .{ .replace = o.force });
    defer af.deinit(io);
    var w_buf: [64 * 1024]u8 = undefined;
    var fw = af.file.writer(io, &w_buf);
    fw.interface.writeAll(encoded) catch return fw.err.?;
    puzzle.encryptStream(gpa, key, header, ad, std.fs.path.basename(o.path), &in_reader.interface, &fw.interface) catch |err| switch (err) {
        error.ReadFailed => return in_reader.err.?,
        error.WriteFailed => return fw.err.?,
        else => return err,
    };
    fw.interface.flush() catch return fw.err.?;
    if (o.force) try af.replace(io) else af.link(io) catch |err| switch (err) {
        error.PathAlreadyExists => return error.OutputExists,
        else => return err,
    };

    // The seeds must not outlive the lock.
    cwd.deleteFile(io, state_path) catch {};
    st.lock_state_saved = false;
    if (o.remove_original) try cwd.deleteFile(io, o.path);

    var d_buf: [64]u8 = undefined;
    var e_buf: [32]u8 = undefined;
    var n_buf: [160]u8 = undefined;
    const note = if (st.threadNote(n_buf[1..])) |n| blk: {
        n_buf[0] = '\n';
        break :blk n_buf[0 .. n.len + 1];
    } else "";
    const est = if (ls.rate_millis > 0)
        try std.fmt.bufPrint(&d_buf, "≈ {s}", .{util.fmtDuration(&e_buf, st.total_steps * 1000 / ls.rate_millis)})
    else
        try std.fmt.bufPrint(&d_buf, "{d} steps", .{st.total_steps});
    const speed_note = if (ls.bench_pages != @intFromEnum(puzzle.BenchPages.explicit) and ls.bench_pages != @intFromEnum(puzzle.BenchPages.none))
        "\nMeasured without explicit huge pages: a machine with them unlocks up to ~45% sooner."
    else
        "";
    var hp_buf: [160]u8 = undefined;
    const reminder = hugePageReminder(io, &hp_buf);
    st.finish(.done, "Locked → {s}\n{d} chain{s} × {d} RandomX steps.\nUnlocking needs {s} of one CPU core and about 2.4 GiB of RAM.{s}{s}{s}{s}", .{
        out_path,
        chains,
        if (chains == 1) "" else "s",
        iterations,
        est,
        speed_note,
        note,
        if (o.remove_original) "\nThe original file was deleted." else "\nThe original file was kept; delete it yourself if you want it gone.",
        reminder,
    });
}

fn snapshot(ls: *lockstate.LockState, lanes: []LaneSnap) void {
    for (ls.chains, lanes) |*c, *l| {
        c.index, c.state = l.get();
    }
}

fn saveLockState(gpa: std.mem.Allocator, io: Io, path: []const u8, ls: lockstate.LockState) !void {
    const data = try ls.encode(gpa);
    defer {
        std.crypto.secureZero(u8, data);
        gpa.free(data);
    }
    try util.writeFileAtomic(io, path, data);
}

fn poolWorker(pool: *Pool, err_out: *?anyerror) void {
    const st = pool.st;
    defer _ = pool.finished.fetchAdd(1, .release);
    var s = pool.engine.stepper() catch |err| {
        err_out.* = err;
        st.requestCancel();
        return;
    };
    defer s.deinit();
    while (true) {
        const j = pool.next.fetchAdd(1, .monotonic);
        if (j >= pool.lanes.len) return;
        var i, var x = pool.lanes[j].get();
        defer std.crypto.secureZero(u8, &x);
        while (i < pool.iterations) : (i += 1) {
            if (st.cancel.load(.monotonic)) return;
            s.step(&x, j, i);
            pool.lanes[j].set(i + 1, x);
            st.lane_done[j].store(i + 1, .monotonic);
            _ = st.done_steps.fetchAdd(1, .monotonic);
        }
    }
}

// ---------------------------------------------------------------------------
// Unlock
// ---------------------------------------------------------------------------

pub fn runUnlock(gpa: std.mem.Allocator, io: Io, opts: UnlockOptions, st: *Status) void {
    st.is_lock = false;
    unlockImpl(gpa, io, opts, st) catch |err| {
        if (err == error.Canceled)
            st.finish(.canceled, "Paused. Progress saved to {s}.progress — run unlock again to resume.", .{opts.path})
        else
            st.finish(.failed, "Unlock failed: {s}", .{describeError(err)});
    };
}

fn unlockImpl(gpa: std.mem.Allocator, io: Io, o: UnlockOptions, st: *Status) !void {
    try selftest.check(gpa, io);
    const cwd = Io.Dir.cwd();
    var file = try cwd.openFile(io, o.path, .{});
    defer file.close(io);
    var r_buf: [64 * 1024]u8 = undefined;
    var fr = file.reader(io, &r_buf);
    const r = &fr.interface;

    var raw: []u8 = undefined;
    var h = puzzle.Header.read(gpa, r, &raw) catch |err| switch (err) {
        error.ReadFailed => return fr.err.?,
        else => return err,
    };
    defer h.deinit(gpa);
    defer gpa.free(raw);
    const ad = puzzle.digest(raw);

    const mode: puzzle.Mode = if (o.light) .light else chooseMode(io, 1);
    if (util.availableMemKib(io, puzzle.dataset_huge_pages)) |avail| {
        if (avail * 1024 < puzzle.light_mode_bytes + puzzle.per_thread_bytes + ram_margin_bytes) return error.NotEnoughMemory;
    }

    var prog_buf: [std.fs.max_path_bytes]u8 = undefined;
    const prog_path = try std.fmt.bufPrint(&prog_buf, "{s}.progress", .{o.path});

    // Resume from a checkpoint when one exists for this exact file.
    var cp: puzzle.Checkpoint = .{ .file_digest = ad, .chain = 0, .index = 0, .state = h.seed };
    {
        var buf: [puzzle.progress_len + 1]u8 = undefined;
        if (cwd.readFile(io, prog_path, &buf)) |data| {
            if (puzzle.Checkpoint.decode(data)) |saved| {
                if (std.mem.eql(u8, &saved.file_digest, &ad) and saved.chain < h.chains and saved.index <= h.iterations)
                    cp = saved;
            }
        } else |_| {}
    }

    st.chains = h.chains;
    st.iterations = h.iterations;
    st.total_steps = h.totalSteps();
    st.rate_millis = h.rate_millis;
    st.resumed_steps = @as(u64, cp.chain) * h.iterations + cp.index;
    st.done_steps.store(st.resumed_steps, .monotonic);
    st.current_chain.store(cp.chain, .monotonic);
    st.mode = mode;
    st.light_requested = o.light;
    st.setPhase(.preparing);
    var engine = try puzzle.Engine.init(gpa, h.salt, mode, std.Thread.getCpuCount() catch 1);
    defer engine.deinit();
    st.pages = engine.pages();
    var stepper = try engine.stepper();
    defer stepper.deinit();
    st.setPhase(.hashing);

    var j = cp.chain;
    var i = cp.index;
    var x = cp.state;
    defer std.crypto.secureZero(u8, &x);
    var last_save = util.nowNs(io);

    while (true) {
        while (i < h.iterations) : (i += 1) {
            if (st.cancel.load(.monotonic)) {
                try saveCheckpoint(io, prog_path, ad, j, i, x);
                return error.Canceled;
            }
            stepper.step(&x, j, i);
            _ = st.done_steps.fetchAdd(1, .monotonic);
            const now = util.nowNs(io);
            if (now - last_save >= checkpoint_interval_ns) {
                try saveCheckpoint(io, prog_path, ad, j, i + 1, x);
                last_save = now;
            }
        }
        if (!std.mem.eql(u8, &puzzle.checkValue(h.salt, x), &h.checks[j])) return error.ChainCheckFailed;
        if (j + 1 == h.chains) break;
        x = puzzle.xorHash(h.links[j], puzzle.linkKey(h.salt, x));
        j += 1;
        i = 0;
        st.current_chain.store(j, .monotonic);
        try saveCheckpoint(io, prog_path, ad, j, 0, x);
        last_save = util.nowNs(io);
    }
    // Keep the solved state so a failed write can be retried instantly.
    try saveCheckpoint(io, prog_path, ad, j, h.iterations, x);

    var key = puzzle.fileKey(h.salt, x);
    defer std.crypto.secureZero(u8, &key);

    st.setPhase(.writing);
    var name_buf: [puzzle.max_name_len]u8 = undefined;
    const stored = puzzle.decryptName(key, h, ad, r, &name_buf) catch |err| switch (err) {
        error.ReadFailed => return fr.err.?,
        error.EndOfStream => return error.Truncated,
        else => return err,
    };
    var name = std.fs.path.basename(stored);
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) name = "unlocked";

    var out_buf: [std.fs.max_path_bytes]u8 = undefined;
    const out_path = o.output orelse if (std.fs.path.dirname(o.path)) |dir|
        try std.fmt.bufPrint(&out_buf, "{s}/{s}", .{ dir, name })
    else
        name;
    if (!o.force and util.exists(io, out_path)) return error.OutputExists;

    var af = try cwd.createFileAtomic(io, out_path, .{ .replace = o.force, .permissions = .fromMode(0o600) });
    defer af.deinit(io);
    var w_buf: [64 * 1024]u8 = undefined;
    var fw = af.file.writer(io, &w_buf);
    puzzle.decryptData(gpa, key, h, ad, r, &fw.interface) catch |err| switch (err) {
        error.ReadFailed => return fr.err.?,
        error.WriteFailed => return fw.err.?,
        else => return err,
    };
    fw.interface.flush() catch return fw.err.?;
    if (o.force) try af.replace(io) else af.link(io) catch |err| switch (err) {
        error.PathAlreadyExists => return error.OutputExists,
        else => return err,
    };

    cwd.deleteFile(io, prog_path) catch {};
    var hp_buf: [160]u8 = undefined;
    st.finish(.done, "Unlocked → {s}{s}", .{ out_path, hugePageReminder(io, &hp_buf) });
}

fn saveCheckpoint(io: Io, path: []const u8, digest: puzzle.Hash, chain: u32, index: u64, state: puzzle.Hash) !void {
    const cp: puzzle.Checkpoint = .{ .file_digest = digest, .chain = chain, .index = index, .state = state };
    var data = cp.encode();
    defer std.crypto.secureZero(u8, &data);
    try util.writeFileAtomic(io, path, &data);
}
