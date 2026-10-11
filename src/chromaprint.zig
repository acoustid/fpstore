//! Chromaprint's compressed fingerprint format, the one clients submit
//! (base64-encoded) and `chromaprint_encode_fingerprint` produces.
//!
//! A header of the algorithm version (u8) and the hash count (u24, big
//! endian), then each hash XORed with the previous one, written as the
//! distances between its set bits: 3-bit values, where 0 ends a hash and 7
//! means 7 plus the next 5-bit value from the exception stream. The 3-bit
//! stream comes first and the 5-bit stream right after it, both packed
//! LSB-first.
//!
//! Decoding is stricter than Chromaprint and go-acoustid, which silently
//! drop set bits past 32 in a hash: such input is rejected, as is a hash
//! count the body is too short to hold.
//!
//! Both directions go through a byte per value. Eight 3-bit values are three
//! bytes and eight 5-bit values five, so (un)packing is one PDEP/PEXT per
//! eight values, and the rest works on whole bytes, eight or 32 at a time.

const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{ InvalidFingerprint, OutputTooSmall, ScratchTooSmall };

pub const header_size = 4;
pub const max_hashes = std.math.maxInt(u24);

pub const Impl = enum {
    /// PDEP/PEXT for (un)packing and merging exceptions, VPERMD for picking
    /// out the hashes. PDEP/PEXT take a cycle on Intel since Haswell and AMD
    /// since Zen 3, but are microcoded and very slow on Zen 1 and 2.
    x86_64_v3,
    /// Plain Zig, shifts and masks, for any target.
    portable,
};

/// What the target supports.
pub const default_impl: Impl = blk: {
    if (builtin.cpu.arch != .x86_64) break :blk .portable;
    const features = builtin.cpu.features;
    if (!std.Target.x86.featureSetHasAll(features, .{ .bmi2, .avx2 })) break :blk .portable;
    const model = builtin.cpu.model;
    if (model == &std.Target.x86.cpu.znver1 or model == &std.Target.x86.cpu.znver2) break :blk .portable;
    break :blk .x86_64_v3;
};

pub fn maxEncodedSize(num_hashes: usize) usize {
    // At most 32 set bits and a terminator per hash, and at most four
    // distances of 7 or more in 32 bits.
    return header_size + (num_hashes * 33 * 3 + 7) / 8 + (num_hashes * 4 * 5 + 7) / 8;
}

/// Scratch `encode` needs for `num_hashes` hashes.
pub fn encodeScratchSize(num_hashes: usize) usize {
    return encodeValuesSize(num_hashes) + encodeExceptionsSize(num_hashes);
}

fn encodeValuesSize(num_hashes: usize) usize {
    // At most 33 values per hash, and the last group's padding.
    return num_hashes * 33 + 7;
}

fn encodeExceptionsSize(num_hashes: usize) usize {
    // At most four exceptions per hash, and an eight-byte write at the end.
    return num_hashes * 4 * 5 / 8 + 8;
}

/// Encodes `hashes` into `out`, which `maxEncodedSize` bytes always fit,
/// using `encodeScratchSize` bytes of `scratch`. Returns the encoded size.
pub fn encode(version: u8, hashes: []const u32, out: []u8, scratch: []u8) Error!usize {
    return encodeImpl(default_impl, version, hashes, out, scratch);
}

fn encodeImpl(comptime impl: Impl, version: u8, hashes: []const u32, out: []u8, scratch: []u8) Error!usize {
    if (hashes.len == 0 or hashes.len > max_hashes) return error.InvalidFingerprint;
    if (scratch.len < encodeScratchSize(hashes.len)) return error.ScratchTooSmall;
    const values = scratch[0..encodeValuesSize(hashes.len)];
    const exceptions = scratch[values.len..][0..encodeExceptionsSize(hashes.len)];

    // The distances between set bits, uncapped, a byte each. Each byte of a
    // hash comes from a table, eight bytes written at once and the next
    // byte's written over the unused part, with the first distance made
    // relative to the last set bit of the bytes before.
    var num_values: usize = 0;
    var prev: u32 = 0;
    for (hashes) |h| {
        const x = h ^ prev;
        prev = h;
        var last_bit: u32 = 0;
        inline for (0..4) |k| {
            const b: u8 = @truncate(x >> (8 * k));
            const deltas = byte_deltas[b] + (8 * k - last_bit);
            std.mem.writeInt(u64, values[num_values..][0..8], deltas, .little);
            num_values += @popCount(b);
            last_bit = if (b != 0) @as(u32, 8 * k + 8) - @clz(b) else last_bit;
        }
        values[num_values] = 0;
        num_values += 1;
    }

    const normal_size = (num_values * 3 + 7) / 8;
    if (out.len < header_size + normal_size) return error.OutputTooSmall;
    const normal = out[header_size..][0..normal_size];

    // Eight values at a time: the ones over 6 capped at 7 into the normal
    // stream and the rest, minus 7, into the exception stream.
    var exceptions_size: usize = 0;
    var acc: u64 = 0;
    var acc_bits: u6 = 0;
    var o: usize = 0;
    var i: usize = 0;
    const padded = padToGroup(values, num_values);
    while (i < padded.len) : ({
        i += 8;
        o += 3;
    }) {
        const x = std.mem.readInt(u64, padded[i..][0..8], .little);
        // 0x80 in each byte that is 7 or more. No distance is over 32, so
        // adding 0x79 never carries into the next byte.
        const big = (x +% 0x7979797979797979) & 0x8080808080808080;
        const big_bytes = (big >> 7) *% 0xFF;
        const sevens = 0x0707070707070707 & big_bytes;

        const extra = extractBitsMask(impl, big_bytes & 0x1F1F1F1F1F1F1F1F, (x & big_bytes) - sevens);
        acc |= extra << acc_bits;
        acc_bits += @intCast(@popCount(big) * 5);
        std.mem.writeInt(u64, exceptions[exceptions_size..][0..8], acc, .little);
        // At most 7 + 40 bits, so never a whole word.
        const full_bytes = acc_bits >> 3;
        exceptions_size += full_bytes;
        acc >>= full_bytes * 8;
        acc_bits &= 7;

        const packed_bits = extractBits(impl, 3, (x & ~big_bytes) | sevens);
        if (normal.len - o >= 4) {
            std.mem.writeInt(u32, normal[o..][0..4], @truncate(packed_bits), .little);
        } else {
            var tmp: [4]u8 = undefined;
            std.mem.writeInt(u32, &tmp, @truncate(packed_bits), .little);
            @memcpy(normal[o..], tmp[0 .. normal.len - o]);
        }
    }
    if (acc_bits > 0) {
        exceptions[exceptions_size] = @truncate(acc);
        exceptions_size += 1;
    }

    const size = header_size + normal_size + exceptions_size;
    if (out.len < size) return error.OutputTooSmall;
    out[0] = version;
    std.mem.writeInt(u24, out[1..4], @intCast(hashes.len), .big);
    @memcpy(out[header_size + normal_size ..][0..exceptions_size], exceptions[0..exceptions_size]);
    return size;
}

