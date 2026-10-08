//! The ZigZag front end: an optional setup form, then a live progress screen
//! for a lock or unlock job running on a background thread.

const std = @import("std");
const zz = @import("zigzag");
const engine = @import("engine.zig");
const util = @import("util.zig");
const puzzle = @import("puzzle.zig");

pub const Job = union(enum) {
    lock: engine.LockOptions,
    unlock: engine.UnlockOptions,
};

/// What the program was started with. `Program` constructs the model itself,
/// so this is handed over through a global before `run()`.
pub var launch: struct {
    gpa: std.mem.Allocator = undefined,
    job: ?Job = null,
} = .{};

const yuzu = zz.Color.hex("#F5C542");
const leaf = zz.Color.hex("#8FCB5A");
const dim = zz.Color.gray(12);
const bad = zz.Color.hex("#FF6B6B");

const Field = enum { mode, path, duration, threads, submit };
const lock_fields = [_]Field{ .mode, .path, .duration, .threads, .submit };
const unlock_fields = [_]Field{ .mode, .path, .submit };

const Choice = zz.Dropdown([]const u8);
/// Dropdown value meaning "let me type it myself".
const custom = "\x00custom";

const mode_items = [_]Choice.Item{
    .init("lock", "Lock    make a file time-locked"),
    .init("unlock", "Unlock  solve a .yuzu file"),
};

const duration_items = [_]Choice.Item{
    .init("5m", "5 minutes"),   .init("15m", "15 minutes"), .init("30m", "30 minutes"),
    .init("1h", "1 hour"),      .init("2h", "2 hours"),     .init("6h", "6 hours"),
    .init("12h", "12 hours"),   .init("1d", "1 day"),       .init("3d", "3 days"),
    .init("1w", "1 week"),      .init("30d", "30 days"),    .init(custom, "Custom…"),
};

const max_thread_items = 32;

