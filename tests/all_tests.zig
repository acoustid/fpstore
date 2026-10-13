//! End-to-end tests: fpstore against a real fingerprint database and a real
//! fpindex replicating from it, both run by docker-compose.test.yml.
//!
//!     zig build e2e-tests

const std = @import("std");
const utils = @import("utils.zig");

test {
    _ = @import("feed_test.zig");
}

test "tests:beforeAll" {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // From nothing, whatever a previous run left behind.
    try utils.runDockerCompose(allocator, &.{ "down", "-v", "--remove-orphans" });
    try utils.runDockerCompose(allocator, &.{ "up", "-d", "--wait" });
    try utils.startFpstore(allocator);
    try utils.waitForOk(allocator, utils.fpstore_url ++ "/fpindex/_health", .fromSeconds(10));
    // fpindex creates the index once it reads fpstore's meta feed.
    try utils.waitForOk(allocator, utils.fpindex_url ++ "/" ++ utils.index_name, .fromSeconds(30));
}

test "tests:afterAll" {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    utils.stopFpstore();
    try utils.runDockerCompose(allocator, &.{ "down", "-v" });
}
