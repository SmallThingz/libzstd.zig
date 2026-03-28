const std = @import("std");
const zcompress = @import("zcompress");

test "zstd compress/decompress roundtrip" {
    const input =
        "zcompress wraps libzstd and this payload should survive roundtrip compression and decompression";
    const compressed = try zcompress.zstd.compressDefault(std.testing.allocator, input);
    defer std.testing.allocator.free(compressed);

    const decompressed = try zcompress.zstd.decompress(std.testing.allocator, compressed, input.len * 2);
    defer std.testing.allocator.free(decompressed);

    try std.testing.expectEqualStrings(input, decompressed);
}

test "zstd invalid frame is rejected" {
    const invalid = "not-a-zstd-frame";
    try std.testing.expectError(
        error.InvalidFrame,
        zcompress.zstd.decompress(std.testing.allocator, invalid, 1024),
    );
}
