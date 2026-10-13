//! The changelog feed fpindex nodes replicate from, served under /fpindex.
//!
//! fpindex's RemoteCoordinator is pointed at it with
//! `--coordinator-url http://<fpstore>/fpindex` (no trailing slash):
//!
//!     GET /fpindex/_changelog/{index}/{generation}?after=&max=
//!     GET /fpindex/_meta?after=&max=
//!     GET /fpindex/_bootstrap/{index}/{generation}?chunk=
//!
//! The changelog itself is fpindex_changelog in the fingerprint database,
//! written by a trigger on `fingerprint`, with the query pg_acoustid extracts.
//! The bootstrap reads the fingerprints and extracts the queries here.
//!
//! **The server never waits.** It answers with whatever is there and tells
//! the consumer how long to sleep before asking again (`retry_after_ms`). Any
//! transaction touching fpindex_changelog locks every partition, so one held
//! open across a wait would block retention from dropping old ones.
//!
//! **410 is load-bearing.** A consumer resuming from a position retention has
//! dropped must get 410 Gone, which fpindex takes as its cue to bootstrap from
//! a peer. A 200 with no entries would leave it waiting forever.
//!
//! The wire types are fpindex's own: msgpack maps keyed by the first letter
//! of each field name, a tagged union as a one-element map.

const std = @import("std");
const http = @import("dusty");
const msgpack = @import("msgpack");
const pg = @import("pg");
const query = @import("query.zig");
const ServerContext = @import("server.zig").ServerContext;
const sendError = @import("server.zig").sendError;

const log = std.log.scoped(.feed);

/// The one index in this deployment. With a single lineage, the changelog's
/// own sequence is that index's position.
pub const index_name = "acoustid";
/// Lineage identity: the position of the index's create op on the meta feed,
/// a constant with one index created once. Still checked on every request,
/// so a consumer following another lineage is told rather than fed this one.
pub const generation: u64 = 1;

/// Bound on what a client can ask for, whatever it sends.
const max_entries = 10000;
/// What a caught-up consumer is told to wait: the knob between feed latency
/// and query load.
const idle_retry_ms = 1000;
/// Told after a full batch, when there is probably more waiting.
const busy_retry_ms = 0;
/// Fingerprints read per transaction while streaming a bootstrap.
const bootstrap_chunk = 1000;
/// How long the health check waits for the database.
const health_timeout_s = 2;

pub fn registerRoutes(server: *@import("server.zig").Server) void {
    const g = server.router.group("/fpindex", &.{});
    g.get("/_changelog/:index/:gen", handleReadChangelog);
    g.get("/_meta", handleReadMeta);
    g.get("/_bootstrap/:index/:gen", handleBootstrap);
    g.get("/_health", handleHealth);
    // Every write the protocol has, refused: the trigger is the only writer,
    // and without these the request would hit a GET-only route, get a 405,
    // and the node would read that as a retryable outage.
    g.post("/_changelog/:index/:gen", handleRefuseWrite);
    g.put("/_index/:index", handleRefuseWrite);
    g.delete("/_index/:index", handleRefuseWrite);
    g.post("/_truncate/:index/:gen", handleRefuseWrite);
}

// --- wire types, as fpindex defines them ---

fn Prefixed() msgpack.StructFormat {
    return .{ .as_map = .{ .key = .{ .field_name_prefix = 1 } } };
}

pub const Insert = struct {
    id: u32,
    hashes: []const u32,
    pub const msgpackFormat = Prefixed;
};

pub const Delete = struct {
    id: u32,
    pub const msgpackFormat = Prefixed;
};

pub const Change = union(enum) {
    insert: Insert,
    delete: Delete,
    pub fn msgpackFormat() msgpack.UnionFormat {
        return .{ .as_map = .{ .key = .{ .field_name_prefix = 1 } } };
    }
};

pub const Entry = struct {
    id: u64,
    change: Change,
    pub const msgpackFormat = Prefixed;
};

pub const ReadResponse = struct {
    entries: []const Entry,
    retry_after_ms: u64,
    pub const msgpackFormat = Prefixed;
};