/// For each byte, the distances between its set bits, counting from bit 0
/// as 1, packed a byte each.
const byte_deltas: [256]u64 = blk: {
    @setEvalBranchQuota(10_000);
    var table: [256]u64 = undefined;
    for (&table, 0..) |*entry, b| {
        var deltas: u64 = 0;
        var n: usize = 0;
        var last: u64 = 0;
        for (0..8) |j| {
            if (b & (1 << j) != 0) {
                deltas |= (j + 1 - last) << (8 * n);
                last = j + 1;
                n += 1;
            }
        }
        entry.* = deltas;
    }
    break :blk table;
};

/// Zero-fills `buf` from `len` up to a whole number of eight-value groups.
fn padToGroup(buf: []u8, len: usize) []const u8 {
    const padded = std.mem.alignForward(usize, len, 8);
    @memset(buf[len..padded], 0);
    return buf[0..padded];
}

pub const Header = struct {
    version: u8,
    num_hashes: usize,
};

/// The header, if the body can hold that many hashes, which bounds the
/// output to what the input could make.
pub fn decodeHeader(data: []const u8) Error!Header {
    if (data.len < header_size) return error.InvalidFingerprint;
    const num_hashes = std.mem.readInt(u24, data[1..4], .big);
    // Each hash takes at least a 3-bit terminator.
    if (num_hashes == 0 or num_hashes > (data.len - header_size) * 8 / 3) return error.InvalidFingerprint;
    return .{ .version = data[0], .num_hashes = num_hashes };
}

/// Scratch `decode` needs for `data_len` bytes of input.
pub fn decodeScratchSize(data_len: usize) usize {
    const body_len = data_len -| header_size;
    return decodeValuesSize(body_len) + decodeExceptionsSize(body_len);
}

fn decodeValuesSize(body_len: usize) usize {
    // Every group of the body unpacked, the last one partial.
    return (body_len + 2) / 3 * 8;
}

fn decodeExceptionsSize(body_len: usize) usize {
    // A copy of the exception stream, padded for the whole-word reads that
    // run past its end.
    return body_len + exceptions_padding;
}

const exceptions_padding = 8;

const vector_len = 32;
const Vector = @Vector(vector_len, u8);
const Mask = @Int(.unsigned, vector_len);

/// Decodes into `out`, which has to hold `decodeHeader(data).num_hashes`,
/// using `decodeScratchSize(data.len)` bytes of `scratch`. Bytes past the
/// end of the encoded fingerprint are ignored.
pub fn decode(data: []const u8, out: []u32, scratch: []u8) Error!Header {
    return decodeImpl(default_impl, data, out, scratch);
}

