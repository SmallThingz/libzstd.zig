pub const c = @cImport({
    @cDefine("ZSTD_STATIC_LINKING_ONLY", "1");
    @cInclude("zstd.h");
    @cInclude("zstd_errors.h");
    @cInclude("zdict.h");
});
