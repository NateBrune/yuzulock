const std = @import("std");
const Io = std.Io;
const zz = @import("zigzag");
const engine = @import("engine.zig");
const puzzle = @import("puzzle.zig");
const tui = @import("tui.zig");
const util = @import("util.zig");
const selftest = @import("selftest.zig");

const version = "0.1.0";

const usage =
    \\yuzu — lock files for a span of time with sequential RandomX hashing
    \\
    \\Usage:
    \\  yuzu                                   interactive mode
    \\  yuzu lock <file> -t <duration> [opts]  lock a file → <file>.yuzu
    \\  yuzu unlock <file.yuzu> [opts]         solve the puzzle and restore the file
    \\  yuzu <file.yuzu>                       same as unlock, with plain text progress
    \\  yuzu info <file.yuzu> [--bench]        show a locked file's parameters
    \\  yuzu bench                             measure this machine's hashing speed
    \\  yuzu selftest                          check RandomX against its official test vectors
    \\
    \\Lock options:
    \\  -t, --time <duration>   how long unlocking should take: 90s, 30m, 2h, 1d12h, 1w
    \\  -j, --threads <n>       threads used while locking (default: physical cores,
    \\                          at most one per 2 MiB of L3 cache, the RandomX miners' rule)
    \\      --steps <n>         use exactly n total steps instead of benchmarking
    \\      --remove            delete the original after a successful lock
    \\
    \\Unlock options:
    \\      --light             use RandomX light mode (300 MiB, several times slower)
    \\
    \\Common options:
    \\  -o, --output <path>     output file
    \\  -f, --force             overwrite the output if it exists
    \\      --plain             plain text progress instead of the TUI
    \\  -h, --help              show this help
    \\  -V, --version           show the version
    \\
    \\Each step is a RandomX v2 hash (the algorithm Monero mines with), which
    \\is built so that ordinary CPUs are close to the fastest possible hardware.
    \\
    \\RAM: about 2.4 GiB, the same for locking and unlocking: every thread shares
    \\one 2 GiB dataset and adds only 2 MiB. With less free RAM, unlocking falls
    \\back to light mode (300 MiB, several times slower). Timed locks always
    \\measure in fast mode.
    \\
    \\Huge pages make RandomX about 45% faster, and anyone racing a lock will use
    \\them. Reserve them before locking so the timing matches:
    \\  sudo sysctl vm.nr_hugepages=1250      (sudo sysctl vm.nr_hugepages=0 to release)
    \\
    \\Locking spreads the work over several threads. Unlocking has to replay
    \\every chain in order on one thread, so it takes about the requested time
    \\on a machine like this one.
    \\
    \\Both can be paused (q or Ctrl+C) and resumed by running the same command
    \\again. Unlock progress is kept in <file>.yuzu.progress. Lock progress is
    \\kept in <file>.yuzu.lockstate, which holds the secret seeds: anyone who
    \\copies it can skip the work, so it's owner-only and deleted when the
    \\lock finishes.
    \\
;

const Command = enum { interactive, lock, unlock, info, bench, selftest, help, version };

const Args = struct {
    command: Command = .interactive,
    positional: ?[]const u8 = null,
    time: ?[]const u8 = null,
    threads: ?[]const u8 = null,
    steps: ?[]const u8 = null,
    output: ?[]const u8 = null,
    force: bool = false,
    remove: bool = false,
    plain: bool = false,
    bench: bool = false,
    light: bool = false,
};

fn parseArgs(argv: []const [:0]const u8) !Args {
    var a: Args = .{};
    var i: usize = 1;
    if (argv.len > 1) {
        const c = argv[1];
        if (std.mem.eql(u8, c, "lock")) {
            a.command = .lock;
            i = 2;
        } else if (std.mem.eql(u8, c, "unlock")) {
            a.command = .unlock;
            i = 2;
        } else if (std.mem.eql(u8, c, "info")) {
            a.command = .info;
            i = 2;
        } else if (std.mem.eql(u8, c, "bench")) {
            a.command = .bench;
            i = 2;
        } else if (std.mem.eql(u8, c, "selftest")) {
            a.command = .selftest;
            i = 2;
        } else if (std.mem.eql(u8, c, "help")) {
            a.command = .help;
            return a;
        } else if (std.mem.endsWith(u8, c, ".yuzu")) {
            // `yuzu file.yuzu` is shorthand for a plain-text unlock.
            a.command = .unlock;
            a.positional = c;
            a.plain = true;
            i = 2;
        }
    }
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        const eql = struct {
            fn f(x: []const u8, short: []const u8, long: []const u8) bool {
                return (short.len > 0 and std.mem.eql(u8, x, short)) or std.mem.eql(u8, x, long);
            }
        }.f;
        if (eql(arg, "-h", "--help")) {
            a.command = .help;
            return a;
        } else if (eql(arg, "-V", "--version")) {
            a.command = .version;
            return a;
        } else if (eql(arg, "-f", "--force")) {
            a.force = true;
        } else if (eql(arg, "", "--remove")) {
            a.remove = true;
        } else if (eql(arg, "", "--plain")) {
            a.plain = true;
        } else if (eql(arg, "", "--bench")) {
            a.bench = true;
        } else if (eql(arg, "", "--light")) {
            a.light = true;
        } else if (eql(arg, "-t", "--time") or eql(arg, "-j", "--threads") or
            eql(arg, "-o", "--output") or eql(arg, "", "--steps"))
        {
            i += 1;
            if (i >= argv.len) return fail("missing value for {s}", .{arg});
            const v = argv[i];
            if (eql(arg, "-t", "--time")) a.time = v else if (eql(arg, "-j", "--threads")) a.threads = v else if (eql(arg, "-o", "--output")) a.output = v else a.steps = v;
        } else if (arg.len > 1 and arg[0] == '-') {
            return fail("unknown option {s}", .{arg});
        } else if (a.positional == null) {
            a.positional = arg;
        } else {
            return fail("unexpected argument {s}", .{arg});
        }
    }
    if (a.command == .interactive and a.positional != null)
        return fail("unknown command {s} (try yuzu --help)", .{a.positional.?});
    return a;
}