fn decodeImpl(comptime impl: Impl, data: []const u8, out: []u32, scratch: []u8) Error!Header {
    const header = try decodeHeader(data);
    if (out.len < header.num_hashes) return error.OutputTooSmall;
    if (scratch.len < decodeScratchSize(data.len)) return error.ScratchTooSmall;
    const body = data[header_size..];
    const values = scratch[0..decodeValuesSize(body.len)];
    const exceptions = scratch[values.len..][0..decodeExceptionsSize(body.len)];

    // Unpack everything as 3-bit values. Past the end of the normal stream
    // that is the exception stream read wrong. Only the rest of the last
    // group of eight is looked at, and its values are dropped.
    unpack(impl, body, values);
    const max_values = body.len * 8 / 3;

    // The normal stream ends at the terminator of the last hash.
    var num_values: usize = 0;
    var num_exceptions: usize = 0;
    {
        var remaining = header.num_hashes;
        var i: usize = 0;
        while (max_values - i >= vector_len) : (i += vector_len) {
            const v: Vector = values[i..][0..vector_len].*;
            const zeros = @popCount(@as(Mask, @bitCast(v == @as(Vector, @splat(0)))));
            if (zeros >= remaining) break;
            remaining -= zeros;
            num_exceptions += @popCount(@as(Mask, @bitCast(v == @as(Vector, @splat(7)))));
        }
        while (true) : (i += 1) {
            if (i >= max_values) return error.InvalidFingerprint;
            switch (values[i]) {
                0 => {
                    remaining -= 1;
                    if (remaining == 0) break;
                },
                7 => num_exceptions += 1,
                else => {},
            }
        }
        num_values = i + 1;
    }

    const normal_size = (num_values * 3 + 7) / 8;
    const exceptions_size = (num_exceptions * 5 + 7) / 8;
    if (body.len - normal_size < exceptions_size) return error.InvalidFingerprint;

    @memcpy(exceptions[0..exceptions_size], body[normal_size..][0..exceptions_size]);
    @memset(exceptions[exceptions_size..][0..exceptions_padding], 0);

    const groups = values[0..std.mem.alignForward(usize, num_values, 8)];
    try buildHashes(impl, groups, num_values, exceptions, out[0..header.num_hashes]);
    return header;
}

/// Adds to each 7 among the eight values in `x` the next exception from the
/// packed 5-bit stream `exceptions`, starting with exception `e.*`. Reads up
/// to eight bytes past the exception it starts at, and the 7s past the end
/// of the normal stream count too, so `exceptions` needs that much padding.
inline fn mergeExceptions(comptime impl: Impl, x: u64, exceptions: []const u8, e: *usize) u64 {
    // 0x80 in each byte that is 7.
    const y = x ^ 0x0707070707070707;
    const low7 = 0x7F7F7F7F7F7F7F7F;
    const sevens = ~(((y & low7) +% low7) | y | low7);
    switch (impl) {
        .x86_64_v3 => {
            const bit = e.* * 5;
            const bits = std.mem.readInt(u64, exceptions[bit / 8 ..][0..8], .little) >> @intCast(bit % 8);
            e.* += @popCount(sevens);
            return x + depositBits((sevens >> 7) *% 0x1F, bits);
        },
        .portable => {
            var r = x;
            var m = sevens;
            while (m != 0) : (m &= m - 1) {
                const bit = e.* * 5;
                const value = (std.mem.readInt(u16, exceptions[bit / 8 ..][0..2], .little) >> @intCast(bit % 8)) & 0x1F;
                r += @as(u64, value) << @intCast(@ctz(m) - 7);
                e.* += 1;
            }
            return r;
        },
    }
}

/// Turns the distances into hashes.
///
/// A hash is its XOR with the previous hash, XORed with the previous hash,
/// so it is every bit decoded so far XORed together, taken at the hash's
/// terminator. A bit's position is the sum of the distances since the last
/// terminator. Both are prefix scans, done a vector at a time.
///
/// `groups` holds the `num_values` values, padded to a multiple of eight.
fn buildHashes(comptime impl: Impl, groups: []const u8, num_values: usize, exceptions: []const u8, out: []u32) Error!void {
    const Lanes = @Vector(8, u32);
    const zeros: Vector = @splat(0);
    const ones: Vector = @splat(0xFF);

    var i: usize = 0;
    var e: usize = 0;
    var h: usize = 0;
    var pos: u8 = 0;
    var hash: u32 = 0;
    var invalid: Vector = zeros;
    while (num_values - i >= vector_len and out.len - h >= vector_len) : (i += vector_len) {
        // Assembled in registers: storing the groups and loading them back
        // as one vector stalls on store forwarding.
        var merged: @Vector(vector_len / 8, u64) = undefined;
        inline for (0..vector_len / 8) |k| {
            merged[k] = mergeExceptions(impl, std.mem.readInt(u64, groups[i + k * 8 ..][0..8], .little), exceptions, &e);
        }
        const deltas: Vector = @bitCast(merged);
        const ends = @select(u8, deltas == zeros, ones, zeros);

        // Positions: a prefix sum of the distances, restarting after each
        // terminator, and continuing the previous vector's last hash.
        var p = deltas;
        var restart = shiftLanes(u8, vector_len, ends, 1);
        inline for (.{ 1, 2, 4, 8, 16 }) |n| {
            p +%= shiftLanes(u8, vector_len, p, n) & ~restart;
            restart |= shiftLanes(u8, vector_len, restart, n);
        }
        p +%= @as(Vector, @splat(pos)) & ~restart;
        // The first position past 32 in a hash is at most 32 + 38, so it
        // cannot have wrapped around.
        invalid |= @select(u8, p > @as(Vector, @splat(32)), ones, zeros) & ~ends;
        pos = if (ends[vector_len - 1] != 0) 0 else p[vector_len - 1];

        // Hashes: a prefix XOR of the bits.
        var lanes: [vector_len / 8]Lanes = undefined;
        inline for (&lanes, 0..) |*l, k| {
            const lane_pos: Lanes = lanesAt(p, k * 8);
            const lane_ends: Lanes = lanesAt(ends, k * 8);
            const shift: @Vector(8, u5) = @truncate(lane_pos -% @as(Lanes, @splat(1)));
            var x = (@as(Lanes, @splat(1)) << shift) & ~(lane_ends * @as(Lanes, @splat(0x01010101)));
            inline for (.{ 1, 2, 4 }) |n| x ^= shiftLanes(u32, 8, x, n);
            x ^= @as(Lanes, @splat(hash));
            hash = x[7];
            l.* = x;
        }

        // Keep the hash at each terminator.
        if (impl == .x86_64_v3) {
            const end_mask: Mask = @bitCast(deltas == zeros);
            inline for (lanes, 0..) |l, k| {
                const m: u8 = @truncate(end_mask >> (k * 8));
                out[h..][0..8].* = permuteLanes(l, compact_lanes[m]);
                h += @popCount(m);
            }
        } else {
            const hashes: [vector_len]u32 = @bitCast(lanes);
            const is_end: [vector_len]u8 = ends;
            inline for (0..vector_len) |j| {
                out[h] = hashes[j];
                h += is_end[j] & 1;
            }
        }
    }
    if (@reduce(.Or, invalid) != 0) return error.InvalidFingerprint;

    // What is left, one value at a time.
    var p: u32 = pos;
    while (i < num_values) : (i += 8) {
        const group: [8]u8 = @bitCast(mergeExceptions(impl, std.mem.readInt(u64, groups[i..][0..8], .little), exceptions, &e));
        for (group[0..@min(8, num_values - i)]) |value| {
            const delta: u32 = value;
            const not_end = @as(u32, 0) -% @intFromBool(delta != 0);
            p += delta;
            if (p > 32 and not_end != 0) return error.InvalidFingerprint;
            hash ^= (@as(u32, 1) << @intCast((p -% 1) & 31)) & not_end;
            out[h] = hash;
            h += 1 - (not_end & 1);
            p &= not_end;
        }
    }
}

