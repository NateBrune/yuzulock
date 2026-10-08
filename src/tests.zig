const std = @import("std");
const testing = std.testing;
const puzzle = @import("puzzle.zig");
const util = @import("util.zig");
const selftest = @import("selftest.zig");

test "RFC 9106 vectors and libargon2 step vectors" {
    var results: [selftest.count]selftest.Result = undefined;
    const ok = try selftest.run(testing.allocator, testing.io, &results);
    for (results) |r| if (!r.ok) std.debug.print("FAIL {s}\n", .{r.name});
    try testing.expect(ok);
}

test "parseDuration" {
    try testing.expectEqual(@as(u64, 90), try util.parseDuration("90"));
    try testing.expectEqual(@as(u64, 45), try util.parseDuration("45s"));
    try testing.expectEqual(@as(u64, 900), try util.parseDuration("15m"));
    try testing.expectEqual(@as(u64, 9000), try util.parseDuration("2h30m"));
    try testing.expectEqual(@as(u64, 86400 + 12 * 3600), try util.parseDuration("1d12h"));
    try testing.expectEqual(@as(u64, 7 * 86400), try util.parseDuration("1w"));
    try testing.expectError(error.InvalidDuration, util.parseDuration(""));
    try testing.expectError(error.InvalidDuration, util.parseDuration("h"));
    try testing.expectError(error.InvalidDuration, util.parseDuration("5x"));
    try testing.expectError(error.InvalidDuration, util.parseDuration("0"));
}

test "header round trip" {
    const gpa = testing.allocator;
    var links = [_]puzzle.Hash{@splat(7)};
    var checks = [_]puzzle.Check{ @splat(1), @splat(2) };
    const h: puzzle.Header = .{
        .bench_pages = .explicit,
        .chains = 2,
        .iterations = 5,
        .target_seconds = 60,
        .rate_millis = 1234,
        .created = 1_700_000_000,
        .salt = @splat(3),
        .seed = @splat(4),
        .nonce_prefix = @splat(5),
        .chunk_size = 1024,
        .links = &links,
        .checks = &checks,
    };
    const enc = try h.encode(gpa);
    defer gpa.free(enc);
    var r: std.Io.Reader = .fixed(enc);
    var raw: []u8 = undefined;
    var back = try puzzle.Header.read(gpa, &r, &raw);
    defer back.deinit(gpa);
    defer gpa.free(raw);
    try testing.expectEqualSlices(u8, enc, raw);
    try testing.expectEqual(h.iterations, back.iterations);
    try testing.expectEqual(h.bench_pages, back.bench_pages);
    try testing.expectEqualSlices(u8, &links[0], &back.links[0]);
}

fn roundTrip(gpa: std.mem.Allocator, data: []const u8, chunk: u32) !void {
    const key: puzzle.Hash = @splat(9);
    const ad: puzzle.Hash = @splat(8);
    var h: puzzle.Header = undefined;
    h.chunk_size = chunk;
    h.nonce_prefix = @splat(6);

    var enc: std.Io.Writer.Allocating = .init(gpa);
    defer enc.deinit();
    var in: std.Io.Reader = .fixed(data);
    try puzzle.encryptStream(gpa, key, h, ad, "notes.txt", &in, &enc.writer);

    var r: std.Io.Reader = .fixed(enc.written());
    var name_buf: [puzzle.max_name_len]u8 = undefined;
    try testing.expectEqualStrings("notes.txt", try puzzle.decryptName(key, h, ad, &r, &name_buf));
    var dec: std.Io.Writer.Allocating = .init(gpa);
    defer dec.deinit();
    try puzzle.decryptData(gpa, key, h, ad, &r, &dec.writer);
    try testing.expectEqualSlices(u8, data, dec.written());

    // Flipping any ciphertext byte must be detected.
    const tampered = try gpa.dupe(u8, enc.written());
    defer gpa.free(tampered);
    tampered[tampered.len - 1] ^= 1;
    var r2: std.Io.Reader = .fixed(tampered);
    _ = try puzzle.decryptName(key, h, ad, &r2, &name_buf);
    var sink: std.Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();
    try testing.expectError(error.WrongKeyOrCorrupt, puzzle.decryptData(gpa, key, h, ad, &r2, &sink.writer));

    // Dropping the final chunk must be detected too.
    if (data.len >= chunk) {
        const cut = enc.written()[0 .. enc.written().len - (data.len % chunk) - puzzle.tag_len];
        var r3: std.Io.Reader = .fixed(cut);
        _ = try puzzle.decryptName(key, h, ad, &r3, &name_buf);
        var sink2: std.Io.Writer.Allocating = .init(gpa);
        defer sink2.deinit();
        if (puzzle.decryptData(gpa, key, h, ad, &r3, &sink2.writer)) |_| return error.TestExpectedError else |_| {}
    }
}

