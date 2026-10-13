const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zio_dep = b.dependency("zio", .{ .target = target, .optimize = optimize });
    const dusty_dep = b.dependency("dusty", .{ .target = target, .optimize = optimize });
    const msgpack_dep = b.dependency("msgpack", .{ .target = target, .optimize = optimize });
    const json_dep = b.dependency("json", .{ .target = target, .optimize = optimize });
    const pg_dep = b.dependency("pg", .{ .target = target, .optimize = optimize });

    // dusty's own zio import is a stub that makes it time requests out with a
    // portable watchdog; with the real one it uses zio's cancellation.
    dusty_dep.module("dusty").addImport("zio", zio_dep.module("zio"));

    const exe = b.addExecutable(.{
        .name = "fpstore",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zio", .module = zio_dep.module("zio") },
                .{ .name = "dusty", .module = dusty_dep.module("dusty") },
                .{ .name = "msgpack", .module = msgpack_dep.module("msgpack") },
                .{ .name = "json", .module = json_dep.module("json") },
                .{ .name = "pg", .module = pg_dep.module("pg") },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the server");
    run_step.dependOn(&run_cmd.step);

    // Generates src/testdata/query/golden.txt from pg_acoustid, see
    // tools/query-golden/main.zig. Not part of the default build.
    const query_golden = b.addExecutable(.{
        .name = "query-golden",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/query-golden/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zio", .module = zio_dep.module("zio") },
                .{ .name = "pg", .module = pg_dep.module("pg") },
                .{ .name = "encoding", .module = b.createModule(.{
                    .root_source_file = b.path("src/encoding.zig"),
                    .target = target,
                    .optimize = optimize,
                }) },
            },
        }),
    });
    const run_query_golden = b.addRunArtifact(query_golden);
    run_query_golden.setCwd(b.path("."));
    run_query_golden.addPassthruArgs();
    b.step("query-golden", "Generate the query extraction test data from pg_acoustid").dependOn(&run_query_golden.step);

    // Both test suites go through test_runner.zig, which runs every test in a
    // zio runtime of its own.
    const unit_tests = b.addTest(.{
        .root_module = exe.root_module,
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("unit-tests", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // End-to-end tests, against the fpstore binary, with the database and an
    // fpindex node from docker-compose.test.yml, which they start and stop.
    const e2e_options = b.addOptions();
    e2e_options.addOptionPath("fpstore_exe", exe.getEmittedBin());
    const e2e_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/all_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zio", .module = zio_dep.module("zio") },
                .{ .name = "dusty", .module = dusty_dep.module("dusty") },
                .{ .name = "msgpack", .module = msgpack_dep.module("msgpack") },
                .{ .name = "pg", .module = pg_dep.module("pg") },
                .{ .name = "query", .module = b.createModule(.{
                    .root_source_file = b.path("src/query.zig"),
                    .target = target,
                    .optimize = optimize,
                }) },
                .{ .name = "build_options", .module = e2e_options.createModule() },
            },
        }),
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
    });
    const run_e2e_tests = b.addRunArtifact(e2e_tests);
    run_e2e_tests.setCwd(b.path("."));
    run_e2e_tests.has_side_effects = true;
    b.step("e2e-tests", "Run end-to-end tests (requires Docker)").dependOn(&run_e2e_tests.step);
}
