module LibDeflate

using Libdl

const libdeflate = find_library(["libdeflate.so", "libdeflate.so.0"])
if isempty(libdeflate)
    throw(ValueError("Cannot find library \"libdeflate\""))
end

# Must be mutable for the GC to be able to interact with it
"""
	Decompressor() -> Decompressor

Create an object to do LibDeflate decompression. The same decompressor cannot be
used by multiple threads at the same time. To parallelize decompression,
create multiple instances of `Decompressor` and use one for each thread.
"""
mutable struct Decompressor
	actual_nbytes_ret::Cint
	ptr::Ptr{Nothing}
end

Base.unsafe_convert(::Type{Ptr{Nothing}}, x::Decompressor) = x.ptr

function Decompressor()
	decompressor = Decompressor(0, ccall((:libdeflate_alloc_decompressor, 
	               libdeflate), Ptr{Nothing}, ()))
	finalizer(free_decompressor, decompressor)
	return decompressor
end

function free_decompressor(decompressor::Decompressor)
	ccall((:libdeflate_free_decompressor, libdeflate), 
	       Nothing, (Ptr{Nothing},), decompressor)
	return nothing
end

"""
	Compressor(compresslevel::Int=6) -> Compressor

Create a `Compressor` which does LibDeflate compression. `compresslevel` can be
from 1 (fast) to 12 (slow), and defaults to 6. The same compressor cannot be used
by multiple threads at the same time. To parallelize compression, create
multiple instances of `Compressor` and use one for each thread.
"""
mutable struct Compressor
	level::Int
	ptr::Ptr{Nothing}
end

Base.unsafe_convert(::Type{Ptr{Nothing}}, x::Compressor) = x.ptr

function Compressor(compresslevel::Int=6)
	compresslevel in 1:12 || throw(ArgumentError("Compresslevel must be in 1:12"))
	ptr = ccall((:libdeflate_alloc_compressor, libdeflate), Ptr{Nothing},
	            (Cint,), compresslevel)
	compressor = Compressor(compresslevel, ptr)
	finalizer(free_compressor, compressor)
	return compressor
end

function free_compressor(compressor::Compressor)
	ccall((:libdeflate_free_compressor, libdeflate), Nothing, (Ptr{Nothing},), compressor)
	return nothing
end

# Compression and decompression functions
# Types and constants
const LIBDEFLATE_SUCCESS            = Cint(0)
const LIBDEFLATE_BAD_DATA           = Cint(1)
const LIBDEFLATE_SHORT_INPUT        = Cint(2)
const LIBDEFLATE_INSUFFICIENT_SPACE = Cint(3)

"""
	LibDeflateError(code::Int, message::String)

`LibDeflate` failed with error code `code`.
"""
struct LibDeflateError <: Exception
	code::Int
	msg::String
end

function check_return_code(code)
	if code == LIBDEFLATE_BAD_DATA
		throw(LibDeflateError(LIBDEFLATE_BAD_DATA, "Bad data"))
	elseif code == LIBDEFLATE_SHORT_INPUT
		throw(LibDeflateError(LIBDEFLATE_SHORT_INPUT, "Short input"))
	elseif code == LIBDEFLATE_INSUFFICIENT_SPACE
		throw(LibDeflateError(LIBDEFLATE_INSUFFICIENT_SPACE, "Insufficient space"))
	end
end

"""
    decompress!(::Decompressor, outdata, indata, [len::Int]) -> Int

Use the passed `Decompressor` to decompress the byte vector `indata` into the
first bytes of `outdata` using the DEFLATE algorithm.
If the decompressed size is known beforehand, pass it as `len`. This will increase
performance, but will fail if it is wrong.

Return the number of bytes written to `outdata`.
"""
function decompress! end

# Decompress method with length known (preferred)
function decompress!(decompressor::Decompressor,
                     outdata::Vector{UInt8}, indata::Vector{UInt8}, len::Int)
    if length(outdata) < len
        throw(ValueError("len must be less than or equal to length of outdata"))
    end
    status = ccall((:libdeflate_deflate_decompress, libdeflate), Cint,
                  (Ptr{Nothing}, Ptr{Nothing}, Cint, Ptr{Nothing}, Cint, Ptr{Cint}),
                   decompressor, indata, length(indata), outdata, len, C_NULL)
    check_return_code(status)
    return len
end

# Decompress method with length unknown (not preferred)
function decompress!(decompressor::Decompressor,
		             outdata::Vector{UInt8}, indata::Vector{UInt8})
    GC.@preserve decompressor begin
        retptr = Ptr{Cint}(pointer_from_objref(decompressor))
        status = ccall((:libdeflate_deflate_decompress, libdeflate), Cint,
                       (Ptr{Nothing}, Ptr{Nothing}, Cint, Ptr{Nothing}, Cint, Ptr{Cint}),
                       decompressor, indata, length(indata), outdata, length(outdata), retptr)
    end
    check_return_code(status)
    return decompressor.actual_nbytes_ret % Int
end

"""
    compress!(::Compressor, outdata, indata) -> Int

Use the passed `Compressor` to compress the byte vector `indata` into the first
bytes of `outdata` using the DEFLATE algorithm.

The output must fit in `outdata`. Return the number of bytes written to `outdata`.
"""
function compress!(compressor::Compressor,
                   outdata::Vector{UInt8}, indata::Vector{UInt8})
    bytes = ccall((:libdeflate_deflate_compress, libdeflate), Cint,
            (Ptr{Nothing}, Ptr{Nothing}, Cint, Ptr{Nothing}, Cint),
            compressor, indata, length(indata), outdata, length(outdata))

    if iszero(bytes)
        throw(LibDeflateError(0, "Buffer too small"))
    end
    return bytes % Int
end

"""
    crc32(data, nbytes)

Calculate the `UInt32` crc32 checksum of the first `nbytes` of the byte vector `data`.
"""
function crc32(data::Vector{UInt8}, nbytes::Int)
    return ccall((:libdeflate_crc32, libdeflate),
           UInt32, (Cint, Ptr{Nothing}, Cint), 0, data, nbytes % Cint)
end

export Decompressor,
       Compressor,
       decompress!,
       compress!

end # module
