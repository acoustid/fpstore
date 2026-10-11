//! The similarity of two fingerprints, ported from go-acoustid's
//! `CompareFingerprints` (pkg/chromaprint/match.go), the score fpstore has
//! been returning for lookups.
//!
//! The fingerprints are aligned on the offset where most of their hashes,
//! masked to 14 bits, match, and scored by the bit error between the aligned
//! hashes, scaled by how much of the shorter one overlaps and penalised when
//! either is repetitive.
//!
//! It is ported as it is, quirks included, and checked against go-acoustid
//! itself. When peaks tie for the best offset, the one used is whichever Go's
//! `sort.Slice` leaves first, given a comparator that is not a strict order,
//! so that sort is ported too. This makes the score depend on the order of
//! the arguments in those cases.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const max_offset = 80;
/// The longest fingerprint go-acoustid compares.
pub const max_hashes = (1 << 16) - 1;

const align_bits = 14;
const unique_bits = 16;
const max_offset_threshold_div = 10;

/// `GaussianKernel` of width 3 and sigma 1.3, as go-acoustid computes it
/// with Go's `math.Exp`, which is not bit for bit the same as Zig's.
const gaussian_kernel = [3]f64{
    @bitCast(@as(u64, 0x3fd3231cc85b1cbe)),
    @bitCast(@as(u64, 0x3fd9b9c66f49c684)),
    @bitCast(@as(u64, 0x3fd3231cc85b1cbe)),
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

/// Go's `hashBitMask`: `num_bits` bits, the odd ones first, then the even.
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

/// Go's `AlignFingerprints` with a limit of one: the best offset, if any.
fn alignFingerprints(allocator: Allocator, master: []const u32, query: []const u32) Allocator.Error!?OffsetHit {
    const hits = try findPeaks(allocator, master, query);
    defer allocator.free(hits);
    return if (hits.len > 0) hits[0] else null;
}

/// Go's `AlignFingerprints` without a limit: the peaks of the offset
/// histogram, best first.
fn findPeaks(allocator: Allocator, master: []const u32, query: []const u32) Allocator.Error![]OffsetHit {
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

    // The peaks above the threshold.
    var hits: std.ArrayList(OffsetHit) = .empty;
    defer hits.deinit(allocator);
    for (smoothed, 0..) |count, offset| {
        if (count < count_threshold) continue;
        const previous_count = if (offset > 0) smoothed[offset - 1] else 0;
        const next_count = if (offset < smoothed.len - 1) smoothed[offset + 1] else 0;
        if (previous_count <= count and next_count < count) {
            try hits.append(allocator, .{
                .offset = @as(i32, @intCast(offset)) - @as(i32, @intCast(query.len)),
                .count = count,
            });
        }
    }
    GoSort(OffsetHit, countAtLeast).sortSlice(hits.items);
    return hits.toOwnedSlice(allocator);
}

/// The comparator go-acoustid sorts peaks with, which is true both ways for
/// equal counts.
fn countAtLeast(a: OffsetHit, b: OffsetHit) bool {
    return a.count >= b.count;
}

/// Go's `Convolve` with `BorderReflect`, keeping the order of the floating
/// point operations.
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

/// Go's `CompareAlignedFingerprints`.
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

/// Go's `sort.Slice` (pattern-defeating quicksort, as of Go 1.19), step for
/// step, so that it leaves elements that compare equal in the same order Go
/// does, also with a `less` that is not a strict order.
fn GoSort(comptime T: type, comptime less: fn (T, T) bool) type {
    return struct {
        const Hint = enum { unknown, increasing, decreasing };

        fn sortSlice(data: []T) void {
            const limit = std.math.log2_int_ceil(usize, data.len + 1);
            pdqsort(data, 0, data.len, limit);
        }

        fn lessAt(data: []T, i: usize, j: usize) bool {
            return less(data[i], data[j]);
        }

        fn swap(data: []T, i: usize, j: usize) void {
            std.mem.swap(T, &data[i], &data[j]);
        }

        fn insertionSort(data: []T, a: usize, b: usize) void {
            var i = a + 1;
            while (i < b) : (i += 1) {
                var j = i;
                while (j > a and lessAt(data, j, j - 1)) : (j -= 1) swap(data, j, j - 1);
            }
        }

        fn siftDown(data: []T, lo: usize, hi: usize, first: usize) void {
            var root = lo;
            while (true) {
                var child = 2 * root + 1;
                if (child >= hi) return;
                if (child + 1 < hi and lessAt(data, first + child, first + child + 1)) child += 1;
                if (!lessAt(data, first + root, first + child)) return;
                swap(data, first + root, first + child);
                root = child;
            }
        }

        fn heapSort(data: []T, a: usize, b: usize) void {
            const first = a;
            const hi = b - a;
            var i = (hi - 1) / 2 + 1;
            while (i > 0) {
                i -= 1;
                siftDown(data, i, hi, first);
            }
            i = hi;
            while (i > 0) {
                i -= 1;
                swap(data, first, first + i);
                siftDown(data, 0, i, first);
            }
        }

        fn pdqsort(data: []T, a_start: usize, b_start: usize, limit_start: usize) void {
            const max_insertion = 12;
            var a = a_start;
            var b = b_start;
            var limit = limit_start;
            var was_balanced = true;
            var was_partitioned = true;
            while (true) {
                const length = b - a;
                if (length <= max_insertion) {
                    insertionSort(data, a, b);
                    return;
                }
                if (limit == 0) {
                    heapSort(data, a, b);
                    return;
                }
                if (!was_balanced) {
                    breakPatterns(data, a, b);
                    limit -= 1;
                }

                var pivot, var hint = choosePivot(data, a, b);
                if (hint == .decreasing) {
                    reverseRange(data, a, b);
                    pivot = (b - 1) - (pivot - a);
                    hint = .increasing;
                }
                if (was_balanced and was_partitioned and hint == .increasing) {
                    if (partialInsertionSort(data, a, b)) return;
                }
                // Never true with `countAtLeast`, where the element before a
                // right-hand partition, its pivot, is above all of it.
                if (a > 0 and !lessAt(data, a - 1, pivot)) {
                    a = partitionEqual(data, a, b, pivot);
                    continue;
                }

                const mid, const already_partitioned = partition(data, a, b, pivot);
                was_partitioned = already_partitioned;
                const left_len = mid - a;
                const right_len = b - mid;
                const balance_threshold = length / 8;
                if (left_len < right_len) {
                    was_balanced = left_len >= balance_threshold;
                    pdqsort(data, a, mid, limit);
                    a = mid + 1;
                } else {
                    was_balanced = right_len >= balance_threshold;
                    pdqsort(data, mid + 1, b, limit);
                    b = mid;
                }
            }
        }

        fn partition(data: []T, a: usize, b: usize, pivot: usize) struct { usize, bool } {
            swap(data, a, pivot);
            // Inclusive bounds, as in Go; `j` can go one below `a + 1`.
            var i: isize = @intCast(a + 1);
            var j: isize = @intCast(b - 1);
            while (i <= j and lessAt(data, @intCast(i), a)) i += 1;
            while (i <= j and !lessAt(data, @intCast(j), a)) j -= 1;
            if (i > j) {
                swap(data, @intCast(j), a);
                return .{ @intCast(j), true };
            }
            swap(data, @intCast(i), @intCast(j));
            i += 1;
            j -= 1;
            while (true) {
                while (i <= j and lessAt(data, @intCast(i), a)) i += 1;
                while (i <= j and !lessAt(data, @intCast(j), a)) j -= 1;
                if (i > j) break;
                swap(data, @intCast(i), @intCast(j));
                i += 1;
                j -= 1;
            }
            swap(data, @intCast(j), a);
            return .{ @intCast(j), false };
        }

        fn partitionEqual(data: []T, a: usize, b: usize, pivot: usize) usize {
            swap(data, a, pivot);
            var i: isize = @intCast(a + 1);
            var j: isize = @intCast(b - 1);
            while (true) {
                while (i <= j and !lessAt(data, a, @intCast(i))) i += 1;
                while (i <= j and lessAt(data, a, @intCast(j))) j -= 1;
                if (i > j) break;
                swap(data, @intCast(i), @intCast(j));
                i += 1;
                j -= 1;
            }
            return @intCast(i);
        }

        fn partialInsertionSort(data: []T, a: usize, b: usize) bool {
            const max_steps = 5;
            const shortest_shifting = 50;
            var i = a + 1;
            for (0..max_steps) |_| {
                while (i < b and !lessAt(data, i, i - 1)) i += 1;
                if (i == b) return true;
                if (b - a < shortest_shifting) return false;
                swap(data, i, i - 1);
                // Shift the smaller one to the left. Go stops at 1, not at
                // `a + 1`, and so does this.
                if (i - a >= 2) {
                    var j = i - 1;
                    while (j >= 1) : (j -= 1) {
                        if (!lessAt(data, j, j - 1)) break;
                        swap(data, j, j - 1);
                    }
                }
                // Shift the greater one to the right.
                if (b - i >= 2) {
                    var j = i + 1;
                    while (j < b) : (j += 1) {
                        if (!lessAt(data, j, j - 1)) break;
                        swap(data, j, j - 1);
                    }
                }
            }
            return false;
        }

        fn breakPatterns(data: []T, a: usize, b: usize) void {
            const length = b - a;
            if (length < 8) return;
            var random: u64 = length;
            const modulus = @as(u64, 1) << @intCast(std.math.log2_int(usize, length) + 1);
            var idx = a + (length / 4) * 2 - 1;
            while (idx <= a + (length / 4) * 2 + 1) : (idx += 1) {
                random ^= random << 13;
                random ^= random >> 7;
                random ^= random << 17;
                var other: usize = @intCast(random & (modulus - 1));
                if (other >= length) other -= length;
                swap(data, idx, a + other);
            }
        }

        fn choosePivot(data: []T, a: usize, b: usize) struct { usize, Hint } {
            const shortest_ninther = 50;
            const max_swaps = 4 * 3;
            const l = b - a;
            var swaps: usize = 0;
            var i = a + l / 4 * 1;
            var j = a + l / 4 * 2;
            var k = a + l / 4 * 3;
            if (l >= 8) {
                if (l >= shortest_ninther) {
                    i = median(data, i - 1, i, i + 1, &swaps);
                    j = median(data, j - 1, j, j + 1, &swaps);
                    k = median(data, k - 1, k, k + 1, &swaps);
                }
                j = median(data, i, j, k, &swaps);
            }
            return switch (swaps) {
                0 => .{ j, .increasing },
                max_swaps => .{ j, .decreasing },
                else => .{ j, .unknown },
            };
        }

        fn order2(data: []T, a: usize, b: usize, swaps: *usize) struct { usize, usize } {
            if (lessAt(data, b, a)) {
                swaps.* += 1;
                return .{ b, a };
            }
            return .{ a, b };
        }

        fn median(data: []T, a_in: usize, b_in: usize, c_in: usize, swaps: *usize) usize {
            var a, var b = order2(data, a_in, b_in, swaps);
            b, const c = order2(data, b, c_in, swaps);
            _ = c;
            a, b = order2(data, a, b, swaps);
            return b;
        }

        fn reverseRange(data: []T, a: usize, b: usize) void {
            var i = a;
            var j = b - 1;
            while (i < j) : ({
                i += 1;
                j -= 1;
            }) swap(data, i, j);
        }
    };
}

const testing = std.testing;
const chromaprint = @import("chromaprint.zig");

/// Fingerprints and the results go-acoustid gives for pairs of them,
/// generated by tools/compare-golden: real fingerprints of the same
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

test "matches go-acoustid on real and modified fingerprints" {
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

        const peaks = try findPeaks(allocator, master, query);
        defer allocator.free(peaks);
        errdefer std.debug.print("pair: {s}\n", .{line});
        try testing.expectEqual(num_peaks, peaks.len);
        if (num_peaks > 0) {
            try testing.expectEqual(offset, peaks[0].offset);
            try testing.expectEqual(count, peaks[0].count);
        }
        try testing.expectEqual(score, try compare(allocator, master, query));
        num_pairs += 1;
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

test "sorts like Go's sort.Slice" {
    const allocator = testing.allocator;
    var hits: std.ArrayList(OffsetHit) = .empty;
    defer hits.deinit(allocator);
    var num_cases: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, @embedFile("testdata/compare/sort.txt"), '\n');
    while (lines.next()) |line| {
        if (line[0] == '#') continue;
        const bar = std.mem.indexOfScalar(u8, line, '|').?;
        hits.clearRetainingCapacity();
        var counts = std.mem.tokenizeScalar(u8, line[0..bar], ' ');
        while (counts.next()) |count| {
            try hits.append(allocator, .{ .offset = @intCast(hits.items.len), .count = try std.fmt.parseFloat(f64, count) });
        }
        GoSort(OffsetHit, countAtLeast).sortSlice(hits.items);
        var order = std.mem.tokenizeScalar(u8, line[bar + 1 ..], ' ');
        for (hits.items) |hit| {
            try testing.expectEqual(try std.fmt.parseInt(i32, order.next().?, 10), hit.offset);
        }
        try testing.expectEqual(null, order.next());
        num_cases += 1;
    }
    try testing.expect(num_cases > 100);
}
