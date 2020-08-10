# LibDeflate.jl

This package provides minimalist Julia bindings for [libdeflate](https://github.com/ebiggers/libdeflate).

Libdeflate is a heavily optimized implementation of the DEFLATE compression algorithm. Unlike libz or gzip, libdeflate does not support streaming, and so is intended for use in block compression. But it is significantly faster than either libz or gzip.

This package provides only two types and three functions:

* `Decompressor`: Create an object that decompresses using DEFLATE.
* `Compressor(N)`: Create an object that compresses using DEFLATE level `N`.
* `decompress!` Compress a byte vector into another byte vector using a `Decompressor`.
* `compress!` Compresses a byte vector into another byte vector using a `Compressor`
* `crc32(data, N)` computes the crc32 checksum of the first `N` bytes of byte vector `data`

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

For extra speed, you can pass the size of the decompressed data to `decompress!`, using `decompress!(decompressor, outvector, compressed, 55)`.
