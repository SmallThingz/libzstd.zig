const std = @import("std");
const zcompress = @import("zcompress");

pub fn main() !void {
    const gpa = std.heap.smp_allocator;
    const input =
        "Example payload: zstd compression through the zcompress Zig wrapper.";

    const compressed = try zcompress.zstd.compressDefault(gpa, input);
    defer gpa.free(compressed);

    const decompressed = try zcompress.zstd.decompress(gpa, compressed, input.len * 2);
    defer gpa.free(decompressed);

    if (!std.mem.eql(u8, input, decompressed)) return error.RoundtripMismatch;

    std.debug.print(
        "input={d} compressed={d} decompressed={d}\n",
        .{ input.len, compressed.len, decompressed.len },
    );
}