pub const Model = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    screen: enum { form, running },
    cwd: []const u8,

    // Form state
    mode: enum { lock, unlock },
    focus: Field,
    /// The field whose popup (dropdown, or file browser for `.path`) is open.
    popup: ?Field,
    path: zz.TextInput,
    duration: zz.TextInput,
    threads: zz.TextInput,
    form_error: ?[]const u8,
    picker: zz.components.FilePicker,
    dropdown: Choice,
    /// Copies of the form values that outlive the text inputs' edits.
    owned: [2][]u8,

    // Dropdown items built at startup (they depend on this machine).
    thread_items: [max_thread_items + 2]Choice.Item,
    thread_count: usize,
    thread_labels: [max_thread_items + 1][16]u8,
    /// The miners'-rule thread count for this CPU.
    auto_threads: engine.AutoThreads,
    /// Free RAM and free explicit huge pages at startup, for the RAM summary.
    avail_kib: ?u64,
    huge_pages_free: u64,

    // Job state
    job: Job,
    status: engine.Status,
    thread: ?std.Thread,
    spinner: zz.Spinner,
    rate_t0: u64,
    rate_steps0: u64,
    rate_seen: bool,
    rate: f64,
    elapsed_started: u64,
    now: u64,
    quitting: bool,

    pub const Msg = union(enum) {
        key: zz.KeyEvent,
        tick: zz.msg.Tick,
    };

    pub fn init(self: *Model, ctx: *zz.Context) !zz.Cmd(Msg) {
        self.* = .{
            .gpa = launch.gpa,
            .io = ctx.io,
            .screen = .form,
            .cwd = std.process.currentPathAlloc(ctx.io, ctx.persistent_allocator) catch "/",
            .mode = .lock,
            .focus = .path,
            .popup = null,
            .path = .init(ctx.persistent_allocator),
            .duration = .init(ctx.persistent_allocator),
            .threads = .init(ctx.persistent_allocator),
            .form_error = null,
            .picker = .init(ctx.persistent_allocator),
            .dropdown = .init(ctx.persistent_allocator),
            .owned = .{ &.{}, &.{} },
            .thread_items = undefined,
            .thread_count = 0,
            .thread_labels = undefined,
            .avail_kib = util.availableMemKib(ctx.io, puzzle.dataset_huge_pages),
            .huge_pages_free = util.freeHugePages(ctx.io),
            .auto_threads = engine.autoThreads(ctx.io),
            .job = undefined,
            .status = .{},
            .thread = null,
            .spinner = .init(),
            .rate_t0 = 0,
            .rate_steps0 = 0,
            .rate_seen = false,
            .rate = 0,
            .elapsed_started = 0,
            .now = 0,
            .quitting = false,
        };
        self.path.setPlaceholder("enter to browse, or type a path");
        self.duration.setPlaceholder("enter for presets, or type e.g. 1d12h");

        self.picker.setHomePath(ctx.home_dir);
        self.picker.dir_icon = "▸ ";
        self.picker.parent_icon = "◂ ";
        self.picker.link_icon = "↪ ";
        self.picker.file_icon = "  ";
        self.picker.path_style = (zz.Style{}).bold(true).fg(yuzu).inline_style(true);
        self.picker.dir_style = (zz.Style{}).bold(true).fg(leaf).inline_style(true);
        self.picker.cursor_style = (zz.Style{}).bold(true).fg(.black).bg(yuzu).inline_style(true);

        self.dropdown.max_visible = 8;
        self.dropdown.border_fg = dim;
        self.dropdown.cursor_item_style = (zz.Style{}).bold(true).fg(yuzu).inline_style(true);
        self.dropdown.selected_item_style = (zz.Style{}).fg(leaf).inline_style(true);

        self.buildThreadItems();
        self.threads.setPlaceholder(self.thread_items[0].label);
        self.syncFocus();

        if (launch.job) |job| {
            try self.start(job, ctx);
        }
        return zz.Cmd(Msg).everyMs(100);
    }

    /// "auto", then 1..CPU count.
    fn buildThreadItems(self: *Model) void {
        const cpus = @min(std.Thread.getCpuCount() catch 1, max_thread_items);
        const auto_label = std.fmt.bufPrint(&self.thread_labels[0], "auto ({d})", .{self.auto_threads.threads}) catch "auto";
        self.thread_items[0] = .init("", auto_label);
        for (1..cpus + 1) |n| {
            const text = std.fmt.bufPrint(&self.thread_labels[n], "{d}", .{n}) catch unreachable;
            self.thread_items[n] = .init(text, text);
        }
        self.thread_items[cpus + 1] = .init(custom, "Custom…");
        self.thread_count = cpus + 2;
    }

    pub fn deinit(self: *Model) void {
        self.joinJob();
        self.path.deinit();
        self.duration.deinit();
        self.threads.deinit();
        self.picker.deinit();
        self.dropdown.deinit();
        for (self.owned) |o| self.gpa.free(o);
    }

    pub fn joinJob(self: *Model) void {
        if (self.thread) |t| {
            self.status.requestCancel();
            t.join();
            self.thread = null;
        }
    }

    fn start(self: *Model, job: Job, ctx: *zz.Context) !void {
        self.job = job;
        self.screen = .running;
        self.elapsed_started = ctx.elapsed;
        self.thread = switch (job) {
            .lock => |o| try std.Thread.spawn(.{}, engine.runLock, .{ self.gpa, ctx.io, o, &self.status }),
            .unlock => |o| try std.Thread.spawn(.{}, engine.runUnlock, .{ self.gpa, ctx.io, o, &self.status }),
        };
    }

    // -----------------------------------------------------------------------
    // Update
    // -----------------------------------------------------------------------

    pub fn update(self: *Model, msg: Msg, ctx: *zz.Context) !zz.Cmd(Msg) {
        switch (msg) {
            .tick => {
                self.now = ctx.elapsed;
                _ = self.spinner.update(@intCast(ctx.elapsed));
                if (self.screen == .running) {
                    self.sampleRate();
                    if (self.quitting and self.status.isFinished()) return .quit;
                }
            },
            .key => |k| return switch (self.screen) {
                .form => self.updateForm(k, ctx),
                .running => self.updateRunning(k),
            },
        }
        return .none;
    }

    fn updateRunning(self: *Model, k: zz.KeyEvent) zz.Cmd(Msg) {
        if (self.status.isFinished()) return .quit;
        const is_quit = switch (k.key) {
            .char => |c| c == 'q' or (k.modifiers.ctrl and c == 'c'),
            .escape => true,
            else => false,
        };
        if (is_quit) {
            self.status.requestCancel();
            self.quitting = true;
        }
        return .none;
    }

    fn updateForm(self: *Model, k: zz.KeyEvent, ctx: *zz.Context) !zz.Cmd(Msg) {
        if (k.key == .char and k.modifiers.ctrl) switch (k.key.char) {
            'c' => return .quit,
            'o' => {
                self.focus = .path;
                self.syncFocus();
                try self.openPopup(.path, ctx);
                return .none;
            },
            's' => {
                self.popup = null;
                if (try self.submit()) |job| try self.start(job, ctx);
                return .none;
            },
            else => {},
        };

        if (self.popup) |p| {
            if (k.key == .tab) {
                self.popup = null;
                self.dropdown.close();
                self.moveFocus(if (k.modifiers.shift) -1 else 1);
                return .none;
            }
            if (p == .path) try self.updatePicker(k, ctx) else try self.updateDropdown(p, k);
            return .none;
        }

        switch (k.key) {
            .escape => return .quit,
            .tab, .down => {
                self.moveFocus(if (k.modifiers.shift) -1 else 1);
                return .none;
            },
            .up => {
                self.moveFocus(-1);
                return .none;
            },
            .enter => {
                if (self.focus == .submit) {
                    if (try self.submit()) |job| try self.start(job, ctx);
                } else try self.openPopup(self.focus, ctx);
                return .none;
            },
            else => {},
        }
        self.form_error = null;
        switch (self.focus) {
            .mode => switch (k.key) {
                .left, .right, .space => self.setMode(if (self.mode == .lock) .unlock else .lock),
                .char => |c| switch (c) {
                    'l', 'L' => self.setMode(.lock),
                    'u', 'U' => self.setMode(.unlock),
                    else => {},
                },
                else => {},
            },
            .path => self.path.handleKey(k),
            .duration => self.duration.handleKey(k),
            .threads => self.threads.handleKey(k),
            .submit => {},
        }
        return .none;
    }

    fn setMode(self: *Model, mode: @TypeOf(self.mode)) void {
        self.mode = mode;
    }

    fn inputFor(self: *Model, f: Field) ?*zz.TextInput {
        return switch (f) {
            .path => &self.path,
            .duration => &self.duration,
            .threads => &self.threads,
            .mode, .submit => null,
        };
    }

    // -----------------------------------------------------------------------
    // Popups
    // -----------------------------------------------------------------------

    fn openPopup(self: *Model, f: Field, ctx: *zz.Context) !void {
        self.form_error = null;
        if (f == .path) return self.openPicker(ctx);

        const items: []const Choice.Item = switch (f) {
            .mode => &mode_items,
            .duration => &duration_items,
            .threads => self.thread_items[0..self.thread_count],
            .path, .submit => return,
        };
        try self.dropdown.setItems(items);

        // Start on the entry matching what's already in the field.
        const current: []const u8 = if (f == .mode)
            (if (self.mode == .lock) "lock" else "unlock")
        else
            std.mem.trim(u8, self.inputFor(f).?.getValue(), " ");
        for (items, 0..) |item, i| {
            if (std.ascii.eqlIgnoreCase(item.value, current)) self.dropdown.selected_index = i;
        }
        self.dropdown.open();
        self.popup = f;
    }

    fn updateDropdown(self: *Model, f: Field, k: zz.KeyEvent) !void {
        self.dropdown.handleKey(k);
        if (self.dropdown.isExpanded()) return;
        self.popup = null;

        // Enter picks; Esc or q just closes.
        if (k.key != .enter) return;
        const value = (self.dropdown.selectedItem() orelse return).value;
        if (std.mem.eql(u8, value, custom)) return; // stay on the field and type

        switch (f) {
            .mode => self.setMode(if (std.mem.eql(u8, value, "lock")) .lock else .unlock),
            else => try self.inputFor(f).?.setValue(value),
        }
        self.moveFocus(1);
    }

    fn openPicker(self: *Model, ctx: *zz.Context) !void {
        // Unlock only makes sense on .yuzu files; lock takes anything.
        self.picker.allowed_extensions = if (self.mode == .unlock) &.{".yuzu"} else null;
        self.picker.height = @intCast(std.math.clamp(@as(i32, ctx.height) - 20, 6, 16));

        // Start where the typed path points, falling back to the working directory.
        const typed = std.mem.trim(u8, self.path.getValue(), " \t");
        var start_dir: []const u8 = self.cwd;
        if (typed.len > 0) {
            const abs = try std.fs.path.resolve(ctx.allocator, &.{ self.cwd, typed });
            if (isDir(self.io, abs)) {
                start_dir = abs;
            } else if (std.fs.path.dirname(abs)) |parent| {
                if (isDir(self.io, parent)) start_dir = parent;
            }
        }
        try self.picker.navigate(self.io, start_dir);
        self.popup = .path;
    }

    fn updatePicker(self: *Model, k: zz.KeyEvent, ctx: *zz.Context) !void {
        switch (k.key) {
            .escape => {
                self.popup = null;
                return;
            },
            .char => |c| if (c == 'q') {
                self.popup = null;
                return;
            },
            else => {},
        }
        if (try self.picker.handleKey(self.io, k)) {
            const chosen = self.picker.getSelected().?;
            if (isDir(self.io, chosen)) {
                // A symlink to a directory: open it rather than pick it.
                const copy = try ctx.allocator.dupe(u8, chosen);
                try self.picker.navigate(self.io, copy);
            } else {
                try self.path.setValue(relativeToCwd(self.cwd, chosen));
                self.popup = null;
                self.moveFocus(1);
            }
        }
        // FilePicker scrolls by `height` but only draws `height - 2` rows.
        const visible = self.picker.height -| 2;
        if (self.picker.cursor >= self.picker.y_offset + visible)
            self.picker.y_offset = self.picker.cursor + 1 - visible;
    }

    fn isDir(io: std.Io, path: []const u8) bool {
        const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
        return st.kind == .directory;
    }

    fn relativeToCwd(cwd: []const u8, path: []const u8) []const u8 {
        if (std.mem.eql(u8, cwd, "/")) return path;
        if (path.len > cwd.len + 1 and std.mem.startsWith(u8, path, cwd) and path[cwd.len] == '/')
            return path[cwd.len + 1 ..];
        return path;
    }

    fn fields(self: *const Model) []const Field {
        return if (self.mode == .lock) &lock_fields else &unlock_fields;
    }

    fn moveFocus(self: *Model, delta: i32) void {
        const list = self.fields();
        const cur = std.mem.indexOfScalar(Field, list, self.focus) orelse 0;
        const n: i32 = @intCast(list.len);
        self.focus = list[@intCast(@mod(@as(i32, @intCast(cur)) + delta, n))];
        self.syncFocus();
    }

    fn syncFocus(self: *Model) void {
        for ([_]Field{ .path, .duration, .threads }) |f| {
            const input = self.inputFor(f).?;
            if (f == self.focus) input.focus() else input.blur();
        }
    }

    fn own(self: *Model, slot: usize, text: []const u8) ![]const u8 {
        self.gpa.free(self.owned[slot]);
        self.owned[slot] = try self.gpa.dupe(u8, text);
        return self.owned[slot];
    }

    fn submit(self: *Model) !?Job {
        const path = std.mem.trim(u8, self.path.getValue(), " \t");
        if (path.len == 0) return self.fail("Enter a file path.");
        if (!util.exists(self.io, path)) return self.fail("File not found.");
        const owned_path = try self.own(0, path);

        if (self.mode == .unlock) return .{ .unlock = .{ .path = owned_path } };

        const seconds = util.parseDuration(self.duration.getValue()) catch
            return self.fail("Duration must look like 90s, 30m, 2h or 1d12h.");
        var opts: engine.LockOptions = .{ .path = owned_path, .seconds = seconds };
        const t = std.mem.trim(u8, self.threads.getValue(), " ");
        if (t.len > 0) {
            opts.threads = std.fmt.parseInt(u32, t, 10) catch return self.fail("Threads must be a number.");
            if (opts.threads == 0 or opts.threads > engine.max_lanes) return self.fail("Threads must be 1–64.");
        }
        return .{ .lock = opts };
    }

    fn fail(self: *Model, text: []const u8) ?Job {
        self.form_error = text;
        return null;
    }

    fn sampleRate(self: *Model) void {
        if (self.status.phase() != .hashing) return;
        const done = self.status.done_steps.load(.monotonic);
        if (!self.rate_seen) {
            self.rate_seen = true;
            self.rate_t0 = self.now;
            self.rate_steps0 = done;
            return;
        }
        const dt = self.now -| self.rate_t0;
        if (dt > std.time.ns_per_s / 2 and done > self.rate_steps0)
            self.rate = @as(f64, @floatFromInt(done - self.rate_steps0)) * std.time.ns_per_s / @as(f64, @floatFromInt(dt));
    }

    // -----------------------------------------------------------------------
    // View
    // -----------------------------------------------------------------------

    pub fn view(self: *const Model, ctx: *const zz.Context) ![]const u8 {
        const a = ctx.allocator;
        const body = switch (self.screen) {
            .form => try self.viewForm(a),
            .running => try self.viewRunning(a, contentWidth(ctx.width)),
        };
        const title = try (zz.Style{}).bold(true).fg(yuzu).inline_style(true).render(a, "◉ yuzu");
        const sub = try (zz.Style{}).fg(dim).inline_style(true).render(a, "  time-lock files with sequential RandomX hashing");
        const header = try std.fmt.allocPrint(a, "{s}{s}", .{ title, sub });
        const box = try (zz.Style{})
            .borderAll(zz.Border.rounded)
            .borderForeground(yuzu)
            .paddingLeft(2).paddingRight(2).paddingTop(1).paddingBottom(1)
            .width(contentWidth(ctx.width))
            .render(a, body);
        const all = try zz.joinVertical(a, &.{ header, "", box });
        return zz.place.place(a, ctx.width, ctx.height, .center, .middle, all);
    }

    fn label(a: std.mem.Allocator, text: []const u8, focused: bool) ![]const u8 {
        const s = if (focused) (zz.Style{}).bold(true).fg(yuzu) else (zz.Style{}).fg(dim);
        return s.inline_style(true).render(a, text);
    }

    /// Prefixes every line of `text` so popups line up under the field values.
    fn indent(a: std.mem.Allocator, text: []const u8, prefix: []const u8) ![]const u8 {
        var w: std.Io.Writer.Allocating = .init(a);
        var lines = std.mem.splitScalar(u8, text, '\n');
        var first = true;
        while (lines.next()) |line| {
            if (!first) try w.writer.writeByte('\n');
            first = false;
            try w.writer.print("{s}{s}", .{ prefix, line });
        }
        return w.toOwnedSlice();
    }

    const value_col = "             "; // width of a row label + 2

    fn viewForm(self: *const Model, a: std.mem.Allocator) ![]const u8 {
        var w: std.Io.Writer.Allocating = .init(a);
        const out = &w.writer;
        const muted = (zz.Style{}).fg(dim).inline_style(true);
        const arrow = struct {
            fn f(m: *const Model, field: Field) []const u8 {
                return if (m.popup == field) " ▲" else if (m.focus == field) " ▼" else "";
            }
        }.f;

        const on = (zz.Style{}).bold(true).fg(.black).bg(yuzu).inline_style(true);
        const off = (zz.Style{}).fg(dim).inline_style(true);
        try out.print("{s}  {s} {s}{s}\n", .{
            try label(a, "Mode       ", self.focus == .mode),
            try (if (self.mode == .lock) on else off).render(a, " Lock "),
            try (if (self.mode == .unlock) on else off).render(a, " Unlock "),
            try muted.render(a, arrow(self, .mode)),
        });
        if (self.popup == .mode) try out.print("{s}\n", .{try self.viewDropdown(a)});
        try out.writeAll("\n");

        const rows = [_]struct { Field, []const u8, *const zz.TextInput }{
            .{ .path, "File       ", &self.path },
            .{ .duration, "Lock for   ", &self.duration },
            .{ .threads, "Threads    ", &self.threads },
        };
        for (rows) |row| {
            if (self.mode == .unlock and row[0] != .path) continue;
            try out.print("{s}  {s}{s}\n", .{
                try label(a, row[1], self.focus == row[0]),
                try row[2].view(a),
                try muted.render(a, arrow(self, row[0])),
            });
            if (self.popup == row[0]) {
                const popup = if (row[0] == .path) try self.viewPicker(a) else try self.viewDropdown(a);
                try out.print("{s}\n", .{popup});
            }
        }
        if (self.mode == .lock and self.popup == null) {
            try out.print("\n{s}", .{try self.viewRamSummary(a)});
            if (self.hasLockState(a)) try out.print("{s}\n", .{try (zz.Style{}).fg(yuzu).render(
                a,
                "This file has an unfinished lock. Lock file resumes it with its\noriginal duration; delete its .lockstate to start over.",
            )});
        }
        try out.writeAll("\n");

        const button_text = if (self.mode == .lock) "  Lock file  " else "  Unlock file  ";
        const button = if (self.focus == .submit)
            (zz.Style{}).bold(true).fg(.black).bg(yuzu).inline_style(true)
        else
            (zz.Style{}).fg(yuzu).inline_style(true);
        try out.print("{s}{s}\n\n", .{ value_col, try button.render(a, button_text) });

        if (self.form_error) |e| {
            try out.print("{s}\n\n", .{try (zz.Style{}).fg(bad).inline_style(true).render(a, e)});
        } else if (self.popup == null) {
            const hint = if (self.mode == .lock)
                "More threads lock faster. Unlocking replays every chain in order\non one thread. Every step is a RandomX v2 hash."
            else
                "Unlocking resumes automatically from a saved .progress file.";
            try out.print("{s}\n\n", .{try (zz.Style{}).fg(dim).italic(true).render(a, hint)});
        }

        const keys: []const u8 = if (self.popup) |p| switch (p) {
            .path => "↑↓ move · enter open/select · backspace up · h hidden · ~ home · esc close",
            else => "↑↓ move · enter pick · / filter · esc close",
        } else "tab/↑↓ move · enter choose · type to edit · ctrl+s start · esc quit";
        try out.writeAll(try muted.render(a, keys));
        return w.toOwnedSlice();
    }

    /// RAM and huge page situation for locking and unlocking, recomputed from
    /// the form as it is edited.
    fn viewRamSummary(self: *const Model, a: std.mem.Allocator) ![]const u8 {
        const muted = (zz.Style{}).fg(dim).inline_style(true);
        const strong = (zz.Style{}).bold(true).inline_style(true);
        const thr_text = std.mem.trim(u8, self.threads.getValue(), " ");
        const threads: u64 = if (thr_text.len == 0) self.auto_threads.threads else std.fmt.parseInt(u32, thr_text, 10) catch 0;
        if (threads == 0 or threads > engine.max_lanes)
            return muted.render(a, "Locking    —\nUnlocking  —\n");

        var b1: [32]u8 = undefined;
        var b2: [32]u8 = undefined;
        const lock_kib = (puzzle.fast_mode_bytes + threads * puzzle.per_thread_bytes) / 1024;
        const unlock_kib = (puzzle.fast_mode_bytes + puzzle.per_thread_bytes) / 1024;

        var note: []const u8 = "";
        const fast_ok = if (self.avail_kib) |avail| avail >= lock_kib + 128 * 1024 else true;
        if (!fast_ok) {
            const partial_pool = self.huge_pages_free > 0 and self.huge_pages_free < puzzle.dataset_huge_pages;
            note = try std.fmt.allocPrint(a, "\n{s}", .{try (zz.Style{}).fg(bad).render(a, try std.fmt.allocPrint(
                a,
                "{d} MiB free, but timed locks need {d} MiB for RandomX.{s}",
                .{
                    self.avail_kib.? / 1024,
                    (lock_kib + 128 * 1024) / 1024,
                    if (partial_pool) try std.fmt.allocPrint(
                        a,
                        "\n{d} huge pages are reserved, too few for the dataset ({d}),\nso they only tie up RAM. Either release them:\n  sudo sysctl vm.nr_hugepages=0\nor close apps and retry:\n  sudo sysctl vm.compact_memory=1\n  sudo sysctl vm.nr_hugepages=1250",
                        .{ self.huge_pages_free, puzzle.dataset_huge_pages },
                    ) else "",
                },
            ))});
        } else if (self.huge_pages_free == 0) {
            note = try std.fmt.allocPrint(a, "\n{s}", .{try (zz.Style{}).fg(yuzu).render(
                a,
                "No huge pages reserved: hashing is up to ~45% slower than on a\nmachine with them, so locks may open sooner. Before locking, run:\nsudo sysctl vm.nr_hugepages=1250",
            )});
        } else if (self.huge_pages_free < puzzle.dataset_huge_pages) {
            note = try std.fmt.allocPrint(a, "\n{s}", .{try (zz.Style{}).fg(yuzu).render(a, try std.fmt.allocPrint(
                a,
                "Only {d} huge pages are free; the dataset needs {d}, so it\nwon't use them and they just tie up RAM. Close apps, then run:\n  sudo sysctl vm.compact_memory=1\n  sudo sysctl vm.nr_hugepages=1250\nor release them: sudo sysctl vm.nr_hugepages=0",
                .{ self.huge_pages_free, puzzle.dataset_huge_pages },
            ))});
        }
        var rb: [160]u8 = undefined;
        const why = self.auto_threads.reason(&rb);
        const threads_line = if (thr_text.len == 0)
            try std.fmt.allocPrint(a, "\n{s}", .{try (zz.Style{}).fg(dim).render(a, try wrap(a, try std.fmt.allocPrint(a, "Auto picks {d} thread{s}: {s}. (The RandomX miners' rule: hyperthreads and threads that spill out of L3 add little speed.)", .{
                self.auto_threads.threads,
                if (self.auto_threads.threads == 1) "" else "s",
                why,
            }), 66))})
        else if (threads > self.auto_threads.threads)
            try std.fmt.allocPrint(a, "\n{s}", .{try (zz.Style{}).fg(yuzu).render(a, try wrap(a, try std.fmt.allocPrint(a, "This CPU suits {d} thread{s}: {s}. Extra threads add little speed.", .{
                self.auto_threads.threads,
                if (self.auto_threads.threads == 1) "" else "s",
                why,
            }), 66))})
        else
            "";
        note = try std.mem.concat(a, u8, &.{ threads_line, note });
        return std.fmt.allocPrint(a, "{s}{s} ({d} thread{s} sharing one 2 GiB dataset)\n{s}{s} (or slower light mode with less){s}\n", .{
            try muted.render(a, "Locking    "),
            try strong.render(a, util.fmtSizeKib(&b1, lock_kib)),
            threads,
            if (threads == 1) "" else "s",
            try muted.render(a, "Unlocking  "),
            try strong.render(a, util.fmtSizeKib(&b2, unlock_kib)),
            note,
        });
    }

    fn hasLockState(self: *const Model, a: std.mem.Allocator) bool {
        const path = std.mem.trim(u8, self.path.getValue(), " \t");
        if (path.len == 0) return false;
        const sp = std.fmt.allocPrint(a, "{s}.yuzu.lockstate", .{path}) catch return false;
        return util.exists(self.io, sp);
    }

    fn viewDropdown(self: *const Model, a: std.mem.Allocator) ![]const u8 {
        // Drop the component's own trigger line; the form row already shows it.
        const full = try self.dropdown.view(a);
        const list = if (std.mem.indexOfScalar(u8, full, '\n')) |nl| full[nl + 1 ..] else full;
        return indent(a, list, value_col);
    }

    fn viewPicker(self: *const Model, a: std.mem.Allocator) ![]const u8 {
        const muted = (zz.Style{}).fg(dim).inline_style(true);
        const empty = self.picker.entries.items.len <= 1;
        const notice = if (!empty) "" else if (self.mode == .unlock) "  (no .yuzu files here)" else "  (empty folder)";

        // FilePicker prints the full directory on its first line, which can be
        // wider than the box; swap it for a shortened one.
        const list = try self.picker.view(a);
        const body = if (std.mem.indexOfScalar(u8, list, '\n')) |nl| list[nl + 1 ..] else list;
        const content = try std.fmt.allocPrint(a, "{s}{s}\n{s}", .{
            try self.picker.path_style.render(a, try self.shortPath(a, self.picker.current_path.items, 50)),
            try muted.render(a, notice),
            body,
        });
        const framed = try (zz.Style{}).borderAll(zz.Border.rounded).borderForeground(dim).paddingLeft(1).paddingRight(1).width(52).render(a, content);
        return indent(a, framed, value_col);
    }

    /// `~`-relative and cut from the left to at most `max` bytes.
    fn shortPath(self: *const Model, a: std.mem.Allocator, path: []const u8, max: usize) ![]const u8 {
        const home = std.mem.trimEnd(u8, self.picker.home_path, "/");
        const p = if (home.len > 1 and std.mem.startsWith(u8, path, home) and
            (path.len == home.len or path[home.len] == '/'))
            try std.fmt.allocPrint(a, "~{s}", .{path[home.len..]})
        else
            path;
        if (p.len <= max) return p;
        var cut = p.len - (max - 1);
        while (cut < p.len and (p[cut] & 0xC0) == 0x80) cut += 1; // stay on a UTF-8 boundary
        return std.fmt.allocPrint(a, "…{s}", .{p[cut..]});
    }

    /// Inner width of the main box; messages are wrapped to fit it.
    fn contentWidth(term_width: u16) u16 {
        return @min(72, term_width -| 6);
    }

    /// Greedy word wrap to `width` columns. Words longer than a line (such as
    /// long paths) are broken at the column limit.
    fn wrap(a: std.mem.Allocator, text: []const u8, width: usize) ![]const u8 {
        const w = @max(width, 10);
        var out: std.Io.Writer.Allocating = .init(a);
        var lines = std.mem.splitScalar(u8, text, '\n');
        var first_line = true;
        while (lines.next()) |line| {
            if (!first_line) try out.writer.writeByte('\n');
            first_line = false;
            var col: usize = 0;
            var words = std.mem.tokenizeScalar(u8, line, ' ');
            while (words.next()) |word_full| {
                var word = word_full;
                while (word.len > 0) {
                    const ww = zz.measure.width(word);
                    if (col > 0 and col + 1 + ww <= w) {
                        try out.writer.print(" {s}", .{word});
                        col += 1 + ww;
                        break;
                    }
                    if (col > 0) {
                        try out.writer.writeByte('\n');
                        col = 0;
                    }
                    if (ww <= w) {
                        try out.writer.writeAll(word);
                        col = ww;
                        break;
                    }
                    // Hard-break an over-long word on a UTF-8 boundary.
                    var cut: usize = @min(w, word.len);
                    while (cut > 0 and cut < word.len and (word[cut] & 0xC0) == 0x80) cut -= 1;
                    if (cut == 0) cut = word.len;
                    try out.writer.writeAll(word[0..cut]);
                    try out.writer.writeByte('\n');
                    word = word[cut..];
                }
            }
        }
        return out.toOwnedSlice();
    }

    fn viewRunning(self: *const Model, a: std.mem.Allocator, width: u16) ![]const u8 {
        var w: std.Io.Writer.Allocating = .init(a);
        const out = &w.writer;
        const st = &self.status;
        const phase = st.phase();
        const verb = if (self.job == .lock) "Locking" else "Unlocking";
        const path = switch (self.job) {
            .lock => |o| o.path,
            .unlock => |o| o.path,
        };
        const bold = (zz.Style{}).bold(true).inline_style(true);
        const muted = (zz.Style{}).fg(dim).inline_style(true);
        const shown_path = try self.shortPath(a, path, @as(usize, width) -| (verb.len + 1));
        try out.print("{s} {s}\n\n", .{ try bold.render(a, verb), try (zz.Style{}).fg(leaf).inline_style(true).render(a, shown_path) });

        var b1: [64]u8 = undefined;
        var b2: [64]u8 = undefined;
        const elapsed_s = (self.now -| self.elapsed_started) / std.time.ns_per_s;

        switch (phase) {
            .starting => try out.print("{s}\n", .{try self.spinner.viewWithTitle(a, "Starting…")}),
            .preparing => try out.print("{s}\n", .{try self.spinner.viewWithTitle(a, if (st.mode == .fast) "Building the 2 GiB RandomX dataset…" else "Preparing RandomX (light mode)…")}),
            .benchmarking => try out.print("{s}\n", .{try self.spinner.viewWithTitle(a, "Measuring how fast this machine hashes (3s)…")}),
            .hashing, .writing => {
                const done = st.done_steps.load(.monotonic);
                const total = @max(st.total_steps, 1);
                var bar = zz.Progress.init();
                bar.setWidth(44);
                bar.setGradient(leaf, yuzu);
                bar.setTotal(@floatFromInt(total));
                bar.setValue(@floatFromInt(done));
                try out.print("{s}\n\n", .{try bar.view(a)});

                const remaining = total -| done;
                const eta: []const u8 = if (phase == .writing)
                    "—"
                else if (self.rate > 0)
                    util.fmtDuration(&b1, @intFromFloat(@as(f64, @floatFromInt(remaining)) / self.rate))
                else if (st.rate_millis > 0 and !st.is_lock)
                    util.fmtDuration(&b1, remaining * 1000 / st.rate_millis)
                else
                    "estimating…";
                try out.print("{s} {d} / {d}    {s} {d:.2}/s\n", .{
                    try muted.render(a, "steps"), done, total,
                    try muted.render(a, "rate"),  self.rate,
                });
                try out.print("{s} {s}    {s} {s}\n", .{
                    try muted.render(a, "elapsed"), util.fmtDuration(&b2, elapsed_s),
                    try muted.render(a, "remaining"), eta,
                });
                try out.print("{s} RandomX v2, {s} mode    {s} {s}\n\n", .{
                    try muted.render(a, "hash"),
                    @tagName(st.mode),
                    try muted.render(a, if (st.mode == .fast) "dataset" else "cache"),
                    switch (st.pages) {
                        .explicit => "explicit huge pages",
                        .transparent => "transparent huge pages",
                        .normal => "normal pages",
                        else => "—",
                    },
                });
                var nb: [160]u8 = undefined;
                if (st.threadNote(&nb)) |n|
                    try out.print("{s}\n\n", .{try (zz.Style{}).fg(yuzu).render(a, try wrap(a, n, width))});
                if (st.speedNote()) |n|
                    try out.print("{s}\n\n", .{try (zz.Style{}).fg(yuzu).render(a, try wrap(a, n, width))});
                if (st.is_lock) if (st.threadsChoiceNote()) |n|
                    try out.print("{s}\n\n", .{try (zz.Style{}).fg(dim).render(a, try wrap(a, n, width))});

                if (phase == .writing) {
                    try out.print("{s}\n", .{try self.spinner.viewWithTitle(a, if (st.is_lock) "Encrypting…" else "Decrypting…")});
                } else if (st.is_lock) {
                    try self.viewLanes(a, out);
                    if (st.resumed_steps > 0)
                        try out.print("{s}\n", .{try muted.render(a, "resumed from saved lock progress")});
                } else {
                    const cur = st.current_chain.load(.monotonic);
                    const in_chain = done -| @as(u64, cur) * st.iterations;
                    var cbar = zz.Progress.init();
                    cbar.setWidth(30);
                    cbar.show_percent = false;
                    cbar.setGradient(leaf, yuzu);
                    cbar.setTotal(@floatFromInt(@max(st.iterations, 1)));
                    cbar.setValue(@floatFromInt(@min(in_chain, st.iterations)));
                    try out.print("{s} {d}/{d}  {s}\n", .{ try muted.render(a, "chain"), cur + 1, st.chains, try cbar.view(a) });
                    if (st.resumed_steps > 0)
                        try out.print("{s}\n", .{try muted.render(a, "resumed from a saved checkpoint")});
                }
            },
            .done => try out.print("{s}\n\n{s}\n", .{
                try (zz.Style{}).bold(true).fg(leaf).inline_style(true).render(a, "✓ Done"),
                try wrap(a, st.message(), width),
            }),
            .failed => try out.print("{s}\n", .{try (zz.Style{}).bold(true).fg(bad).render(a, try wrap(a, st.message(), width))}),
            .canceled => try out.print("{s}\n", .{try (zz.Style{}).fg(yuzu).render(a, try wrap(a, st.message(), width))}),
        }

        try out.writeAll("\n");
        const help = if (st.isFinished())
            "press any key to exit"
        else if (self.quitting)
            "stopping…"
        else if (self.job == .unlock or phase == .hashing)
            "q pause (progress is saved)"
        else
            "q cancel";
        try out.writeAll(try muted.render(a, help));
        return w.toOwnedSlice();
    }

    fn viewLanes(self: *const Model, a: std.mem.Allocator, out: *std.Io.Writer) !void {
        const st = &self.status;
        const shown = @min(st.chains, 16);
        for (0..shown) |j| {
            var bar = zz.Progress.init();
            bar.setWidth(28);
            bar.show_percent = false;
            bar.setGradient(leaf, yuzu);
            bar.setTotal(@floatFromInt(@max(st.iterations, 1)));
            bar.setValue(@floatFromInt(st.lane_done[j].load(.monotonic)));
            try out.print("{s} {s}\n", .{
                try (zz.Style{}).fg(dim).inline_style(true).render(a, try std.fmt.allocPrint(a, "chain {d:>2}", .{j + 1})),
                try bar.view(a),
            });
        }
        if (st.chains > shown)
            try out.print("{s}\n", .{try (zz.Style{}).fg(dim).inline_style(true).render(a, try std.fmt.allocPrint(a, "… and {d} more", .{st.chains - shown}))});
    }
};
