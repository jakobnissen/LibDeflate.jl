# LibDeflate.jl

![CI](https://github.com/jakobnissen/LibDeflate.jl/workflows/CI/badge.svg)
[![Codecov](https://codecov.io/gh/jakobnissen/LibDeflate.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/jakobnissen/LibDeflate.jl)

This package provides Julia bindings for [libdeflate](https://github.com/ebiggers/libdeflate).

Libdeflate is a heavily optimized implementation of the DEFLATE compression algorithm used in the zip, bgzip and gzip formats. Unlike libz or gzip, libdeflate does not support streaming, and so is intended for use in of files that fit in-memory or for block-compressed files like bgzip. But it is significantly faster than either libz or gzip.

This package provides simple functionality for working with raw DEFLATE payloads, zlib and gzip data. It is intended for internal use by other packages, not to be used directly by users. Hence, its interface is somewhat small.

### Interface
Many functions have a  "safe" and an "unsafe" variant. The unsafe works with pointers, the safe attempts to convert Julia objects to `ReadableMemory` or `WriteableMemory`, which are simply structs containing pointers.
When possible, use the safe variants as the overhead is rather small.

For more details on these functions, read their docstrings which define their API.
Functions and types without a docstring are internal.

No functions here are expected to throw errors. On error, they return a `LibDeflateError` object.

__Common exported types__
* `Decompressor`: Create an object that decompresses using DEFLATE.
* `Compressor(N)`: Create an object that compresses using DEFLATE level `N`.
* `LibDeflateError`: An enum will all LibDeflate errors. Functions are either successful or return this.
* `ReadableMemory`: A pointer and a length. Constructable from types that are pointer-readable.
* `WriteableMemory`: A pointer and a length. Constructable from types that are pointer-writeable.

__Working with DEFLATE payloads__
* `(unsafe_)decompress!`: DEFLATE decompress payload.
* `(unsafe_)compress!`: DEFLATE compress payload

__Working with gzip files__
* `(unsafe_)gzip_decompress!`: Decompress gzip data.
* `(unsafe_)gzip_compress!`: Compress gzip data and/or metadata

* `(unsafe_)parse_gzip_header`: Parse out gzip header
* `is_valid_extra_data`: Check if some bytes are valid metadata for the gzip "extra" field.

__Working with Libz files__
* `(unsafe_)lib_decompress!`: Decompress zlib data.
* `(unsafe_)zlib_compress!`: Compress zlib data

__Miscellaneous__
* `(unsafe)_crc32`: Compute the crc32 checksum of the bytes at `data`. Note that this is _not_ the same algorithm as `crc32c`.
* `(unsafe)_adler32`: Compute the Adler32 checksum of the bytes at `data`.

