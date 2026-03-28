# libzstd

`libzstd` is a Zig package that vendors C compression libraries and exposes
small typed Zig wrappers.

Current status:
- `libzstd`: implemented (source is compiled by Zig)
- `libbrotli`: planned
- `libdeflate`: planned

## Features

- Compiles upstream `libzstd` sources directly in `build.zig`
- Exposes one-shot and streaming APIs in Zig (`std.Io.Reader` / `std.Io.Writer`)
- Exposes full raw `libzstd` API under `libzstd.c`
- Supports both libc modes:
  - static libc via [`ziglibc`](https://github.com/SmallThingz/ziglibc) (default)
  - dynamic/system libc via `-Dstatic_libc=false`

## Build Options

- `-Dstatic_libc=true|false` (default `true`): static ziglibc or system libc
- `-Dshared=true|false` (default `false`): build `libzstd` artifact as shared/static

## Commands

```bash
zig build test
zig build test -Dstatic_libc=false
zig build example
```

## Zig API

```zig
const zstd = @import("libzstd");

const compressed = try zstd.compressDefault(allocator, input);
defer allocator.free(compressed);

const decompressed = try zstd.decompress(allocator, compressed, input.len * 2);
defer allocator.free(decompressed);
```

Raw `libzstd` symbols are exposed through `zstd.c`, e.g.
`zstd.c.ZSTD_versionNumber()`.