/// For each mask of eight lanes, the indices of its set lanes, in order.
const compact_lanes: [256]@Vector(8, u8) = blk: {
    @setEvalBranchQuota(10_000);
    var table: [256]@Vector(8, u8) = undefined;
    for (&table, 0..) |*entry, m| {
        var indices: [8]u8 = @splat(0);
        var n: usize = 0;
        for (0..8) |j| {
            if (m & (1 << j) != 0) {
                indices[n] = j;
                n += 1;
            }
        }
        entry.* = indices;
    }
    break :blk table;
};

/// VPERMD: lane `j` of the result is lane `indices[j]` of `v`.
inline fn permuteLanes(v: @Vector(8, u32), indices: @Vector(8, u8)) [8]u32 {
    const wide: @Vector(8, u32) = indices;
    return asm ("vpermd %[v], %[indices], %[ret]"
        : [ret] "=x" (-> @Vector(8, u32)),
        : [v] "x" (v),
          [indices] "x" (wide),
    );
}

/// Lanes moved up by `n`, with zeros shifted in.
inline fn shiftLanes(comptime T: type, comptime len: usize, v: @Vector(len, T), comptime n: usize) @Vector(len, T) {
    const mask = comptime blk: {
        var m: [len]i32 = undefined;
        for (&m, 0..) |*x, j| x.* = if (j >= n) j - n else -1;
        break :blk m;
    };
    return @shuffle(T, v, @as(@Vector(len, T), @splat(0)), mask);
}

/// Eight lanes from `start`, widened to u32.
inline fn lanesAt(v: Vector, comptime start: usize) @Vector(8, u32) {
    const mask = comptime blk: {
        var m: [8]i32 = undefined;
        for (&m, 0..) |*x, j| x.* = start + j;
        break :blk m;
    };
    return @shuffle(u8, v, undefined, mask);
}

/// Low `width` bits of each byte.
fn byteMask(comptime width: u4) u64 {
    return @as(u64, (1 << width) - 1) * 0x0101010101010101;
}

/// Unpacks eight 3-bit values per three bytes of `src` into a byte each in
/// `dst`, including a partial last group, zero-padded.
fn unpack(comptime impl: Impl, src: []const u8, dst: []u8) void {
    const width = 3;
    var i: usize = 0;
    var o: usize = 0;
    while (src.len - i >= 8) : ({
        i += width;
        o += 8;
    }) {
        const bits = std.mem.readInt(u64, src[i..][0..8], .little);
        std.mem.writeInt(u64, dst[o..][0..8], spreadBits(impl, width, bits), .little);
    }
    while (i < src.len) : ({
        i += width;
        o += 8;
    }) {
        var tmp: [8]u8 = @splat(0);
        const n = @min(8, src.len - i);
        @memcpy(tmp[0..n], src[i..][0..n]);
        const bits = std.mem.readInt(u64, &tmp, .little);
        std.mem.writeInt(u64, dst[o..][0..8], spreadBits(impl, width, bits), .little);
    }
}

/// The low `width` bits of each byte of `x`, concatenated.
inline fn extractBits(comptime impl: Impl, comptime width: u4, x: u64) u64 {
    const mask = comptime byteMask(width);
    switch (impl) {
        .x86_64_v3 => return asm ("pextq %[mask], %[x], %[ret]"
            : [ret] "=r" (-> u64),
            : [x] "r" (x),
              [mask] "r" (mask),
        ),
        .portable => {
            var r: u64 = 0;
            inline for (0..8) |i| r |= ((x >> (8 * i)) & ((1 << width) - 1)) << (width * i);
            return r;
        },
    }
}