pub const MetaOp = struct {
    pos: u64,
    kind: Kind,
    index_name: []const u8,
    pub const Kind = enum(u8) { create, delete };
    pub const msgpackFormat = Prefixed;
};

pub const MetaReadResponse = struct {
    ops: []const MetaOp,
    retry_after_ms: u64,
    pub const msgpackFormat = Prefixed;
};

pub const BootstrapHeader = struct {
    position: u64,
    pub const msgpackFormat = Prefixed;
};

/// The whole meta feed: one index, created once, never deleted. A create's
/// position is the generation.
const meta_ops = [_]MetaOp{.{ .pos = generation, .kind = .create, .index_name = index_name }};

// --- handlers ---

/// The lineage in the path, if it is this feed's.
fn checkLineage(req: *http.Request) !void {
    const index = req.params.get("index") orelse "";
    const gen = req.params.get("gen") orelse "";
    const gen_ok = if (std.fmt.parseInt(u64, gen, 10)) |g| g == generation else |_| false;
    if (!std.mem.eql(u8, index, index_name) or !gen_ok) {
        log.warn("requested unknown lineage {f}/{f}", .{ std.zig.fmtString(index), std.zig.fmtString(gen) });
        return error.IndexNotFound;
    }
}

/// A non-negative integer query parameter, clamped to `max`.
fn intParam(req: *http.Request, name: []const u8, default: u64, max: u64) u64 {
    const raw = req.query.get(name) orelse return default;
    const value = std.fmt.parseInt(i64, raw, 10) catch return default;
    return @min(@as(u64, @intCast(@max(value, 0))), max);
}

fn respond(res: *http.Response, value: anytype) !void {
    try res.encode(.msgpack, msgpack.encode, value);
}

fn handleReadChangelog(ctx: *ServerContext, req: *http.Request, res: *http.Response) !void {
    checkLineage(req) catch |err| return try sendError(req, res, err);
    const after = intParam(req, "after", 0, std.math.maxInt(i64));
    const limit = intParam(req, "max", max_entries, max_entries);

    // Everything at or below last_deleted_id is gone. No exemption for a new
    // node at 0 either: it cannot build a complete index from what is left.
    if (try lastDeletedId(ctx.db)) |last_deleted| {
        if (after < last_deleted) {
            log.info("consumer at {d} is below the retention floor {d}", .{ after, last_deleted });
            return try sendError(req, res, error.BelowRetention);
        }
    }

    var entries: std.ArrayList(Entry) = .empty;
    var result = try ctx.db.query(
        \\SELECT id, fingerprint_id, query
        \\FROM fpindex_changelog
        \\WHERE id > $1
        \\ORDER BY id
        \\LIMIT $2
    , .{ @as(i64, @intCast(after)), @as(i64, @intCast(limit)) });
    defer result.deinit();
    while (try result.next()) |row| {
        const hashes = try (try row.get(pg.Iterator(i32), 2)).alloc(req.arena);
        try entries.append(req.arena, .{
            .id = @intCast(try row.get(i64, 0)),
            .change = .{ .insert = .{ .id = @intCast(try row.get(i32, 1)), .hashes = @ptrCast(hashes) } },
        });
    }

    // A full batch means there is probably more behind it. Checked for
    // entries first: with max=0 an empty result is also "full".
    const full = entries.items.len > 0 and entries.items.len == limit;
    try respond(res, ReadResponse{
        .entries = entries.items,
        .retry_after_ms = if (full) busy_retry_ms else idle_retry_ms,
    });
}

/// The highest position retention has dropped, or null if it never has. An
/// empty changelog cannot tell a fresh install from one whose every partition
/// aged out; fpindex_meta only has a row once something was dropped.
fn lastDeletedId(db: *pg.Pool) !?u64 {
    const value = try queryScalar(db, "SELECT last_deleted_id FROM fpindex_meta") orelse return null;
    return @intCast(value);
}

/// The first column of the first row of `sql`, if there is a row.
///
/// Not through `Pool.row`, whose deinit drains the rest of the result and,
/// if that fails, does not give the connection back; and a failure, such as
/// error.Canceled, has to be returned rather than dropped by a defer.
fn queryScalar(db: *pg.Pool, sql: []const u8) !?i64 {
    var result = try db.query(sql, .{});
    // Gives the connection back; one left mid-result is closed instead.
    defer result.deinit();
    const row = try result.next() orelse return null;
    const value = try row.get(i64, 0);
    try result.drain();
    return value;
}

