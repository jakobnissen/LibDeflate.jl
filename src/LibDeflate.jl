"""
    Module LibDeflate

`LibDeflate` provides Julia bindings for the C library `libdeflate`. The C library,
and the corresponding Julia package, contain highly optimized code for compressing and
uncompressing data using the DEFLATE algorithm, including gzip, or zlib formats.
"""
module LibDeflate

using libdeflate_jll

# Alias Base unions to avoid relying on internals
const BitInteger = Union{Int128, Int16, Int32, Int64, Int8, UInt128, UInt16, UInt32, UInt64, UInt8}
const IEEEFloat = Union{Float16, Float32, Float64}

"""
    Module LibDeflateErrors

Dummy module to contain the variants of the `LibDeflateError` enum.
"""
module LibDeflateErrors

    @enum LibDeflateError::UInt8 begin
        deflate_bad_payload
        deflate_output_too_short
        deflate_insufficient_space
        gzip_header_too_short
        gzip_bad_magic_bytes
        gzip_not_deflate
        gzip_string_not_null_terminated
        gzip_null_in_string
        gzip_bad_header_crc16
        gzip_bad_crc32
        gzip_extra_too_long
        gzip_bad_extra
        zlib_input_too_short
        zlib_not_deflate
        zlib_wrong_window_size
        zlib_needs_compression_dict
        zlib_bad_header_check
        zlib_bad_adler32
        zlib_insufficient_space
    end

    @doc """
        LibDeflateError

    A `UInt8` enum representing that LibDeflate encountered an error. The numerical value
    of the errors are not stable across non-breaking releases, but their names are.
    Code checking for specific errors should check by e.g. ` == LibDeflateErrors.gzip_not_deflate`.
    Successful operations will never return a `LibDeflateError`.
    """
    LibDeflateError

    export LibDeflateError
end # module

using .LibDeflateErrors

const DEFAULT_COMPRESSION_LEVEL = 6

"""
    WriteableMemory

Struct that wraps a pointer and a length. This struct is not garbage-collector aware,
so must be used with `GC.@preserve`. This can be constructed from types that are
pointer-writeable, like integer arrays.
To make custom types available as input for `LibDeflate`, add a constructor taking
your custom type.

See also: [`ReadableMemory`](@ref)
"""
struct WriteableMemory
    ptr::Ptr{Nothing}
    len::UInt
end

# We can only write to types where we know they are mutable, that
# `pointer` and `sizeof` are correct (unlike e.g. subarrays with non-1-strides),
# and where all bitpatterns are legal values.
function WriteableMemory(
    x::Union{
        Array{T},
        SubArray{T,N,<:Array{T},<:Tuple{Vararg{AbstractUnitRange}}} where N,
    },
) where {T<:Union{BitInteger, IEEEFloat}}
    return WriteableMemory(pointer(x), sizeof(x))
end
WriteableMemory(x::WriteableMemory) = x

"""
    ReadableMemory

Struct that wraps a pointer and a length. This struct is not garbage-collector aware,
so must be used with `GC.@preserve`. This can be constructed from types that are
pointer-readable, like integer arrays.
To make custom types available as input for `LibDeflate`, add a constructor taking
your custom type.

See also: [`WriteableMemory`](@ref)
"""
struct ReadableMemory
    ptr::Ptr{Nothing}
    len::UInt
end

# We can read from data with the same pointer and stride requirements, but
# the data only needs to be bitvalues. Also, we can read from immutable structs.
# We let T be a free parameter so we can check whether it is a bitstype
function ReadableMemory(
    x::Union{
        Array,
        SubArray{T,N,<:Array,<:Tuple{Vararg{AbstractUnitRange}}} where {T,N},
        String,
        SubString{String},
        WriteableMemory,
        ReadableMemory,
    },
)
    # This check happens to also work for WriteableMemory and strings.
    isbitstype(eltype(x)) || error("Container element type must be a bitstype")
    return ReadableMemory(pointer(x), sizeof(x))
