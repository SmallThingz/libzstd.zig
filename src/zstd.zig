const std = @import("std");
const raw = @import("zstd_raw.zig").c;

/// Compression level used by `compress` when no explicit level is provided.
pub const default_level: i32 = 3;
/// Full raw `libzstd` C API exposed via `@cImport`.
pub const c = raw;
const content_size_unknown: u64 = std.math.maxInt(u64);
const content_size_error: u64 = std.math.maxInt(u64) - 1;

/// Compresses `src` into a new allocation using zstd.
pub fn compress(allocator: std.mem.Allocator, src: []const u8, level: i32) ![]u8 {
    const bound = raw.ZSTD_compressBound(src.len);
    if (raw.ZSTD_isError(bound) != 0) return error.CompressionFailed;

    const out = try allocator.alloc(u8, bound);
    errdefer allocator.free(out);

    const written = raw.ZSTD_compress(
        out.ptr,
        out.len,
        src.ptr,
        src.len,
        level,
    );
    if (raw.ZSTD_isError(written) != 0) return error.CompressionFailed;

    return shrinkOwnedSlice(allocator, out, written);
}

/// Compresses `src` using `default_level`.
pub fn compressDefault(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    return compress(allocator, src, default_level);
}

/// Decompresses a single zstd frame into a newly allocated slice.
///
/// If the frame doesn't encode content size, `max_output_size` must be provided.
pub fn decompress(
    allocator: std.mem.Allocator,
    src: []const u8,
    max_output_size: ?usize,
) ![]u8 {
    const frame_size: u64 = @intCast(raw.ZSTD_getFrameContentSize(src.ptr, src.len));
    if (frame_size == content_size_error) return error.InvalidFrame;

    const target_len: usize = if (frame_size == content_size_unknown) blk: {
        break :blk max_output_size orelse return error.UnknownDecompressedSize;
    } else try toUsize(frame_size);

    if (max_output_size) |max| {
        if (target_len > max) return error.OutputTooLarge;
    }

    const out = try allocator.alloc(u8, target_len);
    errdefer allocator.free(out);

    const written = raw.ZSTD_decompress(out.ptr, out.len, src.ptr, src.len);
    if (raw.ZSTD_isError(written) != 0) {
        if (raw.ZSTD_getErrorCode(written) == raw.ZSTD_error_dstSize_tooSmall) {
            return error.OutputTooLarge;
        }
        return error.DecompressionFailed;
    }

    return shrinkOwnedSlice(allocator, out, written);
}

/// Returns `true` when a zstd `size_t` return code represents an error.
pub fn isError(code: usize) bool {
    return raw.ZSTD_isError(code) != 0;
}

/// Returns zstd's human-readable message for a `size_t` result code.
pub fn errorName(code: usize) []const u8 {
    return std.mem.span(raw.ZSTD_getErrorName(code));
}

fn toUsize(value: u64) !usize {
    if (value > std.math.maxInt(usize)) return error.OutputTooLarge;
    return @intCast(value);
}

fn shrinkOwnedSlice(allocator: std.mem.Allocator, buf: []u8, len: usize) ![]u8 {
    if (len == buf.len) return buf;
    if (allocator.resize(buf, len)) return buf[0..len];

    const exact = try allocator.alloc(u8, len);
    @memcpy(exact, buf[0..len]);
    allocator.free(buf);
    return exact;
}
