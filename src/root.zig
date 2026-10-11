pub const chromaprint = @import("chromaprint.zig");
pub const compare = @import("compare.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
