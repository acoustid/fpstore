//! The similarity of two fingerprints, the score fpstore has been returning
//! for lookups.
//!
//! The fingerprints are aligned on the offset where most of their hashes,
//! masked to 14 bits, match, and scored by the bit error between the aligned
//! hashes, scaled by how much of the shorter one overlaps and penalised when
//! either is repetitive.
//!
//! It is checked against scores from the previous implementation, but is
//! not meant to match them bit for bit. When peaks tie for the best offset,
//! the first one is used.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const max_offset = 80;
/// The longest fingerprint compared.
pub const max_hashes = (1 << 16) - 1;

const align_bits = 14;
const unique_bits = 16;
const max_offset_threshold_div = 10;

/// A Gaussian kernel of width 3 and sigma 1.3.
const gaussian_kernel = blk: {
    const sigma = 1.3;
    var kernel: [3]f64 = undefined;
    var sum: f64 = 0;
    for (&kernel, 0..) |*k, i| {
        const x: f64 = @as(f64, @floatFromInt(i)) - 1;
        k.* = @exp(-x * x / (2 * sigma * sigma));
        sum += k.*;
    }
    for (&kernel) |*k| k.* /= sum;
    break :blk kernel;
};

pub const Error = error{FingerprintTooLong} || Allocator.Error;

/// The similarity of `master` and `query`, from 0 to 1.
pub fn compare(allocator: Allocator, master: []const u32, query: []const u32) Error!f32 {
    if (master.len > max_hashes or query.len > max_hashes) return error.FingerprintTooLong;
    const hit = try alignFingerprints(allocator, master, query) orelse return 0;
    return compareAligned(master, query, hit);
}

const OffsetHit = struct {
    /// Where `query` starts in `master`.
    offset: i32,
    count: f64,
};

/// `num_bits` bits, the odd ones first, then the even.
fn hashBitMask(comptime num_bits: u6) u32 {
    var mask: u32 = 0xaaaaaaaa;
    if (num_bits <= 16) {
        mask &= @truncate((@as(u64, 1) << (num_bits * 2)) - 1);
    } else {
        mask |= 0x55555555 & @as(u32, @truncate((@as(u64, 1) << ((num_bits - 16) * 2)) - 1));
    }
    return mask;
}

const HashOffset = struct {
    hash: u32,
    offset: u32,

    fn lessThan(_: void, a: HashOffset, b: HashOffset) bool {
        return a.hash < b.hash;
    }
};

fn maskedHashes(allocator: Allocator, hashes: []const u32) Allocator.Error![]HashOffset {
    const mask = hashBitMask(align_bits);
    const result = try allocator.alloc(HashOffset, hashes.len);
    for (hashes, result, 0..) |hash, *r, i| r.* = .{ .hash = hash & mask, .offset = @intCast(i) };
    // Which of the equal hashes comes first does not matter, every pair of
    // them is counted.
    std.sort.pdq(HashOffset, result, {}, HashOffset.lessThan);
    return result;
}

/// The highest peak of the offset histogram, if any is high enough.
fn alignFingerprints(allocator: Allocator, master: []const u32, query: []const u32) Allocator.Error!?OffsetHit {
    const master_hashes = try maskedHashes(allocator, master);
    defer allocator.free(master_hashes);
    const query_hashes = try maskedHashes(allocator, query);
    defer allocator.free(query_hashes);

    // A histogram of the offsets between every pair of matching hashes.
    const num_counts = master.len + query.len + 1;
    const counts = try allocator.alloc(f64, num_counts);
    defer allocator.free(counts);
    @memset(counts, 0);
    var i: usize = 0;
    for (master_hashes) |m| {
        while (i < query_hashes.len and query_hashes[i].hash < m.hash) i += 1;
        if (i >= query_hashes.len) break;
        var j = i;
        while (j < query_hashes.len and query_hashes[j].hash == m.hash) : (j += 1) {
            const offset = @as(i32, @intCast(m.offset)) - @as(i32, @intCast(query_hashes[j].offset));
            if (-max_offset <= offset and offset <= max_offset) {
                counts[@intCast(offset + @as(i32, @intCast(query.len)))] += 1;
            }
        }
    }

    const smoothed = try allocator.alloc(f64, num_counts);
    defer allocator.free(smoothed);
    convolveReflect(counts, smoothed, &gaussian_kernel);

    var top_count: f64 = 0;
    for (smoothed) |c| {
        if (c > top_count) top_count = c;
    }
    const count_threshold = @max(top_count / max_offset_threshold_div, 2);

    // The highest peak above the threshold.
    var best: ?OffsetHit = null;
    for (smoothed, 0..) |count, offset| {
        if (count < count_threshold) continue;
        if (best != null and count <= best.?.count) continue;
        const previous_count = if (offset > 0) smoothed[offset - 1] else 0;
        const next_count = if (offset < smoothed.len - 1) smoothed[offset + 1] else 0;
        if (previous_count <= count and next_count < count) {
            best = .{
                .offset = @as(i32, @intCast(offset)) - @as(i32, @intCast(query.len)),
                .count = count,
            };
        }
    }
    return best;
}

