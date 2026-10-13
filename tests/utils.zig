//! What the end-to-end tests share: the services docker-compose.test.yml
//! runs, the fpstore they start, and ways to talk to each.
//!
//! The setup and teardown hooks run on std.testing.io; tests run in a zio
//! runtime of their own, whose Io is `io()`.

const std = @import("std");
const http = @import("dusty");
const msgpack = @import("msgpack");
const pg = @import("pg");
const build_options = @import("build_options");

pub const fpstore_port = 14660;
pub const fpindex_port = 16081;
pub const postgres_port = 15433;

pub const fpstore_url = std.fmt.comptimePrint("http://127.0.0.1:{d}", .{fpstore_port});
pub const fpindex_url = std.fmt.comptimePrint("http://127.0.0.1:{d}", .{fpindex_port});

pub const index_name = "acoustid";

/// The Io of the running test's zio runtime, from the test runner.
pub fn io() std.Io {
    return @import("root").testIo();
}

pub fn timeout(duration: std.Io.Duration) std.Io.Timeout {
    return .{ .duration = .{ .raw = duration, .clock = .awake } };
}

// --- setup, on std.testing.io ---

pub fn runDockerCompose(allocator: std.mem.Allocator, compose_args: []const []const u8) !void {
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    try args.appendSlice(allocator, &.{ "docker", "compose", "-f", "docker-compose.test.yml", "-p", "fpstore-test" });
    try args.appendSlice(allocator, compose_args);

    const result = try std.process.run(allocator, std.testing.io, .{ .argv = args.items });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    std.debug.print("docker compose {s} failed:\n{s}\n", .{ compose_args[0], result.stderr });
    return error.DockerComposeFailed;
}

var fpstore_process: ?std.process.Child = null;

/// Starts the fpstore under test, with its output in zig-out/e2e/fpstore.log.
pub fn startFpstore(allocator: std.mem.Allocator) !void {
    const setup_io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(setup_io, "zig-out/e2e");
    const log_file = try cwd.createFile(setup_io, "zig-out/e2e/fpstore.log", .{});
    defer log_file.close(setup_io);

    var environ: std.process.Environ.Map = .init(allocator);
    defer environ.deinit();
    try environ.put("FPSTORE_POSTGRES_PASSWORD", "acoustid");

    var port_buf: [8]u8 = undefined;
    var postgres_port_buf: [8]u8 = undefined;
    fpstore_process = try std.process.spawn(setup_io, .{
        .argv = &.{
            build_options.fpstore_exe,
            "--port",
            try std.fmt.bufPrint(&port_buf, "{d}", .{fpstore_port}),
            "--postgres-port",
            try std.fmt.bufPrint(&postgres_port_buf, "{d}", .{postgres_port}),
        },
        .environ_map = &environ,
        .stdin = .ignore,
        .stdout = .{ .file = log_file },
        .stderr = .{ .file = log_file },
    });
}

pub fn stopFpstore() void {
    if (fpstore_process) |*child| child.kill(std.testing.io);
    fpstore_process = null;
}

/// Waits until `url` answers 200. Each attempt is unbounded, as dusty's
/// timeouts need a zio runtime; a server that is not up yet refuses at once.
pub fn waitForOk(allocator: std.mem.Allocator, url: []const u8, max_wait: std.Io.Duration) !void {
    const setup_io = std.testing.io;
    const start = std.Io.Timestamp.now(setup_io, .awake);
    while (true) {
        if (request(allocator, setup_io, .get, url, null, .none)) |response| {
            allocator.free(response.body);
            if (response.status == .ok) return;
        } else |err| switch (err) {
            error.Canceled => return err,
            else => {},
        }
        if (start.untilNow(setup_io, .awake).nanoseconds > max_wait.nanoseconds) {
            std.debug.print("{s} did not answer 200 in time\n", .{url});
            return error.Timeout;
        }
        try setup_io.sleep(.fromMilliseconds(100), .awake);
    }
}

// --- HTTP ---

pub const Response = struct {
    status: http.Status,
    body: []u8,
};

/// One HTTP request. A body goes without a Content-Type, which fpstore and
/// fpindex both read as msgpack. The body of the response is the caller's.
pub fn request(
    allocator: std.mem.Allocator,
    client_io: std.Io,
    method: http.Method,
    url: []const u8,
    body: ?[]const u8,
    request_timeout: std.Io.Timeout,
) !Response {
    var client = http.Client.init(allocator, client_io, .{});
    defer client.deinit();
    var response = try client.fetch(url, .{ .method = method, .body = body, .timeout = request_timeout });
    defer response.deinit();
    return .{
        .status = response.status(),
        .body = try allocator.dupe(u8, (try response.body()) orelse ""),
    };
}

