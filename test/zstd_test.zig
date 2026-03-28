const std = @import("std");
const zstd = @import("zcompress");

test "zstd compress/decompress roundtrip" {
    const input =
        "zcompress wraps libzstd and this payload should survive roundtrip compression and decompression";
    const compressed = try zstd.compressDefault(std.testing.allocator, input);
    defer std.testing.allocator.free(compressed);

    const decompressed = try zstd.decompress(std.testing.allocator, compressed, input.len * 2);
    defer std.testing.allocator.free(decompressed);

    try std.testing.expectEqualStrings(input, decompressed);
}

test "zstd invalid frame is rejected" {
    const invalid = "not-a-zstd-frame";
    try std.testing.expectError(
        error.InvalidFrame,
        zstd.decompress(std.testing.allocator, invalid, 1024),
    );
}

test "zstd raw API is exposed" {
    try std.testing.expect(zstd.c.ZSTD_versionNumber() > 0);
}

test "zstd stream reader/writer roundtrip" {
    const input =
        "streamed zstd encode/decode should work with std.Io.Reader and std.Io.Writer";

    var reader = std.Io.Reader.fixed(input);
    var compressed = try std.Io.Writer.Allocating.initCapacity(std.testing.allocator, input.len + 64);
    errdefer compressed.deinit();

    try zstd.compressReaderToWriter(std.testing.allocator, &reader, &compressed.writer, zstd.default_level);

    var compressed_list = compressed.toArrayList();
    defer compressed_list.deinit(std.testing.allocator);

    var compressed_reader = std.Io.Reader.fixed(compressed_list.items);
    var decompressed = try std.Io.Writer.Allocating.initCapacity(std.testing.allocator, input.len + 64);
    errdefer decompressed.deinit();

    try zstd.decompressReaderToWriter(std.testing.allocator, &compressed_reader, &decompressed.writer);

    var decompressed_list = decompressed.toArrayList();
    defer decompressed_list.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(input, decompressed_list.items);
}