/// The low `8 * width` bits of `x`, `width` bits into each byte.
inline fn spreadBits(comptime impl: Impl, comptime width: u4, x: u64) u64 {
    switch (impl) {
        .x86_64_v3 => return depositBits(comptime byteMask(width), x),
        .portable => {
            var r: u64 = 0;
            inline for (0..8) |i| r |= ((x >> (width * i)) & ((1 << width) - 1)) << (8 * i);
            return r;
        },
    }
}

/// PEXT with a mask of whole `0x1F`s in some bytes: the masked bits of `x`,
/// concatenated.
inline fn extractBitsMask(comptime impl: Impl, mask: u64, x: u64) u64 {
    switch (impl) {
        .x86_64_v3 => return asm ("pextq %[mask], %[x], %[ret]"
            : [ret] "=r" (-> u64),
            : [x] "r" (x),
              [mask] "r" (mask),
        ),
        .portable => {
            var r: u64 = 0;
            var shift: u6 = 0;
            inline for (0..8) |j| {
                const selected = (mask >> (8 * j)) & 1;
                r |= ((x >> (8 * j)) & 0x1F & (0 -% selected)) << shift;
                shift += @intCast(5 * selected);
            }
            return r;
        },
    }
}

/// PDEP: the low bits of `x` into the set bits of `mask`.
inline fn depositBits(mask: u64, x: u64) u64 {
    return asm ("pdepq %[mask], %[x], %[ret]"
        : [ret] "=r" (-> u64),
        : [x] "r" (x),
          [mask] "r" (mask),
    );
}

const testing = std.testing;

const impls = if (default_impl == .x86_64_v3) [_]Impl{ .x86_64_v3, .portable } else [_]Impl{.portable};

/// The format written out a bit at a time, to check the fast paths against.
fn referenceEncode(allocator: std.mem.Allocator, version: u8, hashes: []const u32) ![]u8 {
    var normal: std.ArrayList(u8) = .empty;
    defer normal.deinit(allocator);
    var exceptional: std.ArrayList(u8) = .empty;
    defer exceptional.deinit(allocator);
    var prev: u32 = 0;
    for (hashes) |h| {
        const v = h ^ prev;
        prev = h;
        var last_bit: u32 = 0;
        for (1..33) |bit| {
            if (v & (@as(u32, 1) << @intCast(bit - 1)) == 0) continue;
            const delta: u32 = @intCast(bit - last_bit);
            last_bit = @intCast(bit);
            if (delta >= 7) {
                try normal.append(allocator, 7);
                try exceptional.append(allocator, @intCast(delta - 7));
            } else {
                try normal.append(allocator, @intCast(delta));
            }
        }
        try normal.append(allocator, 0);
    }
    const normal_size = (normal.items.len * 3 + 7) / 8;
    const exceptional_size = (exceptional.items.len * 5 + 7) / 8;
    const out = try allocator.alloc(u8, header_size + normal_size + exceptional_size);
    @memset(out, 0);
    out[0] = version;
    std.mem.writeInt(u24, out[1..4], @intCast(hashes.len), .big);
    for (normal.items, 0..) |value, i| writeBits(out[header_size..], i * 3, 3, value);
    for (exceptional.items, 0..) |value, i| writeBits(out[header_size + normal_size ..], i * 5, 5, value);
    return out;
}

fn writeBits(buf: []u8, start: usize, width: usize, value: u8) void {
    for (0..width) |b| {
        const bit = start + b;
        buf[bit / 8] |= @intCast(((value >> @intCast(b)) & 1) << @intCast(bit % 8));
    }
}

fn readBits(buf: []const u8, start: usize, width: usize) ?u8 {
    if (start + width > buf.len * 8) return null;
    var value: u8 = 0;
    for (0..width) |b| {
        const bit = start + b;
        value |= @intCast(((buf[bit / 8] >> @intCast(bit % 8)) & 1) << @intCast(b));
    }
    return value;
}

/// The format read a bit at a time. Null for anything `decode` has to
/// reject.
fn referenceDecode(allocator: std.mem.Allocator, data: []const u8) !?[]u32 {
    if (data.len < header_size) return null;
    const num_hashes = std.mem.readInt(u24, data[1..4], .big);
    if (num_hashes == 0) return null;
    const body = data[header_size..];

    var normal: std.ArrayList(u8) = .empty;
    defer normal.deinit(allocator);
    var ends: usize = 0;
    while (ends < num_hashes) {
        const value = readBits(body, normal.items.len * 3, 3) orelse return null;
        try normal.append(allocator, value);
        if (value == 0) ends += 1;
    }

    const hashes = try allocator.alloc(u32, num_hashes);
    errdefer allocator.free(hashes);
    var exception_bit = (normal.items.len * 3 + 7) / 8 * 8;
    var h: usize = 0;
    var hash: u32 = 0;
    var last_bit: u32 = 0;
    for (normal.items) |value| {
        if (value == 0) {
            hashes[h] = hash;
            h += 1;
            last_bit = 0;
            continue;
        }
        var delta: u32 = value;
        if (value == 7) {
            delta += readBits(body, exception_bit, 5) orelse {
                allocator.free(hashes);
                return null;
            };
            exception_bit += 5;
        }
        last_bit += delta;
        if (last_bit > 32) {
            allocator.free(hashes);
            return null;
        }
        hash ^= @as(u32, 1) << @intCast(last_bit - 1);
    }
    return hashes;
}

