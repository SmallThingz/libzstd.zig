pub const c = @cImport({
    @cInclude("zstd.h");
    @cInclude("zdict.h");
});
