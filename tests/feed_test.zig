//! The changelog feed under /fpindex, read directly and through the fpindex
//! node replicating from it.

const std = @import("std");
const msgpack = @import("msgpack");
const query = @import("query");
const utils = @import("utils.zig");
const Prefixed = utils.Prefixed;

const testing = std.testing;

// The wire types as fpindex decodes them, written out again rather than taken
// from src/feed.zig, so a mistake there cannot pass by agreeing with itself.

const Insert = struct {
    id: u32,
    hashes: []const u32,
    pub const msgpackFormat = Prefixed;
};

const Delete = struct {
    id: u32,
    pub const msgpackFormat = Prefixed;
};

const Change = union(enum) {
    insert: Insert,
    delete: Delete,
    pub fn msgpackFormat() msgpack.UnionFormat {
        return .{ .as_map = .{ .key = .{ .field_name_prefix = 1 } } };
    }
};

const Entry = struct {
    id: u64,
    change: Change,
    pub const msgpackFormat = Prefixed;
};

const ReadResponse = struct {
    entries: []const Entry,
    retry_after_ms: u64,
    pub const msgpackFormat = Prefixed;
};

const MetaOp = struct {
    pos: u64,
    kind: enum(u8) { create, delete },
    index_name: []const u8,
    pub const msgpackFormat = Prefixed;
};

const MetaReadResponse = struct {
    ops: []const MetaOp,
    retry_after_ms: u64,
    pub const msgpackFormat = Prefixed;
};

const BootstrapHeader = struct {
    position: u64,
    pub const msgpackFormat = Prefixed;
};

const feed_url = utils.fpstore_url ++ "/fpindex";
const changelog_url = feed_url ++ "/_changelog/acoustid/1";
const bootstrap_url = feed_url ++ "/_bootstrap/acoustid/1";

const silence: u32 = 627964279;

fn readChangelog(arena: std.mem.Allocator, after: u64, max: ?u64) !ReadResponse {
    const url = if (max) |m|
        try std.fmt.allocPrint(arena, changelog_url ++ "?after={d}&max={d}", .{ after, m })
    else
        try std.fmt.allocPrint(arena, changelog_url ++ "?after={d}", .{after});
    const response = try utils.get(arena, url);
    try testing.expectEqual(.ok, response.status);
    return msgpack.decodeFromSliceLeaky(ReadResponse, arena, response.body);
}

fn extract(arena: std.mem.Allocator, hashes: []const u32) ![]const u32 {
    var out: [query.max_length]u32 = undefined;
    return arena.dupe(u32, query.extract(hashes, &out));
}

test "a stored fingerprint replicates to fpindex and is found by its query" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const db = try utils.connectDb();
    defer db.deinit();
    var prng = std.Random.DefaultPrng.init(1);

    const hashes = try utils.randomFingerprint(arena, prng.random(), 300);
    const id = try utils.insertFingerprint(db, hashes);
    try utils.waitForIndexVersion(arena, try utils.changelogPosition(db), .fromSeconds(15));

    const q = try extract(arena, hashes);
    const results = try utils.searchIndex(arena, q);
    try testing.expect(results.len > 0);
    try testing.expectEqual(id, results[0].id);
    try testing.expectEqual(q.len, results[0].score);
}

test "the changelog serves what the trigger wrote, in order, and paces the consumer" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const db = try utils.connectDb();
    defer db.deinit();
    var prng = std.Random.DefaultPrng.init(2);

    const before = try utils.changelogPosition(db);
    var fingerprints: [3][]u32 = undefined;
    var ids: [3]u32 = undefined;
    for (&fingerprints, &ids) |*hashes, *id| {
        hashes.* = try utils.randomFingerprint(arena, prng.random(), 300);
        id.* = try utils.insertFingerprint(db, hashes.*);
    }

    // Caught up: everything there is, and wait before asking again.
    const all = try readChangelog(arena, before, null);
    try testing.expectEqual(3, all.entries.len);
    try testing.expectEqual(1000, all.retry_after_ms);
    var last = before;
    for (all.entries, fingerprints, ids) |entry, hashes, id| {
        try testing.expect(entry.id > last);
        last = entry.id;
        try testing.expectEqual(id, entry.change.insert.id);
        // The query pg_acoustid extracted in the trigger, and ours, agree.
        try testing.expectEqualSlices(u32, try extract(arena, hashes), entry.change.insert.hashes);
    }

    // A full batch: there is probably more, come straight back.
    const some = try readChangelog(arena, before, 2);
    try testing.expectEqual(2, some.entries.len);
    try testing.expectEqual(0, some.retry_after_ms);

    // Resuming after what was read gives the rest, and nothing again.
    const rest = try readChangelog(arena, some.entries[1].id, null);
    try testing.expectEqual(1, rest.entries.len);
    try testing.expectEqual(all.entries[2].id, rest.entries[0].id);
}