/// Memory ending right at an inaccessible page, so that reading or writing
/// past its end faults, filled with `fill` so that reading what was never
/// written shows. A plain allocation off Linux.
const Guarded = struct {
    memory: []u8,
    bytes: []u8,

    fn init(len: usize, fill: u8) !Guarded {
        const memory = if (builtin.os.tag == .linux) blk: {
            const linux = std.os.linux;
            const page = std.heap.pageSize();
            const total = std.mem.alignForward(usize, len, page) + page;
            const addr = linux.mmap(null, total, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
            if (linux.errno(addr) != .SUCCESS) return error.OutOfMemory;
            const memory = @as([*]u8, @ptrFromInt(addr))[0..total];
            if (linux.errno(linux.mprotect(memory[total - page ..].ptr, page, .{})) != .SUCCESS) return error.Unexpected;
            break :blk memory;
        } else try testing.allocator.alloc(u8, len);
        const bytes = if (builtin.os.tag == .linux) memory[memory.len - std.heap.pageSize() - len ..][0..len] else memory;
        @memset(bytes, fill);
        return .{ .memory = memory, .bytes = bytes };
    }

    fn deinit(self: Guarded) void {
        if (builtin.os.tag == .linux) {
            _ = std.os.linux.munmap(self.memory.ptr, self.memory.len);
        } else {
            testing.allocator.free(self.memory);
        }
    }
};

/// Encodes into an output of exactly `size` bytes, with guarded scratch and
/// output.
fn encodeAlloc(comptime impl: Impl, version: u8, hashes: []const u32, size: usize) ![]u8 {
    const scratch = try Guarded.init(encodeScratchSize(hashes.len), 0xA5);
    defer scratch.deinit();
    const out = try Guarded.init(size, 0xA5);
    defer out.deinit();
    const n = try encodeImpl(impl, version, hashes, out.bytes, scratch.bytes);
    try testing.expectEqual(size, n);
    return testing.allocator.dupe(u8, out.bytes);
}

/// Decodes a guarded copy of `data` with guarded scratch and output, both
/// exactly as large as they need to be and filled with `fill`.
fn decodeAlloc(comptime impl: Impl, data: []const u8, fill: u8) ![]u32 {
    const input = try Guarded.init(data.len, 0);
    defer input.deinit();
    @memcpy(input.bytes, data);
    const header = try decodeHeader(input.bytes);
    const scratch = try Guarded.init(decodeScratchSize(data.len), fill);
    defer scratch.deinit();
    const out = try Guarded.init(header.num_hashes * 4, fill);
    defer out.deinit();
    const hashes: []u32 = @alignCast(std.mem.bytesAsSlice(u32, out.bytes));
    _ = try decodeImpl(impl, input.bytes, hashes, scratch.bytes);
    return testing.allocator.dupe(u32, hashes);
}

/// Encodes with every implementation, checks the result against the
/// reference, and decodes it back.
fn expectRoundTrip(version: u8, hashes: []const u32) !void {
    const allocator = testing.allocator;
    const expected = try referenceEncode(allocator, version, hashes);
    defer allocator.free(expected);
    inline for (impls) |impl| {
        const encoded = try encodeAlloc(impl, version, hashes, expected.len);
        defer allocator.free(encoded);
        try testing.expectEqualSlices(u8, expected, encoded);

        const header = try decodeHeader(encoded);
        try testing.expectEqual(version, header.version);
        try testing.expectEqual(hashes.len, header.num_hashes);
        const decoded = try decodeAlloc(impl, encoded, 0xA5);
        defer allocator.free(decoded);
        try testing.expectEqualSlices(u32, hashes, decoded);
    }
}

/// Every implementation either rejects `data` like the reference does, or
/// decodes it to the same hashes.
fn expectDecodeMatchesReference(data: []const u8) !void {
    const allocator = testing.allocator;
    const expected = try referenceDecode(allocator, data);
    defer if (expected) |e| allocator.free(e);
    inline for (impls) |impl| {
        for ([_]u8{ 0x00, 0xFF }) |fill| {
            if (decodeAlloc(impl, data, fill)) |decoded| {
                defer allocator.free(decoded);
                try testing.expectEqualSlices(u32, expected orelse return error.TestUnexpectedResult, decoded);
            } else |err| {
                try testing.expectEqual(error.InvalidFingerprint, err);
                try testing.expectEqual(null, expected);
            }
        }
    }
}

fn randomHashes(random: std.Random, hashes: []u32) void {
    // Sparse, dense and random bits, and runs of repeated hashes, which are
    // empty after the XOR and so all terminators.
    for (hashes, 0..) |*h, i| {
        h.* = switch (random.uintLessThan(u8, 5)) {
            0 => random.int(u32),
            1 => random.int(u32) & random.int(u32) & random.int(u32),
            2 => random.int(u32) | random.int(u32),
            3 => if (i > 0) hashes[i - 1] ^ (@as(u32, 1) << random.int(u5)) else 0,
            else => if (i > 0) hashes[i - 1] else 0,
        };
    }
}

const real_fingerprints = [_][]const u8{
    @embedFile("testdata/calibre_sunrise.txt"),
    @embedFile("testdata/radio1_1_ad.txt"),
    @embedFile("testdata/radio1_2_ad_and_calibre_sunshine.txt"),
    @embedFile("testdata/radio1_3_calibre_sunshine.txt"),
    @embedFile("testdata/radio1_4_calibre_sunshine.txt"),
    @embedFile("testdata/radio1_5_calibre_sunshine.txt"),
};

test "real fingerprints decode like the reference and re-encode byte for byte" {
    const allocator = testing.allocator;
    const decoder = std.base64.url_safe_no_pad.Decoder;
    for (real_fingerprints) |text| {
        const str = std.mem.trim(u8, text, " \n");
        const data = try allocator.alloc(u8, try decoder.calcSizeForSlice(str));
        defer allocator.free(data);
        try decoder.decode(data, str);

        const header = try decodeHeader(data);
        try testing.expectEqual(1, header.version);
        const expected = (try referenceDecode(allocator, data)).?;
        defer allocator.free(expected);

        inline for (impls) |impl| {
            const decoded = try decodeAlloc(impl, data, 0xA5);
            defer allocator.free(decoded);
            try testing.expectEqualSlices(u32, expected, decoded);

            const encoded = try encodeAlloc(impl, header.version, decoded, data.len);
            defer allocator.free(encoded);
            try testing.expectEqualSlices(u8, data, encoded);
        }
    }
}

test "round trip edge cases" {
    // A single hash, without and with set bits.
    try expectRoundTrip(1, &.{0});
    try expectRoundTrip(1, &.{1});
    try expectRoundTrip(1, &.{0xFFFFFFFF});
    // Only the top bit: a distance of 32, the largest exception.
    try expectRoundTrip(1, &.{ 0x80000000, 0, 0x80000000 });
    // Bits 7, 14, 21 and 28 apart: four exceptions in one hash.
    try expectRoundTrip(1, &.{ 0x08102040, 0, 0x08102040, 0x08102040 ^ 0x80000000 });
    // Distances of exactly 6 and 7, either side of the exception cut-off.
    try expectRoundTrip(1, &.{ 0x00000820, 0x00001040 ^ 0x00000820 });
    // The version is carried through.
    try expectRoundTrip(0, &.{ 1, 2, 3 });
    try expectRoundTrip(0xAB, &.{ 1, 2, 3 });
}

test "round trip long runs of terminators and of dense hashes" {
    // Repeated hashes make a terminator per value, more terminators in a
    // vector than there is room for at the end of the output; alternating
    // all-ones makes 33 values per hash.
    var hashes: [1000]u32 = undefined;
    for (&hashes, 0..) |*h, i| h.* = if (i < 500) 0x12345678 else if (i % 2 == 0) 0 else 0xFFFFFFFF;
    for ([_]usize{ 1, 7, 8, 31, 32, 33, 63, 64, 65, 100, 500, 501, 1000 }) |len| {
        try expectRoundTrip(1, hashes[0..len]);
        try expectRoundTrip(1, hashes[hashes.len - len ..]);
    }
}

test "round trip random fingerprints against the reference encoder" {
    var prng = std.Random.DefaultPrng.init(1);
    const random = prng.random();
    var hashes: [3000]u32 = undefined;
    for (0..300) |i| {
        const max_len: usize = if (i % 10 == 0) hashes.len else 300;
        const len = random.intRangeAtMost(usize, 1, max_len);
        randomHashes(random, hashes[0..len]);
        try expectRoundTrip(1, hashes[0..len]);
    }
}

test "encode rejects bad input and reports a short output" {
    const hashes = [_]u32{ 0xDEADBEEF, 0x12345678, 0xCAFEBABE, 0x08102040 };
    var scratch: [encodeScratchSize(hashes.len)]u8 = undefined;
    var out: [maxEncodedSize(hashes.len)]u8 = undefined;
    inline for (impls) |impl| {
        try testing.expectError(error.InvalidFingerprint, encodeImpl(impl, 1, &.{}, &out, &scratch));
        const size = try encodeImpl(impl, 1, &hashes, &out, &scratch);
        for (0..size) |len| {
            try testing.expectError(error.OutputTooSmall, encodeImpl(impl, 1, &hashes, out[0..len], &scratch));
        }
        try testing.expectEqual(size, try encodeImpl(impl, 1, &hashes, out[0..size], &scratch));
    }
}

test "decode reports a short output" {
    const allocator = testing.allocator;
    const encoded = try referenceEncode(allocator, 1, &.{ 1, 2, 3 });
    defer allocator.free(encoded);
    var out: [2]u32 = undefined;
    var scratch: [decodeScratchSize(64)]u8 = undefined;
    inline for (impls) |impl| {
        try testing.expectError(error.OutputTooSmall, decodeImpl(impl, encoded, &out, &scratch));
    }
}

test "every truncation is rejected" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(2);
    var hashes: [200]u32 = undefined;
    randomHashes(prng.random(), &hashes);
    const encoded = try referenceEncode(allocator, 1, &hashes);
    defer allocator.free(encoded);
    for (0..encoded.len) |len| {
        try testing.expectEqual(null, try referenceDecode(allocator, encoded[0..len]));
        try expectDecodeMatchesReference(encoded[0..len]);
    }
}

