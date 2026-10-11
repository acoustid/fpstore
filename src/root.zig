pub const chromaprint = @import("chromaprint.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