test "stream encryption round trip" {
    const gpa = testing.allocator;
    var data: [5000]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i * 31);
    try roundTrip(gpa, &data, 1024); // partial final chunk
    try roundTrip(gpa, data[0..4096], 1024); // empty final chunk
    try roundTrip(gpa, "", 1024);
    try roundTrip(gpa, "hi", 1024);
}

test "RandomX steps are deterministic, keyed, and bind chain and index" {
    const gpa = testing.allocator;
    var engine = try puzzle.Engine.init(gpa, @splat(1), .light, 1);
    defer engine.deinit();
    var s = try engine.stepper();
    defer s.deinit();

    var a: puzzle.Hash = @splat(0);
    var b: puzzle.Hash = @splat(0);
    for (0..3) |i| s.step(&a, 0, i);
    for (0..3) |i| s.step(&b, 0, i);
    try testing.expectEqualSlices(u8, &a, &b);

    // The chain index is bound in, so lanes never collide.
    var c: puzzle.Hash = @splat(0);
    for (0..3) |i| s.step(&c, 1, i);
    try testing.expect(!std.mem.eql(u8, &a, &c));

    // A different salt gives a different RandomX key, so different steps.
    var other = try puzzle.Engine.init(gpa, @splat(2), .light, 1);
    defer other.deinit();
    var t = try other.stepper();
    defer t.deinit();
    var d: puzzle.Hash = @splat(0);
    for (0..3) |i| t.step(&d, 0, i);
    try testing.expect(!std.mem.eql(u8, &a, &d));
}

test "checkpoint round trip" {
    const cp: puzzle.Checkpoint = .{ .file_digest = @splat(1), .chain = 3, .index = 99, .state = @splat(2) };
    const enc = cp.encode();
    const back = puzzle.Checkpoint.decode(&enc).?;
    try testing.expectEqual(cp.chain, back.chain);
    try testing.expectEqual(cp.index, back.index);
    try testing.expect(puzzle.Checkpoint.decode(enc[0..10]) == null);
}

test "lock state round trip and corruption detection" {
    const lockstate = @import("lockstate.zig");
    const gpa = testing.allocator;
    var chains = [_]lockstate.Chain{
        .{ .seed = @splat(1), .index = 3, .state = @splat(2) },
        .{ .seed = @splat(3), .index = 5, .state = @splat(4) },
    };
    const s: lockstate.LockState = .{
        .bench_pages = 2,
        .iterations = 5,
        .target_seconds = 60,
        .rate_millis = 1000,
        .created = 1_700_000_000,
        .salt = @splat(9),
        .input = "docs/secret.txt",
        .chains = &chains,
    };
    const enc = try s.encode(gpa);
    defer gpa.free(enc);
    var back = try lockstate.LockState.decode(gpa, enc);
    defer back.deinit(gpa);
    try testing.expectEqualStrings("docs/secret.txt", back.input);
    try testing.expectEqual(@as(u64, 8), back.doneSteps());
    try testing.expectEqualSlices(u8, &chains[1].state, &back.chains[1].state);

    // Any flipped bit is caught by the checksum.
    const bad = try gpa.dupe(u8, enc);
    defer gpa.free(bad);
    bad[40] ^= 1;
    try testing.expectError(error.CorruptLockState, lockstate.LockState.decode(gpa, bad));
    try testing.expectError(error.CorruptLockState, lockstate.LockState.decode(gpa, enc[0 .. enc.len - 1]));
}