test "corrupted input decodes like the reference" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(3);
    const random = prng.random();
    var hashes: [200]u32 = undefined;
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(allocator);
    for (0..3000) |_| {
        const len = random.intRangeAtMost(usize, 1, hashes.len);
        randomHashes(random, hashes[0..len]);
        const encoded = try referenceEncode(allocator, 1, hashes[0..len]);
        defer allocator.free(encoded);
        data.clearRetainingCapacity();
        try data.appendSlice(allocator, encoded);
        const body = data.items[header_size..];
        switch (random.uintLessThan(u8, 6)) {
            // Flipped bits.
            0, 1 => for (0..random.intRangeAtMost(usize, 1, 3)) |_| {
                const bit = random.uintLessThan(usize, body.len * 8);
                body[bit / 8] ^= @as(u8, 1) << @intCast(bit % 8);
            },
            // A hash count off by a little.
            2 => {
                const count = std.mem.readInt(u24, data.items[1..4], .big);
                const changed = if (random.boolean()) count +| random.intRangeAtMost(u24, 1, 3) else count -| random.intRangeAtMost(u24, 1, 3);
                std.mem.writeInt(u24, data.items[1..4], changed, .big);
            },
            // Trailing set bits, which read as 7s past the end of the
            // normal stream and as exceptions that are not there.
            3 => try data.appendNTimes(allocator, 0xFF, random.uintLessThan(usize, 48)),
            // Random bytes, sparse enough that some of them decode.
            4 => for (body) |*byte| {
                byte.* = random.int(u8) & random.int(u8);
            },
            // Terminators with a few 7s among them.
            else => {
                @memset(body, 0);
                for (0..random.uintLessThan(usize, 20)) |_| {
                    writeBits(body, random.uintLessThan(usize, body.len * 8 / 3) * 3, 3, 7);
                }
            },
        }
        try expectDecodeMatchesReference(data.items);
    }
}

