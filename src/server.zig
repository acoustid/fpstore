const std = @import("std");
const http = @import("dusty");
const msgpack = @import("msgpack");
const json = @import("json");
const pg = @import("pg");
const feed = @import("feed.zig");

pub const ServerContext = struct {
    allocator: std.mem.Allocator,
    db: *pg.Pool,

    pub fn uncaughtError(self: *ServerContext, req: *http.Request, res: *http.Response, err: anyerror) void {
        _ = self;
        // dusty propagates Canceled itself and never passes it here, and the
        // error body is written to memory, so there is nothing to propagate.
        sendError(req, res, err) catch {
            res.body = "{\"error\":\"internal\"}";
        };
    }

    pub fn notFound(self: *ServerContext, req: *http.Request, res: *http.Response) !void {
        _ = self;
        try sendError(req, res, error.NotFound);
    }
};

pub const Server = http.Server(ServerContext);

pub fn registerRoutes(server: *Server) void {
    const r = &server.router;

    r.get("/_health", handleHealth);
    r.head("/_health", handleHealth);

    feed.registerRoutes(server);
}

// --- content negotiation (JSON or MessagePack) ---

const ErrorResponse = struct {
    @"error": []const u8,

    pub fn msgpackFormat() msgpack.StructFormat {
        return .{ .as_map = .{ .key = .{ .field_name_prefix = 1 } } };
    }
};

// Format the request body is in: an explicit Content-Type wins, an explicit
// but unsupported one is rejected, and without one a body is msgpack.
fn requestType(req: *http.Request) !http.ContentType {
    if (req.content_type) |ct| return switch (ct) {
        .json, .msgpack => ct,
        else => error.UnsupportedMediaType,
    };
    const has_body = (try req.body()) != null;
    return if (has_body) .msgpack else .json;
}

// Format to respond in: an explicit Accept wins, else the request's, else
// JSON.
fn responseType(req: *http.Request) !http.ContentType {
    if (req.headers.get("Accept")) |accept| {
        const t = http.ContentType.fromContentType(accept);
        if (t == .json or t == .msgpack) return t;
    }
    return requestType(req) catch |err| switch (err) {
        error.Canceled => err,
        else => .json,
    };
}

/// Responds with `err` as its status and name. Handlers call it themselves
/// for outcomes that are part of the protocol, as dusty logs every error a
/// handler returns as unhandled.
pub fn sendError(req: *http.Request, res: *http.Response, err: anyerror) !void {
    res.status = switch (err) {
        error.BadRequest => .bad_request,
        error.NotFound, error.IndexNotFound => .not_found,
        error.FeedIsReadOnly => .forbidden,
        error.BelowRetention => .gone,
        error.UnsupportedMediaType => .unsupported_media_type,
        else => .internal_server_error,
    };
    try respond(ErrorResponse{ .@"error" = @errorName(err) }, req, res);
}

/// Serializes `value` in the negotiated format.
fn respond(value: anytype, req: *http.Request, res: *http.Response) !void {
    switch (try responseType(req)) {
        .json => try res.encode(.json, json.encode, value),
        .msgpack => try res.encode(.msgpack, msgpack.encode, value),
        else => unreachable,
    }
}

// --- system ---

fn handleHealth(_: *ServerContext, _: *http.Request, res: *http.Response) !void {
    res.body = "OK\n";
}