/// Convolves `src` with `kernel`, reflecting it at the borders.
fn convolveReflect(src: []const f64, dst: []f64, kernel: []const f64) void {
    const width = kernel.len;
    const half_width = width / 2;
    const n: isize = @intCast(src.len);
    for (dst, 0..) |*d, i| {
        const k = @as(isize, @intCast(i)) - @as(isize, @intCast(half_width));
        var sum: f64 = 0;
        if (k >= 0 and k <= n - @as(isize, @intCast(width))) {
            for (kernel, 0..) |x, j| sum += src[@intCast(k + @as(isize, @intCast(j)))] * x;
        } else {
            for (kernel, 0..) |x, j| sum += reflect(src, k + @as(isize, @intCast(j))) * x;
        }
        d.* = sum;
    }
}

fn reflect(src: []const f64, index: isize) f64 {
    const n: isize = @intCast(src.len);
    if (index >= 0 and index < n) return src[@intCast(index)];
    if (n == 1) return src[0];
    var i = index;
    while (i < 0 or i >= n) {
        i = if (i < 0) -i - 1 else 2 * n - i - 1;
    }
    return src[@intCast(i)];
}

/// The score of the fingerprints aligned at `hit`.
fn compareAligned(master: []const u32, query: []const u32, hit: OffsetHit) f32 {
    var a = master;
    var b = query;
    const min_size = @min(a.len, b.len);
    if (min_size == 0) return 0;
    if (hit.offset < 0) {
        b = b[@intCast(-hit.offset)..];
    } else {
        a = a[@intCast(hit.offset)..];
    }
    const size = @min(a.len, b.len);
    if (size == 0) return 0;

    const a_unique = countUniqueHashes(a);
    const b_unique = countUniqueHashes(b);
    if (hit.count < @as(f64, @floatFromInt(@max(a_unique, b_unique))) * 0.02) return 0;

    const diversity = @min(
        @min(1.0, @as(f64, @floatFromInt(a_unique + 10)) / @as(f64, @floatFromInt(a.len)) + 0.5),
        @min(1.0, @as(f64, @floatFromInt(b_unique + 10)) / @as(f64, @floatFromInt(b.len)) + 0.5),
    );

    var bit_error: u64 = 0;
    for (a[0..size], b[0..size]) |x, y| bit_error += @popCount(x ^ y);

    const size_f: f64 = @floatFromInt(size);
    var score = (size_f / @as(f64, @floatFromInt(min_size))) *
        (1.0 - @as(f64, @floatFromInt(bit_error)) / @as(f64, @floatFromInt(size * 32)));
    if (score < 0) score = 0;
    if (diversity < 1) score = std.math.pow(f64, score, 8.0 - 7.0 * diversity);
    return @floatCast(score);
}

