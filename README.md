# zcompress

`zcompress` is a Zig package that vendors C compression libraries and exposes
small typed Zig wrappers.

Current status:
- `libzstd`: implemented (source is compiled by Zig)
- `libbrotli`: planned
- `libdeflate`: planned

## Features

- Compiles upstream `libzstd` sources directly in `build.zig`
- Exposes simple `compress` / `decompress` APIs in Zig
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
const zcompress = @import("zcompress");

const compressed = try zcompress.zstd.compressDefault(allocator, input);
defer allocator.free(compressed);

const decompressed = try zcompress.zstd.decompress(allocator, compressed, input.len * 2);
defer allocator.free(decompressed);
```
