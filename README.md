# LibDeflate.jl

![CI](https://github.com/jakobnissen/LibDeflate.jl/workflows/CI/badge.svg)
[![Codecov](https://codecov.io/gh/jakobnissen/LibDeflate.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/jakobnissen/LibDeflate.jl)

This package provides Julia bindings for [libdeflate](https://github.com/ebiggers/libdeflate).

Libdeflate is a heavily optimized implementation of the DEFLATE compression algorithm used in the zip, bgzip and gzip formats. Unlike libz or gzip, libdeflate does not support streaming, and so is intended for use in of files that fit in-memory or for block-compressed files like bgzip. But it is significantly faster than either libz or gzip.

This package provides simple functionality for working with raw DEFLATE payloads and gzip data. It is intended for internal use by other packages, not to be used directly by users. Hence, its interface is somewhat small.

### Interface
Several functions have a "safe" and an "unsafe" variant. The unsafe works with pointers, the safe with arrays. Unless the API is significantly different, these are grouped together here.

For more details on these functions, read their docstrings.

__Common exported types__
* `Decompressor`: Create an object that decompresses using DEFLATE.
* `Compressor(N)`: Create an object that compresses using DEFLATE level `N`.
* `LibDeflateError(::String)`: An `Exception` type for this package.

__Working with DEFLATE payloads__
* `(unsafe_)decompress!`: DEFLATE decompress payload.
* `(unsafe_)compress!`: DEFLATE compress payload

__Working with gzip files__
* `(unsafe_)gzip_decompress!`: Decompress gzip data.`
* `(unsafe_)gzip_compress!`: Compress gzip data and/or metadata`

* `(unsafe_)parse_gzip_header`: Parse out gzip header
* `is_valid_extra_data`: Check if some bytes are valid metadata for the gzip "extra" field.


__Miscellaneous__
* `(unsafe)_crc32`: Compute the crc32 checksum of the byte vector `data`. Note that this is _not_ the same algorithm as `crc32c`.

## Example usage
```julia
julia> compressor = Compressor() # default to level 6
Main.LibDeflate.Compressor(6, Ptr{Nothing} @0x0000000002c37390)

julia> decompressor = Decompressor()
Main.LibDeflate.Decompressor(0, Ptr{Nothing} @0x0000000002645890)

julia> data = Vector{UInt8}("Na " * "na "^15 * "Batman!") # 55 bytes;

julia> outvector = zeros(UInt8, 128);

julia> nbytes = compress!(compressor, outvector, data)
15

julia> compressed = outvector[1:15]; String(copy(compressed))
"\xf3KT\xc8#\x059%\x96\xe4&\xe6)\x02\0"

julia> decompress!(decompressor, outvector, compressed)
55

julia> outvector[1:55] == data
true
```

For extra decompression speed, you can pass the size of the decompressed data to `decompress!`, using `decompress!(decompressor, outvector, compressed, 55)`.
