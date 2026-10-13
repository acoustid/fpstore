const std = @import("std");
const builtin = @import("builtin");
const zio = @import("zio");
const http = @import("dusty");
const pg = @import("pg");

const Server = @import("server.zig").Server;
const ServerContext = @import("server.zig").ServerContext;
const registerRoutes = @import("server.zig").registerRoutes;

// Process allocator: a leak-checking DebugAllocator in Debug builds, the C
// allocator (malloc) otherwise, which scales better under many threads.
const RootAllocator = struct {
    const use_debug = builtin.mode == .debug;
    gpa: if (use_debug) std.heap.DebugAllocator(.{}) else void,

    fn init() RootAllocator {
        return .{ .gpa = if (use_debug) .{} else {} };
    }

    fn allocator(self: *RootAllocator) std.mem.Allocator {
        return if (use_debug) self.gpa.allocator() else std.heap.c_allocator;
    }

    fn deinit(self: *RootAllocator) void {
        if (use_debug) _ = self.gpa.deinit();
    }
};

const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 4659,
    postgres_host: []const u8 = "127.0.0.1",
    postgres_port: u16 = 5432,
    postgres_user: []const u8 = "acoustid",
    postgres_password: ?[]const u8 = null,
    postgres_database: []const u8 = "acoustid",
    postgres_pool_size: u16 = 10,
};

fn runServer(allocator: std.mem.Allocator, rt: *zio.Runtime, config: Config) !void {
    const io = rt.io();

    // Connections are opened as they are needed, so fpstore starts, and
    // answers its health checks, while the database is down.
    const db = try pg.Pool.init(io, allocator, .{
        .size = config.postgres_pool_size,
        .connect_on_init_count = 0,
        .connect = .{ .host = config.postgres_host, .port = config.postgres_port },
        .auth = .{
            .username = config.postgres_user,
            .password = config.postgres_password,
            .database = config.postgres_database,
            .application_name = "fpstore",
        },
    });
    defer db.deinit();

    const listeners = [_]http.Listener{.{ .address = .{ .ip = try std.Io.net.IpAddress.parse(config.host, config.port) } }};

    var server_context = ServerContext{ .allocator = allocator, .db = db };
    var server = Server.init(allocator, io, .{ .listeners = &listeners }, &server_context);
    defer server.deinit();

    registerRoutes(&server);

    var sigint = try zio.Signal.init(.interrupt);
    defer sigint.deinit();
    var sigterm = try zio.Signal.init(.terminate);
    defer sigterm.deinit();

    std.log.info("fpstore listening on http://{s}:{d}", .{ config.host, config.port });

    var http_task = try zio.spawn(Server.run, .{&server});
    defer http_task.cancel();

    const result = try zio.select(.{ .http = &http_task, .sigint = &sigint, .sigterm = &sigterm });
    switch (result) {
        .http => |r| return r,
        .sigint, .sigterm => {
            std.log.info("shutting down", .{});
            http_task.cancel();
        },
    }
}

/// Settings from the environment, which command-line flags override. The
/// password is best given this way, as the command line is visible to others.
fn readEnv(config: *Config, environ: std.process.Environ) !void {
    if (environ.getPosix("FPSTORE_POSTGRES_HOST")) |v| config.postgres_host = v;
    if (environ.getPosix("FPSTORE_POSTGRES_PORT")) |v| config.postgres_port = try std.fmt.parseInt(u16, v, 10);
    if (environ.getPosix("FPSTORE_POSTGRES_USER")) |v| config.postgres_user = v;
    if (environ.getPosix("FPSTORE_POSTGRES_PASSWORD")) |v| config.postgres_password = v;
    if (environ.getPosix("FPSTORE_POSTGRES_DATABASE")) |v| config.postgres_database = v;
}

fn parseArgs(args: std.process.Args, environ: std.process.Environ) !Config {
    var config = Config{};
    try readEnv(&config, environ);
    var it = std.process.Args.Iterator.init(args);
    _ = it.skip(); // argv[0]
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--host")) {
            config.host = it.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--port")) {
            config.port = try std.fmt.parseInt(u16, it.next() orelse return error.MissingArgument, 10);
        } else if (std.mem.eql(u8, arg, "--postgres-host")) {
            config.postgres_host = it.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--postgres-port")) {
            config.postgres_port = try std.fmt.parseInt(u16, it.next() orelse return error.MissingArgument, 10);
        } else if (std.mem.eql(u8, arg, "--postgres-user")) {
            config.postgres_user = it.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--postgres-database")) {
            config.postgres_database = it.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--postgres-pool-size")) {
            config.postgres_pool_size = try std.fmt.parseInt(u16, it.next() orelse return error.MissingArgument, 10);
        } else {
            std.log.warn("ignoring unknown argument '{s}'", .{arg});
        }
    }
    return config;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var root_allocator = RootAllocator.init();
    defer root_allocator.deinit();
    const allocator = root_allocator.allocator();

    const config = try parseArgs(init.args, init.environ);

    var rt = try zio.Runtime.init(allocator, .{ .executors = .auto });
    defer rt.deinit();

    var task = try zio.spawn(runServer, .{ allocator, rt, config });
    try task.join();
}

test {
    _ = @import("encoding.zig");
    _ = @import("compare.zig");
    _ = @import("query.zig");
    _ = @import("feed.zig");
    _ = @import("server.zig");
}