end

Base.pointer(x::Union{ReadableMemory,WriteableMemory}) = x.ptr
Base.sizeof(x::Union{ReadableMemory,WriteableMemory}) = x.len % Int
Base.eltype(::Union{Type{ReadableMemory},Type{WriteableMemory}}) = Nothing

# Must be mutable for the GC to be able to interact with it
"""
    Decompressor()

Create an object which can decompress using the DEFLATE algorithm.
The same decompressor cannot be used by multiple threads at the same time.
To parallelize decompression, create multiple instances of `Decompressor`
and use one for each thread.
Creating this object allocates, so when decompressing multiple blocks, keep
the same decompressor in memory rather than making one for each block.

See also: [`decompress!`](@ref), [`unsafe_decompress!`](@ref)
"""
mutable struct Decompressor
    actual_nbytes_ret::UInt
    ptr::Ptr{Nothing}
end

Base.unsafe_convert(::Type{Ptr{Nothing}}, x::Decompressor) = x.ptr

function Decompressor()
    decompressor = Decompressor(
        0, ccall((:libdeflate_alloc_decompressor, libdeflate), Ptr{Nothing}, ())
    )
    finalizer(free_decompressor, decompressor)
    return decompressor
end

function free_decompressor(decompressor::Decompressor)
    ccall(
        (:libdeflate_free_decompressor, libdeflate), Nothing, (Ptr{Nothing},), decompressor
    )
    return nothing
end

"""
    Compressor(compresslevel::Int=$(DEFAULT_COMPRESSION_LEVEL))

Create an object which can compress using the DEFLATE algorithm. `compresslevel`
can be from 1 (fast) to 12 (slow), and defaults to $(DEFAULT_COMPRESSION_LEVEL).
The same compressor cannot be used by multiple threads at the same time.
To parallelize compression, create multiple instances of `Compressor` and use one for each thread.
Creating this object allocates, so when compressing multiple blocks, keep
the same compressor in memory rather than making one for each block.

See also: [`compress!`](@ref), [`unsafe_compress!`](@ref)
"""
mutable struct Compressor
    level::Int
    ptr::Ptr{Nothing}
end

Base.unsafe_convert(::Type{Ptr{Nothing}}, x::Compressor) = x.ptr

function Compressor(compresslevel::Integer=DEFAULT_COMPRESSION_LEVEL)
    compresslevel in 1:12 || throw(ArgumentError("Compresslevel must be in 1:12"))
    ptr = ccall(
        (:libdeflate_alloc_compressor, libdeflate), Ptr{Nothing}, (Csize_t,), compresslevel
    )
    compressor = Compressor(compresslevel, ptr)
    finalizer(free_compressor, compressor)
    return compressor
end

# Called by the garbage collecter, do not use manually
function free_compressor(compressor::Compressor)
    ccall((:libdeflate_free_compressor, libdeflate), Nothing, (Ptr{Nothing},), compressor)
    return nothing
end

# Compression and decompression functions

# Raw C call - do not export this
function _unsafe_decompress!(
    decompressor::Decompressor,
    out_ptr::Ptr,
    out_len::Integer,
    in_ptr::Ptr,
    inlen::Integer,
    nptr::Ptr,
)::Union{LibDeflateError,Nothing}
    status = @ccall gc_safe=true libdeflate.libdeflate_deflate_decompress(
    	decompressor::Ptr{Nothing},
    	in_ptr::Ptr{UInt8},
    	inlen::Csize_t,
    	out_ptr::Ptr{UInt8},
    	out_len::Csize_t,
    	nptr::Ptr{UInt},
    )::Csize_t
    if status == Cint(1)
        return LibDeflateErrors.deflate_bad_payload
    elseif status == Cint(2)
        return LibDeflateErrors.deflate_output_too_short
    elseif status == Cint(3)
        return LibDeflateErrors.deflate_insufficient_space
    else
        return nothing
    end
end

