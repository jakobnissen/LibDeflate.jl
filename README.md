# LibDeflate.jl

This package provides Julia bindings for [libdeflate](https://github.com/ebiggers/libdeflate).

Libdeflate is a heavily optimized implementation of the DEFLATE compression algorithm used in the zip, bgzip and gzip formats. Unlike libz or gzip, libdeflate does not support streaming, and so is intended for use in of files that fit in-memory or for block-compressed files like bgzip. But it is significantly faster than either libz or gzip.

This package provides simple functionality for working with raw DEFLATE payloads and gzip data. It is intended for internal use by other packages, not to be used directly by users. Hence, its interface is somewhat small.

For more details on the API, read the docstrings for the relevant functions.

### Exported types
* `Decompressor`: Create an object that decompresses using DEFLATE.
* `Compressor(N)`: Create an object that compresses using DEFLATE level `N`.
* `LibDeflateError(::String)`: An `Exception` type for this package.

### Exported functions
* `unsafe_decompress!`: DEFLATE decompress data from one pointer to another
* `decompress!`: DEFLATE decompress a byte vector into another byte vector
* `unsafe_gzip_decompress!`: Gzip decompress data from a pointer to another, yielding a `GzipDecompressResult`.
* `gzip_decompress!`: Same as `unsafe_gzip_decompress!`, but works on vectors, resizing output to fit.
* `unsafe_compress`: DEFLATE compress data from one pointer to another
* `compress!`: DEFLATE compress a byte vector into another byte vector
* `unsafe_gzip_compress!`: Compress data from a pointer in gzip format.
* `gzip_compress!`: Same as `unsafe_gzip_compress!`, but works on vectors.
* `unsafe_crc32`: Compute the crc32 checksum of data obtained from a pointer.
* `crc32`: Compute the crc32 checksum of the byte vector `data`.
* `is_valid_extra_data`: Checks if data at pointer is valid gzip "extra fields".

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
