const std = @import("std");
const builtin = @import("builtin");
const zio = @import("zio");
const http = @import("dusty");

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
};

fn runServer(allocator: std.mem.Allocator, rt: *zio.Runtime, config: Config) !void {
    const io = rt.io();

    const listeners = [_]http.Listener{.{ .address = .{ .ip = try std.Io.net.IpAddress.parse(config.host, config.port) } }};

    var server_context = ServerContext{};
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

fn parseArgs(args: std.process.Args) !Config {
    var config = Config{};
    var it = std.process.Args.Iterator.init(args);
    _ = it.skip(); // argv[0]
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--host")) {
            config.host = it.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--port")) {
            config.port = try std.fmt.parseInt(u16, it.next() orelse return error.MissingArgument, 10);
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

    const config = try parseArgs(init.args);

    var rt = try zio.Runtime.init(allocator, .{ .executors = .auto });
    defer rt.deinit();

    var task = try zio.spawn(runServer, .{ allocator, rt, config });
    try task.join();
}

test {
    _ = @import("encoding.zig");
    _ = @import("compare.zig");
    _ = @import("server.zig");
}