"""
    unsafe_decompress!(
        s::IteratorSize, ::Decompressor,
        out_ptr::Ptr, n_out::Integer,
        in_ptr::Ptr, n_in::Integer
    )::Union{Int, LibDeflateError}

Decompress `n_in` bytes from `in_ptr` to `out_ptr` using the DEFLATE algorithm,
returning the number of decompressed bytes or the error encounted.
`s` should be whether you know the decompressed size or not.

If `s` isa `Base.HasLength`, the number of decompressed bytes is given as `n_out`.
This is more efficient, but will fail if the number is not correct.

If `s` isa `Base.SizeUnknown`, pass the size in bytes of the available space at the output
to `n_out`.

See also: [`decompress!`](@ref)
"""
function unsafe_decompress! end

function unsafe_decompress!(
    ::Base.HasLength,
    decompressor::Decompressor,
    out_ptr::Ptr,
    n_out::Integer,
    in_ptr::Ptr,
    n_in::Integer,
)::Union{LibDeflateError,Int}
    y = _unsafe_decompress!(decompressor, out_ptr, n_out, in_ptr, n_in, C_NULL)
    return y isa LibDeflateError ? y : Int(n_out)
end

function unsafe_decompress!(
    ::Base.SizeUnknown,
    decompressor::Decompressor,
    out_ptr::Ptr,
    n_out::Integer,
    in_ptr::Ptr,
    n_in::Integer,
)::Union{LibDeflateError,Int}
    y = GC.@preserve decompressor begin
        retptr = pointer_from_objref(decompressor)
        _unsafe_decompress!(decompressor, out_ptr, n_out, in_ptr, n_in, retptr)
    end
    return y isa LibDeflateError ? y : (decompressor.actual_nbytes_ret % Int)
end

"""
    decompress!(
        ::Decompressor, out_data, in_data, [n_out::Integer]
    )::Union{LibDeflateError, Int}

Use the passed `Decompressor` to decompress the data at `in_data` into the
first bytes of `out_data` using the DEFLATE algorithm,
returning the number of written bytes to the output, or a `LibDeflateError`.
Data must fit in `out_data`.

If the decompressed size is known beforehand, pass it as `n_out`. This will increase
performance, but will fail if it is wrong.
"""
function decompress! end

# Decompress method with length known (preferred)
function decompress!(
    decompressor::Decompressor, out_data, in_data, n_out::Integer
)::Union{LibDeflateError,Int}
    GC.@preserve out_data in_data begin
        read = ReadableMemory(in_data)
        write = WriteableMemory(out_data)
        sizeof(write) < n_out && return LibDeflateErrors.deflate_insufficient_space
        unsafe_decompress!(
            Base.HasLength(),
            decompressor,
            pointer(write),
            n_out,
            pointer(read),
            sizeof(read),
        )
    end
end

# Decompress method with length unknown (not preferred)
function decompress!(
    decompressor::Decompressor, out_data, in_data
)::Union{LibDeflateError,Int}
    GC.@preserve out_data in_data begin
        read = ReadableMemory(in_data)
        write = WriteableMemory(out_data)
        unsafe_decompress!(
            Base.SizeUnknown(),
            decompressor,
            pointer(write),
            sizeof(write),
            pointer(read),
            sizeof(read),
        )
    end
end

"""
    unsafe_compress!(
        ::Compressor, out_ptr::Ptr, n_out::Integer, in_ptr::Ptr, n_in::Integer
    )::Union{Int. LibDeflateError}

Use the passed `Compressor` to compress `n_in` bytes from the pointer `in_ptr`
to the pointer `n_out` where there are `n_out` bytes of space to write to.

Return the number of written bytes to the output, or a `LibDeflateError`.

See also: [`compress!`](@ref)
"""
function unsafe_compress!(
    compressor::Compressor, out_ptr::Ptr, n_out::Integer, in_ptr::Ptr, n_in::Integer
)::Union{LibDeflateError,Int}
    bytes = @ccall gc_safe=true libdeflate.libdeflate_deflate_compress(
		compressor::Ptr{Nothing},
		in_ptr::Ptr{UInt8},
		n_in::Csize_t,
		out_ptr::Ptr{UInt8},
		n_out::Csize_t,
	)::Csize_t
    iszero(bytes) && return LibDeflateErrors.deflate_insufficient_space
    return bytes % Int