fn handleReadMeta(_: *ServerContext, req: *http.Request, res: *http.Response) !void {
    const after = intParam(req, "after", 0, std.math.maxInt(i64));
    const limit = intParam(req, "max", max_entries, max_entries);
    var first: usize = 0;
    while (first < meta_ops.len and meta_ops[first].pos <= after) first += 1;
    const ops = meta_ops[first..];
    try respond(res, MetaReadResponse{
        .ops = ops[0..@min(ops.len, limit)],
        .retry_after_ms = idle_retry_ms,
    });
}

/// Streams the whole corpus, for a node that has nothing: the changelog
/// starts at its migration, so replaying it from 0 misses every older
/// fingerprint.
///
/// A msgpack header with the changelog position, then arrays of changes, then
/// an empty array, which appears nowhere else, so a stream cut short is never
/// read as complete.
///
/// Correct without holding a snapshot open. The position is read first and
/// the fingerprints in chunks, each its own transaction. A fingerprint there
/// when the position was read is still there for its chunk, as fingerprints
/// are never deleted or changed; anything inserted during the scan has a
/// changelog entry above the position; and replaying from it afterwards costs
/// nothing for what overlaps, as inserts are upserts by id. A single snapshot
/// would hold back vacuum database-wide for the whole scan.
///
/// Writing a chunk waits for the client to take it before the next is read,
/// so a slow node slows the scan down rather than the scan racing ahead.
fn handleBootstrap(ctx: *ServerContext, req: *http.Request, res: *http.Response) !void {
    checkLineage(req) catch |err| return try sendError(req, res, err);
    // At least 1: LIMIT 0 would read nothing, which looks like the end.
    const chunk = @max(1, intParam(req, "chunk", bootstrap_chunk, max_entries));
    const position = try currentPosition(ctx.db);

    // The corpus takes longer than the server's request timeout.
    req.setTimeout(.none);
    res.content_type = .msgpack;
    var buf: [64 * 1024]u8 = undefined;
    var body = try res.stream(&buf);
    const w = &body.interface;

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();

    var streamed: usize = 0;
    var last_id: i32 = 0;
    writeBootstrap: {
        msgpack.encode(BootstrapHeader{ .position = position }, w) catch |err| switch (err) {
            error.WriteFailed => break :writeBootstrap,
            else => return err,
        };
        while (true) {
            _ = arena_state.reset(.retain_capacity);
            const arena = arena_state.allocator();
            var changes: std.ArrayList(Change) = .empty;
            var num_rows: usize = 0;
            {
                var result = try ctx.db.query(
                    \\SELECT id, fingerprint
                    \\FROM fingerprint
                    \\WHERE id > $1
                    \\ORDER BY id
                    \\LIMIT $2
                , .{ last_id, @as(i64, @intCast(chunk)) });
                defer result.deinit();
                while (try result.next()) |row| {
                    num_rows += 1;
                    last_id = try row.get(i32, 0);
                    const fingerprint = try (try row.get(pg.Iterator(i32), 1)).alloc(arena);
                    var out: [query.max_length]u32 = undefined;
                    const q = query.extract(@ptrCast(fingerprint), &out);
                    // All silence extracts to nothing, a document that could
                    // never match.
                    if (q.len == 0) continue;
                    try changes.append(arena, .{ .insert = .{ .id = @intCast(last_id), .hashes = try arena.dupe(u32, q) } });
                }
            }
            if (num_rows == 0) break;
            // An empty array is the terminator, so a chunk of nothing but
            // silence stays off the wire.
            if (changes.items.len == 0) continue;
            msgpack.encode(@as([]const Change, changes.items), w) catch |err| switch (err) {
                error.WriteFailed => break :writeBootstrap,
                else => return err,
            };
            streamed += changes.items.len;
        }
        msgpack.encode(@as([]const Change, &.{}), w) catch |err| switch (err) {
            error.WriteFailed => break :writeBootstrap,
            else => return err,
        };
        try body.end();
        log.info("bootstrap streamed {d} fingerprints at position {d}", .{ streamed, position });
        return;
    }
    // What the write failed on: the client going away, or error.Canceled.
    return body.err orelse error.WriteFailed;
}

