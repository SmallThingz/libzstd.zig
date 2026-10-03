# libzstd.zig

Zstandard 1.5.7 for Zig 0.17.0. Native `std.Build` compiles the pinned upstream C
sources, including dictionary training, directly. No upstream build script or
custom libc is used.

```zig
const zstd = @import("libzstd");
const encoded = try zstd.compressWithOptions(allocator, input, .{
    .level = 5,
    .checksum = true,
});
defer allocator.free(encoded);
const decoded = try zstd.decompress(allocator, encoded, 8 * 1024 * 1024);
defer allocator.free(decoded);
```

Allocated compression emits a content size and defaults to a checksum.
`decompress` accepts exactly one frame, rejecting trailing bytes, checksum errors,
and truncation. Its optional limit bounds output; unknown-size frames require a
limit. Output grows as needed. Always provide a limit for untrusted input.

## Streaming and ownership

`Encoder` and `Decoder` expose allocator-backed `init`, `update`, `finish`,
`reset`, and `deinit`. Encoder also exposes `flush`; `loadDictionary` copies raw
or trained dictionary bytes into either context. Native and Zig buffers both use
the caller allocator. Do not copy owners or use them concurrently; the allocator
must outlive every owner.

```zig
var decoder = try zstd.Decoder.init(allocator, .{
    .max_output_size = 8 * 1024 * 1024,
    .window_log_max = 23,
    .stream = .{ .in_buffer_size = 4096, .out_buffer_size = 4096 },
});
defer decoder.deinit();
try decoder.decodeReader(reader, writer);
```

Reader/writer helpers consume to EOF and do not flush/close the writer. Streaming
decoders accept concatenated frames and enforce one total output limit.
`update` returns the native next-input hint; call decoder `finish()` at EOF to
validate completeness. Empty compressed input is truncated input. A complete
empty frame is valid. Tiny output buffers are fully drained before reading more.
`window_log_max` bounds the native decode window separately from output bytes.

After codec or writer failure, discard partial output and reset or deinitialize
the stream. Further updates return `InvalidState`. Finishing an encoder twice is
idempotent; input after finish returns `StreamFinished` until reset. Errors include
`OutOfMemory`, `OutputTooLarge`, `InvalidFrame`, `ChecksumMismatch`,
`TruncatedInput`, `TrailingData`, `InvalidDictionary`, and `InvalidParameter`.
Raw advanced parameters and upstream `c` declarations remain available. The C
build supports dictionary training, disables legacy pre-1.0 formats and assembly,
and does not enable multithreaded encoding; raw worker-count requests fail rather
than pretending to enable workers.

## Build and consume

```sh
zig build test example -j2
zig build test -Doptimize=safe -j2
zig build check -Dshared=true -j2
zig build check -Dtarget=x86_64-linux-musl -j2
```

`-Dshared` selects native library linkage (default static). Standard target and
optimization options apply. Zig's target libc replaces the former `static_libc`
custom ziglibc option. Use a musl target for self-contained Linux executables.
Tests/examples select LLVM + LLD to avoid Zig 0.16's self-hosted linker issue with
GCC 16 CRT objects. `check` compiles without executing target binaries.

```zig
const dep = b.dependency("libzstd", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("libzstd", dep.module("libzstd"));
```

The exported module carries native linkage and includes. Tests exercise exact
binary/empty roundtrips, tiny buffers, flush/reset, concatenated frames, checksum
corruption, every truncated prefix, dictionary copies, limits, and exhaustive
native/Zig allocator failures.