test "the bootstrap streams every fingerprint with its query, but not silence" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const db = try utils.connectDb();
    defer db.deinit();
    var prng = std.Random.DefaultPrng.init(3);

    const hashes = try utils.randomFingerprint(arena, prng.random(), 300);
    const id = try utils.insertFingerprint(db, hashes);
    const silent = try arena.alloc(u32, 100);
    @memset(silent, silence);
    const silent_id = try utils.insertFingerprint(db, silent);
    const position = try utils.changelogPosition(db);

    // The changelog has it all the same, with nothing to index it under.
    const tail = try readChangelog(arena, position - 1, null);
    try testing.expectEqual(silent_id, tail.entries[0].change.insert.id);
    try testing.expectEqual(0, tail.entries[0].change.insert.hashes.len);

    // Chunks of one, so the silent fingerprint is a chunk of its own.
    const response = try utils.get(arena, bootstrap_url ++ "?chunk=1");
    try testing.expectEqual(.ok, response.status);
    var reader: std.Io.Reader = .fixed(response.body);
    const header = try msgpack.decodeLeaky(BootstrapHeader, arena, &reader);
    try testing.expectEqual(position, header.position);

    var found: ?Insert = null;
    var num_inserts: usize = 0;
    while (true) {
        const changes = try msgpack.decodeLeaky([]const Change, arena, &reader);
        if (changes.len == 0) break;
        for (changes) |change| {
            num_inserts += 1;
            try testing.expect(change.insert.id != silent_id);
            if (change.insert.id == id) found = change.insert;
        }
    }
    // The terminator is the last thing in the stream.
    try testing.expectEqual(0, reader.bufferedLen());
    try testing.expect(num_inserts > 1);
    try testing.expectEqualSlices(u32, try extract(arena, hashes), found.?.hashes);
}

test "a consumer below the retention floor is sent away with 410" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const db = try utils.connectDb();
    defer db.deinit();
    var prng = std.Random.DefaultPrng.init(4);

    _ = try utils.insertFingerprint(db, try utils.randomFingerprint(arena, prng.random(), 300));
    // Below where the fpindex node already is, so it carries on undisturbed.
    _ = try db.exec(
        \\INSERT INTO fpindex_meta (last_deleted_id, last_deleted_created, last_deleted_xid)
        \\VALUES (1, now(), pg_current_xact_id())
    , .{});

    // Not even a new node gets what is left: it could not build a complete
    // index from it.
    const below = try utils.get(arena, changelog_url ++ "?after=0");
    try testing.expectEqual(.gone, below.status);
    const at = try utils.get(arena, changelog_url ++ "?after=1");
    try testing.expectEqual(.ok, at.status);

    _ = try db.exec("DELETE FROM fpindex_meta", .{});
}

test "the meta feed announces the one index, once" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const first = try utils.get(arena, feed_url ++ "/_meta?after=0");
    try testing.expectEqual(.ok, first.status);
    const meta = try msgpack.decodeFromSliceLeaky(MetaReadResponse, arena, first.body);
    try testing.expectEqual(1, meta.ops.len);
    try testing.expectEqual(1, meta.ops[0].pos);
    try testing.expectEqual(.create, meta.ops[0].kind);
    try testing.expectEqualStrings("acoustid", meta.ops[0].index_name);

    const after = try utils.get(arena, feed_url ++ "/_meta?after=1");
    try testing.expectEqual(0, (try msgpack.decodeFromSliceLeaky(MetaReadResponse, arena, after.body)).ops.len);
}

test "writes are refused and other lineages are not found" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = utils.io();
    const t = utils.timeout(.fromSeconds(10));

    try testing.expectEqual(.forbidden, (try utils.request(arena, io, .post, changelog_url, "", t)).status);
    try testing.expectEqual(.forbidden, (try utils.request(arena, io, .put, feed_url ++ "/_index/acoustid", null, t)).status);
    try testing.expectEqual(.forbidden, (try utils.request(arena, io, .delete, feed_url ++ "/_index/acoustid", null, t)).status);
    try testing.expectEqual(.forbidden, (try utils.request(arena, io, .post, feed_url ++ "/_truncate/acoustid/1?floor=1", "", t)).status);

    try testing.expectEqual(.not_found, (try utils.get(arena, feed_url ++ "/_changelog/other/1")).status);
    try testing.expectEqual(.not_found, (try utils.get(arena, feed_url ++ "/_changelog/acoustid/2")).status);
    try testing.expectEqual(.not_found, (try utils.get(arena, feed_url ++ "/_bootstrap/acoustid/x")).status);
}

test "the feed is ready when the database answers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const response = try utils.get(arena, feed_url ++ "/_health");
    try testing.expectEqual(.ok, response.status);
    try testing.expectEqualStrings("{\"ready\":true}", response.body);
}