/// A request from a test, on its runtime.
pub fn get(allocator: std.mem.Allocator, url: []const u8) !Response {
    return request(allocator, io(), .get, url, null, timeout(.fromSeconds(10)));
}

// --- the database ---

pub fn connectDb() !*pg.Pool {
    return pg.Pool.init(io(), std.testing.allocator, .{
        .size = 1,
        .connect = .{ .port = postgres_port },
        .auth = .{ .username = "acoustid", .password = "acoustid", .database = "acoustid" },
    });
}

/// The first column of the first row of `sql`, if there is a row.
pub fn queryScalar(db: *pg.Pool, comptime T: type, sql: []const u8, values: anytype) !?T {
    var result = try db.query(sql, values);
    defer result.deinit();
    const row = try result.next() orelse return null;
    const value = try row.get(T, 0);
    try result.drain();
    return value;
}

/// Stores a fingerprint as acoustid-server would, which also puts it in the
/// changelog through the trigger. Returns its id.
pub fn insertFingerprint(db: *pg.Pool, hashes: []const u32) !u32 {
    const signed: []const i32 = @ptrCast(hashes);
    const id = try queryScalar(db, i32,
        \\INSERT INTO fingerprint (fingerprint, length, track_id, submission_count)
        \\VALUES ($1::int4[], 100, 1, 1)
        \\RETURNING id
    , .{signed});
    return @intCast(id.?);
}

/// The changelog position of the newest entry, 0 if there is none.
pub fn changelogPosition(db: *pg.Pool) !u64 {
    return @intCast((try queryScalar(db, i64, "SELECT coalesce(max(id), 0)::bigint FROM fpindex_changelog", .{})).?);
}

pub fn randomFingerprint(allocator: std.mem.Allocator, random: std.Random, len: usize) ![]u32 {
    const hashes = try allocator.alloc(u32, len);
    random.bytes(std.mem.sliceAsBytes(hashes));
    return hashes;
}

// --- fpindex ---

/// Waits until fpindex has applied the changelog up to `position`.
pub fn waitForIndexVersion(allocator: std.mem.Allocator, position: u64, max_wait: std.Io.Duration) !void {
    const start = std.Io.Timestamp.now(io(), .awake);
    var version: u64 = 0;
    while (true) {
        const response = try get(allocator, fpindex_url ++ "/" ++ index_name);
        defer allocator.free(response.body);
        if (response.status == .ok) {
            const info = try std.json.parseFromSlice(struct { version: u64 }, allocator, response.body, .{ .ignore_unknown_fields = true });
            defer info.deinit();
            version = info.value.version;
            if (version >= position) return;
        }
        if (start.untilNow(io(), .awake).nanoseconds > max_wait.nanoseconds) {
            std.debug.print("fpindex is at {d}, waited for {d}\n", .{ version, position });
            return error.Timeout;
        }
        try io().sleep(.fromMilliseconds(100), .awake);
    }
}

pub fn Prefixed() msgpack.StructFormat {
    return .{ .as_map = .{ .key = .{ .field_name_prefix = 1 } } };
}

pub const SearchResult = struct {
    id: u32,
    score: u32,
    pub const msgpackFormat = Prefixed;
};

/// Searches fpindex directly, by a query as src/query.zig extracts it.
pub fn searchIndex(arena: std.mem.Allocator, query: []const u32) ![]SearchResult {
    var body: std.Io.Writer.Allocating = .init(arena);
    try msgpack.encode(struct {
        query: []const u32,
        limit: u32,
        pub const msgpackFormat = Prefixed;
    }{ .query = query, .limit = 10 }, &body.writer);
    const response = try request(arena, io(), .post, fpindex_url ++ "/" ++ index_name ++ "/_search", body.written(), timeout(.fromSeconds(10)));
    if (response.status != .ok) {
        std.debug.print("fpindex search answered {d}: {s}\n", .{ @intFromEnum(response.status), response.body });
        return error.SearchFailed;
    }
    const parsed = try msgpack.decodeFromSliceLeaky(struct {
        results: []SearchResult,
        pub const msgpackFormat = Prefixed;
    }, arena, response.body);
    return parsed.results;
}