test "a set bit past 32 is rejected" {
    const allocator = testing.allocator;
    // Six distances of 6 reach 36, 7 + 26 reaches 33, and 6 * 5 + 1 + 2 does.
    const cases = [_]struct { normal: []const u8, exceptions: []const u8 }{
        .{ .normal = &.{ 6, 6, 6, 6, 6, 6, 0 }, .exceptions = &.{} },
        .{ .normal = &.{ 7, 0 }, .exceptions = &.{26} },
        .{ .normal = &.{ 6, 6, 6, 6, 6, 1, 2, 0 }, .exceptions = &.{} },
    };
    for (cases) |case| {
        const normal_size = (case.normal.len * 3 + 7) / 8;
        const data = try allocator.alloc(u8, header_size + normal_size + (case.exceptions.len * 5 + 7) / 8);
        defer allocator.free(data);
        @memset(data, 0);
        data[0] = 1;
        std.mem.writeInt(u24, data[1..4], 1, .big);
        for (case.normal, 0..) |value, i| writeBits(data[header_size..], i * 3, 3, value);
        for (case.exceptions, 0..) |value, i| writeBits(data[header_size + normal_size ..], i * 5, 5, value);
        try testing.expectEqual(null, try referenceDecode(allocator, data));
        try expectDecodeMatchesReference(data);
    }
    // 32 itself is fine: 6 * 5 + 2.
    try expectRoundTrip(1, &.{0x80000000 | 0x20820820});
}

test "a header the body cannot hold is rejected" {
    var scratch: [decodeScratchSize(16)]u8 = undefined;
    var out: [64]u32 = undefined;
    try testing.expectError(error.InvalidFingerprint, decodeHeader(&.{ 1, 0, 0 }));
    try testing.expectError(error.InvalidFingerprint, decodeHeader(&.{ 1, 0, 0, 0, 0 }));
    // A 4-byte input must not get to ask for 16M hashes.
    try testing.expectError(error.InvalidFingerprint, decodeHeader(&.{ 1, 0xFF, 0xFF, 0xFF }));
    try testing.expectError(error.InvalidFingerprint, decodeHeader(&.{ 1, 0, 0, 1 }));
    // Three bytes hold eight terminators, but not nine.
    try testing.expectError(error.InvalidFingerprint, decodeHeader(&.{ 1, 0, 0, 9, 0, 0, 0 }));
    const header = try decodeHeader(&.{ 1, 0, 0, 8, 0, 0, 0 });
    try testing.expectEqual(8, header.num_hashes);
    inline for (impls) |impl| {
        _ = try decodeImpl(impl, &.{ 1, 0, 0, 8, 0, 0, 0 }, &out, &scratch);
        try testing.expectEqualSlices(u32, &@as([8]u32, @splat(0)), out[0..8]);
    }
}

test "too little scratch is an error" {
    const allocator = testing.allocator;
    const hashes = [_]u32{ 1, 2, 3 };
    const encoded = try referenceEncode(allocator, 1, &hashes);
    defer allocator.free(encoded);
    var out: [maxEncodedSize(hashes.len)]u8 = undefined;
    var decoded: [hashes.len]u32 = undefined;
    var scratch: [1024]u8 = undefined;
    inline for (impls) |impl| {
        try testing.expectError(error.ScratchTooSmall, encodeImpl(impl, 1, &hashes, &out, scratch[0 .. encodeScratchSize(hashes.len) - 1]));
        try testing.expectError(error.ScratchTooSmall, decodeImpl(impl, encoded, &decoded, scratch[0 .. decodeScratchSize(encoded.len) - 1]));
    }
}

test "trailing bytes are ignored" {
    const allocator = testing.allocator;
    const encoded = try referenceEncode(allocator, 1, &.{ 1, 2, 3 });
    defer allocator.free(encoded);
    const padded = try std.mem.concat(allocator, u8, &.{ encoded, "garbage" });
    defer allocator.free(padded);
    inline for (impls) |impl| {
        const decoded = try decodeAlloc(impl, padded, 0xA5);
        defer allocator.free(decoded);
        try testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, decoded);
    }
}