fn currentPosition(db: *pg.Pool) !u64 {
    return @intCast(try queryScalar(db, "SELECT coalesce(max(id), 0)::bigint FROM fpindex_changelog") orelse 0);
}

/// Readiness: whether the database answers, as that is all the feed needs.
/// Deliberately not about how far consumers have got, which would take the
/// feed away when nodes need it most.
fn handleHealth(ctx: *ServerContext, req: *http.Request, res: *http.Response) !void {
    // A database that accepts the connection and never answers would hold a
    // probe for the whole request timeout.
    req.setTimeout(.{ .duration = .{ .raw = .fromSeconds(health_timeout_s), .clock = .awake } });
    _ = ctx.db.exec("SELECT 1", .{}) catch |err| {
        // Past the deadline the connection is dropped without an answer,
        // which a probe takes as a failure too.
        if (err == error.Canceled) return err;
        log.err("fingerprint database unreachable: {t}", .{err});
        res.status = .service_unavailable;
        res.body = "{\"ready\":false}";
        res.content_type = .json;
        return;
    };
    res.body = "{\"ready\":true}";
    res.content_type = .json;
}

/// The changelog is written by the trigger on `fingerprint`, the index is
/// created once, and retention is the maintenance job's, so nothing here
/// accepts a write. 403 says that is on purpose, where a 503 would be retried.
fn handleRefuseWrite(_: *ServerContext, req: *http.Request, res: *http.Response) !void {
    log.warn("refusing {t} {f}: the feed is read-only", .{ req.method, std.zig.fmtString(req.url) });
    try sendError(req, res, error.FeedIsReadOnly);
}

const testing = std.testing;

/// Encodes `value` and compares it against hand-written bytes, the structure
/// acoustid-server's feed tests pin too. A round trip through the types above
/// would pass just as happily with every key wrong.
fn expectWire(value: anytype, expected: []const u8) !void {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try msgpack.encode(value, &aw.writer);
    try testing.expectEqualSlices(u8, expected, aw.written());
}

test "changelog response wire format" {
    // {"e": [{"i": 7, "c": {"i": {"i": 42, "h": [1, 2, 3]}}}], "r": 250}
    try expectWire(ReadResponse{
        .entries = &.{.{ .id = 7, .change = .{ .insert = .{ .id = 42, .hashes = &.{ 1, 2, 3 } } } }},
        .retry_after_ms = 250,
    }, "\x82" ++ "\xa1e" ++ "\x91" ++
        "\x82" ++ "\xa1i" ++ "\x07" ++ "\xa1c" ++ "\x81" ++ "\xa1i" ++
        "\x82" ++ "\xa1i" ++ "\x2a" ++ "\xa1h" ++ "\x93\x01\x02\x03" ++
        "\xa1r" ++ "\xcc\xfa");
    // {"e": [], "r": 1000}
    try expectWire(ReadResponse{ .entries = &.{}, .retry_after_ms = 1000 }, "\x82\xa1e\x90\xa1r\xcd\x03\xe8");
    // {"d": {"i": 42}}
    try expectWire(Change{ .delete = .{ .id = 42 } }, "\x81\xa1d\x81\xa1i\x2a");
}

test "meta response wire format, with the kind as an integer" {
    // {"o": [{"p": 1, "k": 0, "i": "acoustid"}], "r": 1000}
    try expectWire(MetaReadResponse{ .ops = &meta_ops, .retry_after_ms = 1000 }, "\x82" ++ "\xa1o" ++ "\x91" ++
        "\x83" ++ "\xa1p" ++ "\x01" ++ "\xa1k" ++ "\x00" ++ "\xa1i" ++ "\xa8acoustid" ++
        "\xa1r" ++ "\xcd\x03\xe8");
}

test "bootstrap header wire format" {
    // {"p": 5}
    try expectWire(BootstrapHeader{ .position = 5 }, "\x81\xa1p\x05");
}
