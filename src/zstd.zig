const std = @import("std");

/// Full raw `libzstd` C API exposed via `@cImport`.
///
/// This includes one-shot, dictionary, advanced parameter, and streaming APIs.
pub const c = @import("zstd_raw.zig").c;

/// Compression level used by `compressDefault`.
pub const default_level: i32 = 3;

/// Default stream buffer options based on zstd recommendations.
pub const StreamOptions = struct {
    /// Optional override for input buffer size.
    in_buffer_size: ?usize = null,
    /// Optional override for output buffer size.
    out_buffer_size: ?usize = null,
};

/// Streaming encoder options.
pub const EncoderOptions = struct {
    /// Compression level passed to `ZSTD_initCStream`.
    level: i32 = default_level,
    /// Stream buffer sizing options.
    stream: StreamOptions = .{},
};

/// Streaming decoder options.
pub const DecoderOptions = struct {
    /// Stream buffer sizing options.
    stream: StreamOptions = .{},
};

/// Streaming zstd encoder that writes compressed bytes to a `std.Io.Writer`.
pub const Encoder = struct {
    allocator: std.mem.Allocator,
    cstream: *c.ZSTD_CStream,
    in_buffer: []u8,
    out_buffer: []u8,

    /// Allocates and initializes a streaming encoder.
    pub fn init(allocator: std.mem.Allocator, opts: EncoderOptions) !Encoder {
        const cstream = c.ZSTD_createCStream() orelse return error.OutOfMemory;
        errdefer _ = c.ZSTD_freeCStream(cstream);

        const in_size = opts.stream.in_buffer_size orelse c.ZSTD_CStreamInSize();
        const out_size = opts.stream.out_buffer_size orelse c.ZSTD_CStreamOutSize();
        if (in_size == 0 or out_size == 0) return error.InvalidBufferSize;

        const in_buffer = try allocator.alloc(u8, in_size);
        errdefer allocator.free(in_buffer);
        const out_buffer = try allocator.alloc(u8, out_size);
        errdefer allocator.free(out_buffer);

        _ = try checkCode(c.ZSTD_initCStream(cstream, opts.level));

        return .{
            .allocator = allocator,
            .cstream = cstream,
            .in_buffer = in_buffer,
            .out_buffer = out_buffer,
        };
    }

    /// Releases encoder and owned buffers.
    pub fn deinit(self: *Encoder) void {
        self.allocator.free(self.in_buffer);
        self.allocator.free(self.out_buffer);
        _ = c.ZSTD_freeCStream(self.cstream);
    }

    /// Sets a zstd compression parameter on the underlying stream context.
    pub fn setParameter(self: *Encoder, param: c.ZSTD_cParameter, value: i32) !void {
        _ = try checkCode(c.ZSTD_CCtx_setParameter(self.cstream, param, value));
    }

    /// Resets encoder state and level for a new frame.
    pub fn reset(self: *Encoder, level: i32) !void {
        _ = try checkCode(c.ZSTD_initCStream(self.cstream, level));
    }

    /// Pushes input bytes into the encoder with `ZSTD_e_continue`.
    pub fn update(self: *Encoder, input: []const u8, writer: *std.Io.Writer) !void {
        _ = try self.run(input, c.ZSTD_e_continue, writer);
    }

    /// Flushes pending output with `ZSTD_e_flush`.
    pub fn flush(self: *Encoder, writer: *std.Io.Writer) !void {
        while (true) {
            const remaining = try self.run(&.{}, c.ZSTD_e_flush, writer);
            if (remaining == 0) break;
        }
    }

    /// Finishes the current frame with `ZSTD_e_end`.
    pub fn finish(self: *Encoder, writer: *std.Io.Writer) !void {
        while (true) {
            const remaining = try self.run(&.{}, c.ZSTD_e_end, writer);
            if (remaining == 0) break;
        }
    }

    /// Reads all data from `reader`, encodes it, and writes to `writer`.
    pub fn encodeReader(self: *Encoder, reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
        while (true) {
            const n = try reader.readSliceShort(self.in_buffer);
            if (n == 0) break;
            try self.update(self.in_buffer[0..n], writer);
        }
        try self.finish(writer);
    }

    fn run(
        self: *Encoder,
        input: []const u8,
        directive: c.ZSTD_EndDirective,
        writer: *std.Io.Writer,
    ) !usize {
        var inb = c.ZSTD_inBuffer{
            .src = if (input.len == 0) null else @ptrCast(input.ptr),
            .size = input.len,
            .pos = 0,
        };

        while (true) {
            var outb = c.ZSTD_outBuffer{
                .dst = @ptrCast(self.out_buffer.ptr),
                .size = self.out_buffer.len,
                .pos = 0,
            };

            const remaining = try checkCode(c.ZSTD_compressStream2(self.cstream, &outb, &inb, directive));
            if (outb.pos != 0) try writer.writeAll(self.out_buffer[0..outb.pos]);

            if (directive == c.ZSTD_e_continue) {
                if (inb.pos == inb.size) return remaining;
            } else if (remaining == 0) {
                return 0;
            }

            if (outb.pos == 0 and inb.pos == inb.size and directive == c.ZSTD_e_continue) {
                return remaining;
            }
        }
    }
};

