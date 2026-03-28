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
    const static_libc = b.option(bool, "static_libc", "Link against static ziglibc instead of system libc") orelse true;

    const zstd_upstream = b.dependency("zstd_upstream", .{});

    const lib = b.addLibrary(.{
        .name = "zstd",
        .linkage = if (shared) .dynamic else .static,
        .version = zstd_version,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = !static_libc,
            .sanitize_c = .off,
        }),
    });
    configureZstdLibrary(lib.root_module, zstd_upstream, &zstd_sources);

    const static_libc_artifact = if (static_libc) blk: {
        const ziglibc_dep = b.lazyDependency("ziglibc", .{
            .target = target,
            .optimize = optimize,
            .trace = false,
        }) orelse return;

        const ziglibc_lib = findDependencyArtifactByLinkage(ziglibc_dep, "cguana", .static);
        configureStaticLibc(lib.root_module, ziglibc_lib, ziglibc_dep);
        break :blk ziglibc_lib;
    } else null;

    b.installArtifact(lib);

    const mod = b.addModule("libzstd", .{
        .root_source_file = b.path("src/zstd.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = !static_libc,
    });
    mod.addIncludePath(zstd_upstream.path("lib"));
    mod.linkLibrary(lib);
    if (static_libc_artifact) |artifact| {
        const ziglibc_dep = b.lazyDependency("ziglibc", .{
            .target = target,
            .optimize = optimize,
            .trace = false,
        }) orelse return;
        configureStaticLibc(mod, artifact, ziglibc_dep);
    }

    const tests = b.addTest(.{
        .root_module = b.addModule("libzstd_tests", .{
            .root_source_file = b.path("test/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = !static_libc,
        }),
    });
    tests.root_module.addImport("libzstd", mod);
    if (static_libc_artifact) |artifact| {
        const ziglibc_dep = b.lazyDependency("ziglibc", .{
            .target = target,
            .optimize = optimize,
            .trace = false,
        }) orelse return;
        configureStaticLibc(tests.root_module, artifact, ziglibc_dep);
    }

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);

    const example = b.addExecutable(.{
        .name = "zstd-roundtrip",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/zstd_roundtrip.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = !static_libc,
        }),
    });
    example.root_module.addImport("libzstd", mod);
    if (static_libc_artifact) |artifact| {
        const ziglibc_dep = b.lazyDependency("ziglibc", .{
            .target = target,
            .optimize = optimize,
            .trace = false,
        }) orelse return;
        configureStaticLibc(example.root_module, artifact, ziglibc_dep);
    }
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

fn configureStaticLibc(module: *std.Build.Module, artifact: *std.Build.Step.Compile, dep: *std.Build.Dependency) void {
    module.addIncludePath(dep.path("inc/libc"));
    module.addIncludePath(dep.path("inc/posix"));
    module.addIncludePath(dep.path("inc/gnu"));
    module.linkLibrary(artifact);
}

fn findDependencyArtifactByLinkage(
    dep: *std.Build.Dependency,
    name: []const u8,
    linkage: std.builtin.LinkMode,
) *std.Build.Step.Compile {
    var found: ?*std.Build.Step.Compile = null;
    for (dep.builder.install_tls.step.dependencies.items) |dep_step| {
        const install_artifact = dep_step.cast(std.Build.Step.InstallArtifact) orelse continue;
        if (!std.mem.eql(u8, install_artifact.artifact.name, name)) continue;
        if (install_artifact.artifact.linkage != linkage) continue;

        if (found != null) {
            std.debug.panic(
                "artifact '{s}' with linkage '{s}' is ambiguous in dependency",
                .{ name, @tagName(linkage) },
            );
        }
        found = install_artifact.artifact;
    }

    if (found) |artifact| return artifact;
    std.debug.panic(
        "unable to find artifact '{s}' with linkage '{s}' in dependency install graph",
        .{ name, @tagName(linkage) },
    );
}
