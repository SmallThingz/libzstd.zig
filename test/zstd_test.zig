const std = @import("std");
const zstd = @import("libzstd");

test "zstd compress/decompress roundtrip" {
    const input =
        "libzstd wraps libzstd and this payload should survive roundtrip compression and decompression";
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

const allocator = std.testing.allocator;

test "binary and empty exact roundtrips with output limits" {
    var binary: [131071]u8 = undefined;
    for (&binary, 0..) |*byte, i| byte.* = @truncate(i *% 197 +% (i >> 7));
    for ([_][]const u8{ "", &binary }) |input| {
        const encoded = try zstd.compressDefault(allocator, input);
        defer allocator.free(encoded);
        const restored = try zstd.decompress(allocator, encoded, input.len);
        defer allocator.free(restored);
        try std.testing.expectEqualSlices(u8, input, restored);
        if (input.len != 0)
            try std.testing.expectError(error.OutputTooLarge, zstd.decompress(allocator, encoded, input.len - 1));
    }
}

test "incremental tiny buffers flush and finalized encoder state" {
    var encoded: std.Io.Writer.Allocating = .init(allocator);
    defer encoded.deinit();
    var encoder = try zstd.Encoder.init(allocator, .{ .stream = .{ .in_buffer_size = 3, .out_buffer_size = 1 } });
    defer encoder.deinit();
    const input = "repeated repeated repeated binary\x00\xff repeated";
    for (input) |byte| {
        try encoder.update(&.{byte}, &encoded.writer);
    }
    try encoder.flush(&encoded.writer);
    try encoder.finish(&encoded.writer);
    try encoder.finish(&encoded.writer);
    try std.testing.expectError(error.StreamFinished, encoder.update("late", &encoded.writer));
    var restored: std.Io.Writer.Allocating = .init(allocator);
    defer restored.deinit();
    var decoder = try zstd.Decoder.init(allocator, .{ .max_output_size = input.len, .stream = .{ .in_buffer_size = 1, .out_buffer_size = 1 } });
    defer decoder.deinit();
    for (encoded.written()) |byte| {
        _ = try decoder.update(&.{byte}, &restored.writer);
    }
    try decoder.finish();
    try std.testing.expectEqualSlices(u8, input, restored.written());
}

test "every truncated prefix is rejected by streaming decoder" {
    const encoded = try zstd.compressDefault(allocator, "all bytes matter in this complete compressed frame");
    defer allocator.free(encoded);
    for (0..encoded.len) |n| {
        var decoder = try zstd.Decoder.init(allocator, .{ .stream = .{ .in_buffer_size = 1, .out_buffer_size = 7 } });
        defer decoder.deinit();
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var reader: std.Io.Reader = .fixed(encoded[0..n]);
        try std.testing.expectError(error.TruncatedInput, decoder.decodeReader(&reader, &out.writer));
    }
}

test "stream limit and failed writer poison decoder or encoder" {
    const encoded = try zstd.compressDefault(allocator, &@as([4096]u8, @splat('a')));
    defer allocator.free(encoded);
    var decoder = try zstd.Decoder.init(allocator, .{ .max_output_size = 9, .stream = .{ .out_buffer_size = 5 } });
    defer decoder.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.testing.expectError(error.OutputTooLarge, decoder.update(encoded, &out.writer));
    try std.testing.expect(out.written().len <= 9);
    try std.testing.expectError(error.InvalidState, decoder.update(encoded, &out.writer));

    var encoder = try zstd.Encoder.init(allocator, .{});
    defer encoder.deinit();
    var buffer: [0]u8 = .{};
    var writer: std.Io.Writer = .fixed(&buffer);
    try encoder.update("payload", &writer);
    try std.testing.expectError(error.WriteFailed, encoder.finish(&writer));
    try std.testing.expectError(error.InvalidState, encoder.update("retry", &writer));
}

fn allocationRoundtrip(a: std.mem.Allocator) !void {
    const encoded = try zstd.compressDefault(a, "allocation failure across native state buffers and output");
    defer a.free(encoded);
    const restored = try zstd.decompress(a, encoded, 100);
    defer a.free(restored);
    try std.testing.expectEqualStrings("allocation failure across native state buffers and output", restored);
}

test "every native and Zig allocation failure is leak free" {
    try std.testing.checkAllAllocationFailures(allocator, allocationRoundtrip, .{});
}

test "zero buffer sizes rejected without leaking" {
    try std.testing.expectError(error.InvalidBufferSize, zstd.Encoder.init(allocator, .{ .stream = .{ .out_buffer_size = 0 } }));
    try std.testing.expectError(error.InvalidBufferSize, zstd.Decoder.init(allocator, .{ .stream = .{ .in_buffer_size = 0 } }));
}

test "checksum corruption and one-shot trailing bytes are rejected" {
    const encoded = try zstd.compressDefault(allocator, "checksum protected body");
    defer allocator.free(encoded);
    encoded[encoded.len - 1] ^= 0x80;
    try std.testing.expectError(error.ChecksumMismatch, zstd.decompress(allocator, encoded, 100));
    encoded[encoded.len - 1] ^= 0x80;
    const extra = try std.mem.concat(allocator, u8, &.{ encoded, "junk" });
    defer allocator.free(extra);
    try std.testing.expectError(error.TrailingData, zstd.decompress(allocator, extra, 100));
}

test "streaming concatenated frames and unknown content size" {
    var encoded: std.Io.Writer.Allocating = .init(allocator);
    defer encoded.deinit();
    var encoder = try zstd.Encoder.init(allocator, .{});
    defer encoder.deinit();
    try encoder.update("first", &encoded.writer);
    try encoder.finish(&encoded.writer);
    try std.testing.expectError(error.UnknownDecompressedSize, zstd.decompress(allocator, encoded.written(), null));
    const first = try zstd.decompress(allocator, encoded.written(), 5);
    defer allocator.free(first);
    try std.testing.expectEqualStrings("first", first);
    try encoder.reset(3);
    try encoder.update("second", &encoded.writer);
    try encoder.finish(&encoded.writer);
    var decoder = try zstd.Decoder.init(allocator, .{ .stream = .{ .out_buffer_size = 1 } });
    defer decoder.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var reader: std.Io.Reader = .fixed(encoded.written());
    try decoder.decodeReader(&reader, &out.writer);
    try std.testing.expectEqualStrings("firstsecond", out.written());
}

test "dictionary copies survive caller mutation and raw trainer links" {
    const phrase = "a reusable dictionary with enough repeated vocabulary ";
    var dict: [phrase.len * 16]u8 = undefined;
    for (0..16) |i| @memcpy(dict[i * phrase.len ..][0..phrase.len], phrase);
    var encoder = try zstd.Encoder.init(allocator, .{});
    defer encoder.deinit();
    var decoder = try zstd.Decoder.init(allocator, .{});
    defer decoder.deinit();
    try encoder.loadDictionary(&dict);
    try decoder.loadDictionary(&dict);
    @memset(&dict, 0);
    const input = "a reusable dictionary with enough repeated vocabulary ";
    var encoded: std.Io.Writer.Allocating = .init(allocator);
    defer encoded.deinit();
    try encoder.update(input, &encoded.writer);
    try encoder.finish(&encoded.writer);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    _ = try decoder.update(encoded.written(), &out.writer);
    try decoder.finish();
    try std.testing.expectEqualStrings(input, out.written());
    var output: [256]u8 = undefined;
    const result = zstd.c.ZDICT_trainFromBuffer(&output, output.len, input.ptr, &[_]usize{input.len}, 1);
    try std.testing.expect(zstd.c.ZDICT_isError(result) != 0);
}