/// Streaming zstd decoder that writes decompressed bytes to a `std.Io.Writer`.
pub const Decoder = struct {
    allocator: std.mem.Allocator,
    dstream: *c.ZSTD_DStream,
    in_buffer: []u8,
    out_buffer: []u8,

    /// Allocates and initializes a streaming decoder.
    pub fn init(allocator: std.mem.Allocator, opts: DecoderOptions) !Decoder {
        const dstream = c.ZSTD_createDStream() orelse return error.OutOfMemory;
        errdefer _ = c.ZSTD_freeDStream(dstream);

        const in_size = opts.stream.in_buffer_size orelse c.ZSTD_DStreamInSize();
        const out_size = opts.stream.out_buffer_size orelse c.ZSTD_DStreamOutSize();
        if (in_size == 0 or out_size == 0) return error.InvalidBufferSize;

        const in_buffer = try allocator.alloc(u8, in_size);
        errdefer allocator.free(in_buffer);
        const out_buffer = try allocator.alloc(u8, out_size);
        errdefer allocator.free(out_buffer);

        _ = try checkCode(c.ZSTD_initDStream(dstream));

        return .{
            .allocator = allocator,
            .dstream = dstream,
            .in_buffer = in_buffer,
            .out_buffer = out_buffer,
        };
    }

    /// Releases decoder and owned buffers.
    pub fn deinit(self: *Decoder) void {
        self.allocator.free(self.in_buffer);
        self.allocator.free(self.out_buffer);
        _ = c.ZSTD_freeDStream(self.dstream);
    }

    /// Sets a zstd decompression parameter on the underlying stream context.
    pub fn setParameter(self: *Decoder, param: c.ZSTD_dParameter, value: i32) !void {
        _ = try checkCode(c.ZSTD_DCtx_setParameter(self.dstream, param, value));
    }

    /// Resets decoder state for a new stream.
    pub fn reset(self: *Decoder) !void {
        _ = try checkCode(c.ZSTD_initDStream(self.dstream));
    }

    /// Pushes compressed bytes into the decoder and writes produced output.
    ///
    /// Returns zstd's remaining-input hint from the final `decompressStream` call.
    pub fn update(self: *Decoder, input: []const u8, writer: *std.Io.Writer) !usize {
        var hint: usize = 0;
        var inb = c.ZSTD_inBuffer{
            .src = if (input.len == 0) null else @ptrCast(input.ptr),
            .size = input.len,
            .pos = 0,
        };

        while (inb.pos < inb.size) {
            var outb = c.ZSTD_outBuffer{
                .dst = @ptrCast(self.out_buffer.ptr),
                .size = self.out_buffer.len,
                .pos = 0,
            };

            hint = try checkCode(c.ZSTD_decompressStream(self.dstream, &outb, &inb));
            if (outb.pos != 0) try writer.writeAll(self.out_buffer[0..outb.pos]);

            if (outb.pos == 0 and inb.pos == 0 and hint != 0) return error.DecompressionStalled;
        }

        return hint;
    }

    /// Reads all compressed data from `reader`, decodes it, and writes to `writer`.
    pub fn decodeReader(self: *Decoder, reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
        while (true) {
            const n = try reader.readSliceShort(self.in_buffer);
            if (n == 0) break;
            _ = try self.update(self.in_buffer[0..n], writer);
        }
    }
};