var fail_buf: [512]u8 = undefined;
var fail_msg: []const u8 = "";

fn fail(comptime fmt: []const u8, args: anytype) error{Usage} {
    fail_msg = std.fmt.bufPrint(&fail_buf, fmt, args) catch fmt;
    return error.Usage;
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var out_buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &out_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};
    var err_buf: [1024]u8 = undefined;
    var stderr = Io.File.stderr().writer(io, &err_buf);
    const err = &stderr.interface;
    defer err.flush() catch {};

    const args = parseArgs(argv) catch {
        try err.print("yuzu: {s}\n", .{fail_msg});
        return 2;
    };

    return run(gpa, io, init.environ_map, args, out, err) catch |e| switch (e) {
        error.Usage => {
            try err.print("yuzu: {s}\n", .{fail_msg});
            return 2;
        },
        else => {
            try err.print("yuzu: {s}\n", .{engine.describeError(e)});
            return 1;
        },
    };
}

fn run(gpa: std.mem.Allocator, io: Io, env: *std.process.Environ.Map, a: Args, out: *Io.Writer, err: *Io.Writer) !u8 {
    switch (a.command) {
        .help => {
            try out.writeAll(usage);
            return 0;
        },
        .version => {
            try out.print("yuzu {s}\n", .{version});
            return 0;
        },
        .info => return info(gpa, io, a, out),
        .bench => return bench(gpa, io, out),
        .selftest => return runSelftest(gpa, io, out),
        .interactive => return runUi(gpa, io, env, null, out),
        .lock => {
            const path = a.positional orelse return fail("lock needs a file", .{});
            if (a.time == null and a.steps == null) return fail("lock needs a duration, e.g. -t 2h", .{});
            var o: engine.LockOptions = .{
                .path = path,
                .seconds = if (a.time) |t| util.parseDuration(t) catch return fail("invalid duration '{s}'", .{t}) else 0,
                .output = a.output,
                .force = a.force,
                .remove_original = a.remove,
            };
            if (a.threads) |t| {
                o.threads = std.fmt.parseInt(u32, t, 10) catch return fail("invalid thread count '{s}'", .{t});
                if (o.threads == 0 or o.threads > engine.max_lanes) return fail("threads must be 1–{d}", .{engine.max_lanes});
            }
            if (a.steps) |s| o.steps = std.fmt.parseInt(u64, s, 10) catch return fail("invalid step count '{s}'", .{s});
            return dispatch(gpa, io, env, a, .{ .lock = o }, out, err);
        },
        .unlock => {
            const path = a.positional orelse return fail("unlock needs a .yuzu file", .{});
            return dispatch(gpa, io, env, a, .{ .unlock = .{ .path = path, .output = a.output, .force = a.force, .light = a.light } }, out, err);
        },
    }
}