end

"""
    compress!(::Compressor, out_data, in_data)::Union{LibDeflateError, Int}

Use the passed `Compressor` to compress `in_data` into the first
bytes of `out_data` using the DEFLATE algorithm.
Data must fit in `out_data`.

Return the number of written bytes to the output, or a `LibDeflateError`.
"""
function compress!(compressor::Compressor, out_data, in_data)::Union{LibDeflateError,Int}
    GC.@preserve out_data in_data begin
        read = ReadableMemory(in_data)
        write = WriteableMemory(out_data)
        unsafe_compress!(
            compressor, pointer(write), sizeof(write), pointer(read), sizeof(read)
        )
    end
end

"""
    unsafe_crc32(in_ptr::Ptr, n_in::Integer, start::UInt32)::UInt32

Calculate the crc32 checksum of the first `n_in` bytes of the pointer `in_ptr`,
with seed `start` (default is 0).
Note that crc32 is a different and slower algorithm than the `crc32c` provided
in the Julia standard library.

See also: [`crc32`](@ref)
"""
function unsafe_crc32(in_ptr::Ptr, n_in::Integer, start::UInt32=UInt32(0))
    return @ccall gc_safe=true libdeflate.libdeflate_crc32(
		start::UInt32,
		in_ptr::Ptr{UInt8},
		n_in::Csize_t,
    )::UInt32
end

"""
    crc32(data, start=UInt32(0))::UInt32

Calculate the crc32 checksum of `data` and seed `start` (0 by default).
Note that crc32 is a different and slower algorithm than the `crc32c` provided
in the Julia standard library.

See also: [`unsafe_crc32`](@ref)
"""
function crc32(data, start::UInt32=UInt32(0))
    GC.@preserve data begin
        read = ReadableMemory(data)
        unsafe_crc32(pointer(read), sizeof(read), start)
    end
end

"""
    unsafe_adler32(data, start=UInt32(1))::UInt32

Calculate the adler32 checksum of the first `n_in` of the pointer `in_ptr`,
with seed `start` (default is 1).

See also: [`adler32`](@ref)
"""
function unsafe_adler32(in_ptr::Ptr, n_in::Integer, start::UInt32=UInt32(1))
    return @ccall gc_safe=true libdeflate.libdeflate_adler32(
		start::UInt32,
		in_ptr::Ptr{UInt8},
		n_in::Csize_t,
	)::UInt32
end

"""
    adler32(data, start=UInt32(1))::UInt32

Calculate the adler32 checksum of the byte vector `data` and seed `start` (1 by default).

See also: [`unsafe_adler32`](@ref)
"""
function adler32(data, start::UInt32=UInt32(1))
    GC.@preserve data begin
        read = ReadableMemory(data)
        unsafe_adler32(pointer(read), sizeof(read), start)
    end
end

include("gzip.jl")
include("zlib.jl")

export Decompressor,
    Compressor,
    LibDeflateErrors,
    LibDeflateError,
    WriteableMemory,
    ReadableMemory,
    unsafe_decompress!,
    decompress!,
    unsafe_compress!,
    compress!,
    unsafe_gzip_decompress!,
    gzip_decompress!,
    unsafe_gzip_compress!,
    gzip_compress!,
    unsafe_zlib_decompress!,
    zlib_decompress!,
    unsafe_zlib_compress!,
    zlib_compress!,
    unsafe_crc32,
    crc32,
    unsafe_adler32,
    adler32,
    unsafe_parse_gzip_header,
    parse_gzip_header,
    is_valid_extra_data

end # module