/// Compresses `src` into a new allocation using zstd one-shot API.
pub fn compress(allocator: std.mem.Allocator, src: []const u8, level: i32) ![]u8 {
    const bound = c.ZSTD_compressBound(src.len);
    _ = try checkCode(bound);

    const out = try allocator.alloc(u8, bound);
    errdefer allocator.free(out);

    const written = c.ZSTD_compress(out.ptr, out.len, src.ptr, src.len, level);
    _ = try checkCode(written);

    return shrinkOwnedSlice(allocator, out, written);
}

/// Compresses `src` using `default_level`.
pub fn compressDefault(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    return compress(allocator, src, default_level);
}

/// Decompresses a single zstd frame into a newly allocated slice.
///
/// If frame content size is unknown, `max_output_size` must be provided.
pub fn decompress(
    allocator: std.mem.Allocator,
    src: []const u8,
    max_output_size: ?usize,
) ![]u8 {
    const content_size_unknown: u64 = std.math.maxInt(u64);
    const content_size_error: u64 = std.math.maxInt(u64) - 1;

    const frame_size: u64 = @intCast(c.ZSTD_getFrameContentSize(src.ptr, src.len));
    if (frame_size == content_size_error) return error.InvalidFrame;

    const target_len: usize = if (frame_size == content_size_unknown) blk: {
        break :blk max_output_size orelse return error.UnknownDecompressedSize;
    } else try toUsize(frame_size);

    if (max_output_size) |max| {
        if (target_len > max) return error.OutputTooLarge;
    }

    const out = try allocator.alloc(u8, target_len);
    errdefer allocator.free(out);

    const written = c.ZSTD_decompress(out.ptr, out.len, src.ptr, src.len);
    if (c.ZSTD_isError(written) != 0) {
        if (c.ZSTD_getErrorCode(written) == c.ZSTD_error_dstSize_tooSmall) {
            return error.OutputTooLarge;
        }
        return error.DecompressionFailed;
    }

    return shrinkOwnedSlice(allocator, out, written);
}

/// Compresses bytes from `reader` into `writer` using streaming API.
pub fn compressReaderToWriter(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    level: i32,
) !void {
    var encoder = try Encoder.init(allocator, .{ .level = level });
    defer encoder.deinit();
    try encoder.encodeReader(reader, writer);
}

/// Decompresses bytes from `reader` into `writer` using streaming API.
pub fn decompressReaderToWriter(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
) !void {
    var decoder = try Decoder.init(allocator, .{});
    defer decoder.deinit();
    try decoder.decodeReader(reader, writer);
}

/// Returns `true` when a zstd `size_t` return code represents an error.
pub fn isError(code: usize) bool {
    return c.ZSTD_isError(code) != 0;
}

/// Returns zstd's human-readable message for a `size_t` result code.
pub fn errorName(code: usize) []const u8 {
    return std.mem.span(c.ZSTD_getErrorName(code));
}

fn checkCode(code: usize) !usize {
    if (c.ZSTD_isError(code) != 0) return error.ZstdError;
    return code;
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