fn runSelftest(gpa: std.mem.Allocator, io: Io, out: *Io.Writer) !u8 {
    var results: [selftest.count]selftest.Result = undefined;
    const ok = try selftest.run(gpa, io, &results);
    for (results) |r| try out.print("{s}  {s}\n", .{ if (r.ok) "ok  " else "FAIL", r.name });
    try out.writeAll(if (ok) "all checks passed\n" else "SELF-TEST FAILED: do not lock or unlock with this build\n");
    return if (ok) 0 else 1;
}

fn dispatch(gpa: std.mem.Allocator, io: Io, env: *std.process.Environ.Map, a: Args, job: tui.Job, out: *Io.Writer, err: *Io.Writer) !u8 {
    const tty = Io.File.stdout().isTty(io) catch false;
    if (a.plain or !tty) return runPlain(gpa, io, job, out, err);
    return runUi(gpa, io, env, job, out);
}

fn exitCode(st: *const engine.Status) u8 {
    return switch (st.phase()) {
        .done => 0,
        .canceled => 130,
        else => 1,
    };
}

fn runUi(gpa: std.mem.Allocator, io: Io, env: *std.process.Environ.Map, job: ?tui.Job, out: *Io.Writer) !u8 {
    tui.launch = .{ .gpa = gpa, .job = job };
    var program = zz.Program(tui.Model).initWithOptions(gpa, io, env, .{ .title = "yuzu", .fps = 30 });
    defer program.deinit();
    try program.run();

    const m = &program.model;
    if (m.screen != .running) return 0;
    m.joinJob();
    try out.print("{s}\n", .{m.status.message()});
    return exitCode(&m.status);
}

var plain_status: ?*engine.Status = null;

fn onInterrupt(_: std.posix.SIG) callconv(.c) void {
    if (plain_status) |st| st.requestCancel();
}

fn runPlain(gpa: std.mem.Allocator, io: Io, job: tui.Job, out: *Io.Writer, err: *Io.Writer) !u8 {
    var st: engine.Status = .{};
    // Ctrl+C asks the job to stop cleanly, so an unlock saves its checkpoint.
    plain_status = &st;
    defer plain_status = null;
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = onInterrupt },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &act, null);
    std.posix.sigaction(.TERM, &act, null);

    const thread = switch (job) {
        .lock => |o| try std.Thread.spawn(.{}, engine.runLock, .{ gpa, io, o, &st }),
        .unlock => |o| try std.Thread.spawn(.{}, engine.runUnlock, .{ gpa, io, o, &st }),
    };
    var last: engine.Phase = .starting;
    var b: [64]u8 = undefined;
    var ticks: u32 = 0;
    while (!st.isFinished()) : (ticks += 1) {
        io.sleep(.fromMilliseconds(100), .awake) catch {};
        const p = st.phase();
        if (p != last) {
            if (last == .hashing) try err.writeAll("\n");
            if (p == .hashing) {
                var nb: [160]u8 = undefined;
                if (st.is_lock) if (st.threadsChoiceNote()) |n| try err.print("threads: {s}\n", .{n});
                if (st.threadNote(&nb)) |n| try err.print("note: {s}\n", .{n});
                if (st.speedNote()) |n| try err.print("note: {s}\n", .{n});
                if (st.resumed_steps > 0) {
                    try err.print("resuming from saved progress: {d}/{d} steps done\n", .{ st.resumed_steps, st.total_steps });
                    if (st.is_lock) try err.writeAll("note: the duration and step count come from the original lock\n");
                }
            }
            switch (p) {
                .preparing => try err.writeAll(if (st.mode == .fast) "building the RandomX dataset (2 GiB)…\n" else "preparing RandomX (light mode)…\n"),
                .benchmarking => try err.writeAll("benchmarking…\n"),
                .writing => try err.writeAll(if (st.is_lock) "encrypting…\n" else "decrypting…\n"),
                else => {},
            }
            last = p;
        }
        if (p == .hashing and ticks % 10 == 0) {
            const done = st.done_steps.load(.monotonic);
            const total = @max(st.total_steps, 1);
            const pct = @as(f64, @floatFromInt(done)) * 100 / @as(f64, @floatFromInt(total));
            try err.print("\rhashing {d}/{d} steps ({d:.1}%)", .{ done, total, pct });
            if (!st.is_lock and st.rate_millis > 0 and st.mode == .fast)
                try err.print(" ~{s} left   ", .{util.fmtDuration(&b, (total - done) * 1000 / st.rate_millis)});
        }
        try err.flush();
    }
    thread.join();
    if (last == .hashing) try err.writeAll("\n");
    try err.flush();
    try out.print("{s}\n", .{st.message()});
    return exitCode(&st);
}

