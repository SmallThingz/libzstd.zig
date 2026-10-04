const std = @import("std");

const zstd_version = std.SemanticVersion{
    .major = 1,
    .minor = 5,
    .patch = 7,
};

const zstd_sources = [_][]const u8{
    "lib/common/debug.c",
    "lib/common/entropy_common.c",
    "lib/common/error_private.c",
    "lib/common/fse_decompress.c",
    "lib/common/pool.c",
    "lib/common/threading.c",
    "lib/common/xxhash.c",
    "lib/common/zstd_common.c",
    "lib/dictBuilder/cover.c",
    "lib/dictBuilder/divsufsort.c",
    "lib/dictBuilder/fastcover.c",
    "lib/dictBuilder/zdict.c",
    "lib/compress/fse_compress.c",
    "lib/compress/hist.c",
    "lib/compress/huf_compress.c",
    "lib/compress/zstd_compress.c",
    "lib/compress/zstd_compress_literals.c",
    "lib/compress/zstd_compress_sequences.c",
    "lib/compress/zstd_compress_superblock.c",
    "lib/compress/zstd_double_fast.c",
    "lib/compress/zstd_fast.c",
    "lib/compress/zstd_lazy.c",
    "lib/compress/zstd_ldm.c",
    "lib/compress/zstd_opt.c",
    "lib/compress/zstd_preSplit.c",
    "lib/decompress/huf_decompress.c",
    "lib/decompress/zstd_ddict.c",
    "lib/decompress/zstd_decompress.c",
    "lib/decompress/zstd_decompress_block.c",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const shared = b.option(bool, "shared", "Build libzstd as a shared library") orelse false;

    const zstd_upstream = b.dependency("zstd_upstream", .{});

    const lib = b.addLibrary(.{
        .name = "zstd",
        .linkage = if (shared) .dynamic else .static,
        .version = zstd_version,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .sanitize_c = .off,
        }),
    });
    configureZstdLibrary(lib.root_module, zstd_upstream, &zstd_sources);

    b.installArtifact(lib);

    const mod = b.addModule("libzstd", .{
        .root_source_file = b.path("src/zstd.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addIncludePath(zstd_upstream.path("lib"));
    mod.linkLibrary(lib);

    const headers = b.addWriteFiles();
    const bindings = b.addTranslateC(.{
        .root_source_file = headers.add("zstd.h", "#define ZSTD_STATIC_LINKING_ONLY 1\n#include <zstd.h>\n#include <zstd_errors.h>\n#include <zdict.h>\n"),
        .target = target,
        .optimize = optimize,
    });
    bindings.addIncludePath(zstd_upstream.path("lib"));
    mod.addImport("zstd_c", bindings.createModule());

    const tests = b.addTest(.{
        .use_lld = target.result.ofmt != .macho,
        .use_llvm = true,
        .root_module = b.addModule("libzstd_tests", .{
            .root_source_file = b.path("test/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    tests.root_module.addImport("libzstd", mod);

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);

    const example = b.addExecutable(.{
        .use_lld = target.result.ofmt != .macho,
        .use_llvm = true,
        .name = "zstd-roundtrip",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/zstd_roundtrip.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    example.root_module.addImport("libzstd", mod);
    b.installArtifact(example);

    const run_example = b.addRunArtifact(example);
    const example_step = b.step("example", "Run zstd roundtrip example");
    example_step.dependOn(&run_example.step);

    const check = b.step("check", "Compile library, tests and example without running");
    check.dependOn(&lib.step);
    check.dependOn(&tests.step);
    check.dependOn(&example.step);
}

fn configureZstdLibrary(
    module: *std.Build.Module,
    dep: *std.Build.Dependency,
    files: []const []const u8,
) void {
    module.addIncludePath(dep.path("lib"));
    module.addCMacro("XXH_NAMESPACE", "ZSTD_");
    module.addCMacro("ZSTD_DISABLE_ASM", "1");
    module.addCMacro("ZSTD_LEGACY_SUPPORT", "0");
    module.addCSourceFiles(.{
        .root = dep.path(""),
        .files = files,
        .flags = &.{"-std=c99"},
    });
}