/// How many different values the hashes have, masked to 16 bits.
fn countUniqueHashes(hashes: []const u32) usize {
    comptime std.debug.assert(hashBitMask(unique_bits) == 0xaaaaaaaa);
    var seen: std.StaticBitSet(1 << 16) = .empty;
    for (hashes) |hash| {
        // The 16 odd bits, gathered into the low 16.
        var x = (hash >> 1) & 0x55555555;
        x = (x | (x >> 1)) & 0x33333333;
        x = (x | (x >> 2)) & 0x0f0f0f0f;
        x = (x | (x >> 4)) & 0x00ff00ff;
        x = (x | (x >> 8)) & 0x0000ffff;
        seen.set(x);
    }
    return seen.count();
}

const testing = std.testing;
const chromaprint = @import("chromaprint.zig");

/// Fingerprints and the results the previous implementation gives for pairs
/// of them, generated by tools/compare-golden: real fingerprints of the same
/// tracks and of different ones, and variants of some of them that are
/// shifted, cut, noisy, edited in the middle, or a short loop.
const golden_fingerprints = @embedFile("testdata/compare/fingerprints.bin");
const golden_pairs = @embedFile("testdata/compare/pairs.txt");

fn loadGoldenFingerprints(allocator: Allocator) ![][]u32 {
    var list: std.ArrayList([]u32) = .empty;
    errdefer {
        for (list.items) |fp| allocator.free(fp);
        list.deinit(allocator);
    }
    var pos: usize = 0;
    while (pos < golden_fingerprints.len) {
        const len = std.mem.readInt(u32, golden_fingerprints[pos..][0..4], .little);
        const data = golden_fingerprints[pos + 4 ..][0..len];
        pos += 4 + len;
        const header = try chromaprint.decodeHeader(data);
        const hashes = try allocator.alloc(u32, header.num_hashes);
        errdefer allocator.free(hashes);
        const scratch = try allocator.alloc(u8, chromaprint.decodeScratchSize(data.len));
        defer allocator.free(scratch);
        _ = try chromaprint.decode(data, hashes, scratch);
        try list.append(allocator, hashes);
    }
    return list.toOwnedSlice(allocator);
}

test "matches the previous implementation on real and modified fingerprints" {
    const allocator = testing.allocator;
    const fingerprints = try loadGoldenFingerprints(allocator);
    defer {
        for (fingerprints) |fp| allocator.free(fp);
        allocator.free(fingerprints);
    }

    var num_pairs: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, golden_pairs, '\n');
    while (lines.next()) |line| {
        if (line[0] == '#') continue;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const master = fingerprints[try std.fmt.parseInt(usize, fields.next().?, 10)];
        const query = fingerprints[try std.fmt.parseInt(usize, fields.next().?, 10)];
        const num_peaks = try std.fmt.parseInt(usize, fields.next().?, 10);
        const offset = try std.fmt.parseInt(i32, fields.next().?, 10);
        const count: f64 = @bitCast(try std.fmt.parseInt(u64, fields.next().?, 16));
        const score: f32 = @bitCast(try std.fmt.parseInt(u32, fields.next().?, 16));

        errdefer std.debug.print("pair: {s}\n", .{line});
        num_pairs += 1;
        const actual = try compare(allocator, master, query);
        const hit = try alignFingerprints(allocator, master, query);
        const same_peak = if (hit) |h| num_peaks > 0 and h.offset == offset else num_peaks == 0;
        if (same_peak) {
            if (hit) |h| try testing.expectApproxEqRel(count, h.count, 1e-9);
            try testing.expectApproxEqAbs(score, actual, 1e-6);
        } else {
            // Peaks that tie, as in a short loop, or one right at the
            // threshold can come out the other way, but not in a match.
            try testing.expect(score < 0.2 and actual < 0.2);
        }
    }
    try testing.expect(num_pairs > 400);
}

test "fingerprints that are too long are refused" {
    const long = try testing.allocator.alloc(u32, max_hashes + 1);
    defer testing.allocator.free(long);
    @memset(long, 0);
    try testing.expectError(error.FingerprintTooLong, compare(testing.allocator, long, &.{1}));
    try testing.expectError(error.FingerprintTooLong, compare(testing.allocator, &.{1}, long));
}

test "empty fingerprints score zero" {
    try testing.expectEqual(0, try compare(testing.allocator, &.{}, &.{}));
    try testing.expectEqual(0, try compare(testing.allocator, &.{ 1, 2, 3 }, &.{}));
}