fn bench(gpa: std.mem.Allocator, io: Io, out: *Io.Writer) !u8 {
    const mode = engine.chooseMode(io, 1);
    try out.print("preparing RandomX v2 ({s} mode)…\n", .{@tagName(mode)});
    try out.flush();
    var salt: [16]u8 = undefined;
    io.random(&salt);
    var eng = try puzzle.Engine.init(gpa, salt, mode, std.Thread.getCpuCount() catch 1);
    defer eng.deinit();
    const rate = try engine.benchmark(&eng, io, null);
    const per_sec = @as(f64, @floatFromInt(rate)) / 1000;
    try out.print("{d:.1} steps/s on one core ({d:.2} ms per step), {s} mode, {s} pages\n", .{
        per_sec, 1000 / per_sec, @tagName(mode), @tagName(eng.pages()),
    });
    try out.print("a 1h lock would be {d:.0} steps\n", .{per_sec * 3600});
    if (eng.pages() != .explicit)
        try out.writeAll("note: without explicit huge pages this is up to ~45% slower than it could be (sudo sysctl vm.nr_hugepages=1250)\n");
    return 0;
}

fn info(gpa: std.mem.Allocator, io: Io, a: Args, out: *Io.Writer) !u8 {
    const path = a.positional orelse return fail("info needs a .yuzu file", .{});
    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var r_buf: [4096]u8 = undefined;
    var fr = file.reader(io, &r_buf);
    var raw: []u8 = undefined;
    var h = puzzle.Header.read(gpa, &fr.interface, &raw) catch |e| switch (e) {
        error.ReadFailed => return fr.err.?,
        else => return e,
    };
    defer h.deinit(gpa);
    defer gpa.free(raw);

    var b1: [64]u8 = undefined;
    var b2: [64]u8 = undefined;
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(h.created, 0)) };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    try out.print("file          {s}\n", .{path});
    try out.print("locked        {d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC\n", .{
        day.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(),
    });
    try out.print("requested     {s}\n", .{util.fmtDuration(&b1, h.target_seconds)});
    try out.print("hash          RandomX v2; unlocking needs ~2.4 GiB RAM (300 MiB in slower light mode)\n", .{});
    try out.print("benchmark     {s}\n", .{switch (h.bench_pages) {
        .explicit => "measured with explicit huge pages",
        .transparent => "measured with transparent huge pages (a machine with explicit ones unlocks faster)",
        .normal => "measured with normal pages (a machine with huge pages unlocks up to ~45% faster)",
        .none => "none (fixed step count)",
        _ => "unknown",
    }});
    try out.print("chains        {d} × {d} steps = {d} sequential steps\n", .{ h.chains, h.iterations, h.totalSteps() });
    if (h.rate_millis > 0)
        try out.print("estimate      {s} (speed measured when locked: {d:.2} steps/s)\n", .{
            util.fmtDuration(&b2, h.totalSteps() * 1000 / h.rate_millis),
            @as(f64, @floatFromInt(h.rate_millis)) / 1000,
        });

    var prog_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const prog_path = try std.fmt.bufPrint(&prog_path_buf, "{s}.progress", .{path});
    var cp_buf: [puzzle.progress_len + 1]u8 = undefined;
    if (Io.Dir.cwd().readFile(io, prog_path, &cp_buf)) |data| {
        if (puzzle.Checkpoint.decode(data)) |cp| if (std.mem.eql(u8, &cp.file_digest, &puzzle.digest(raw))) {
            const done = @as(u64, cp.chain) * h.iterations + cp.index;
            try out.print("progress      {d}/{d} steps ({d:.1}%) saved\n", .{
                done, h.totalSteps(), @as(f64, @floatFromInt(done)) * 100 / @as(f64, @floatFromInt(h.totalSteps())),
            });
        };
    } else |_| {}

    if (a.bench) {
        try out.writeAll("benchmarking this machine…\n");
        try out.flush();
        var eng = try puzzle.Engine.init(gpa, h.salt, engine.chooseMode(io, 1), std.Thread.getCpuCount() catch 1);
        defer eng.deinit();
        const rate = try engine.benchmark(&eng, io, null);
        try out.print("this machine  {s} ({d:.2} steps/s)\n", .{
            util.fmtDuration(&b2, h.totalSteps() * 1000 / rate),
            @as(f64, @floatFromInt(rate)) / 1000,
        });
    }
    return 0;
}
