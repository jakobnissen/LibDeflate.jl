# Single-line boxes show the number of bytes, double-lined have
# a variable number of bytes. E.g. here: 1, 1, 4, N, 4.
# +---+---+---+---+---+---+===============+---+---+---+---+
# |CMF|FLG|    DICTID     |COMPRESSED DATA|     ADLER32   |    
# +---+---+---+---+---+---+===============+---+---+---+---+

"""
    zlib_decompress!(decompressor, output::Array, input)

Zlib decompress from `input` to `output`. `input` must have `pointer(x)`
and `sizeof(x)` implemented.
Return the number of bytes written, or a `LibDeflateError`.

See also: [`unsafe_zlib_decompress!`](@ref)
"""
function zlib_decompress!(
    decompressor::Decompressor,
    output::Array,
    input
)::Union{LibDeflateError, Int}
    GC.@preserve output input unsafe_zlib_decompress!(
        decompressor,
        pointer(output),
        sizeof(output),
        pointer(input),
        sizeof(input)
    )
end

"""
    unsafe_zlib_decompress!(decompressor, out_ptr, max_outlen, in_ptr, len)

Zlib decompress data beginning at `in_ptr` and `len` bytes onwards, into `out_ptr`.
Return the number of bytes written, or a `LibDeflateError`.

See also: [`zlib_decompress!`](@ref)
"""
function unsafe_zlib_decompress!(
    decompressor::Decompressor,
    out_ptr::Ptr,
    max_outlen::Integer,
    in_ptr::Ptr,
    len::Integer
)::Union{LibDeflateError, Int}
	# Must be at least 6 bytes in length + compressed
	len < 6 && return LibDeflateErrors.zlib_input_too_short

	ptr = in_ptr
	header = ltoh(unsafe_load(Ptr{UInt16}(ptr)))
	ptr += 2

	# Parse CMF: First 4 bits must be 0x8 = DEFLATE algorithm
	header & 0x000f != 0x0008 && return LibDeflateErrors.zlib_not_deflate

	# Next 4 bits must be 7, as the window size in libdeflate is hardcoded to 32 KiB.
	header & 0x00f0 != 0x0070 && return LibDeflateErrors.zlib_wrong_window

	# libdeflate does not support a custom decompression dict, I think
	header & 0x2000 != 0x0000 && return LibDeflateErrors.zlib_has_dict

    # This is ntoh, because the header checksum is interpreted as a big-endian integer.
	iszero(mod(ntoh(header), UInt16(31))) || return LibDeflateErrors.zlib_bad_header_check

    # Decompress payload
	nbytes = unsafe_decompress!(
		Base.SizeUnknown(),
		decompressor,
		out_ptr,
		max_outlen,
		ptr,
		len - 6
	)
    nbytes isa LibDeflateError && return nbytes
	
	# Then check adler32, also stored as big-endian
    exp_adler32 = ntoh(unsafe_load(Ptr{UInt32}(in_ptr) + len - 4))
    obs_adler32 = unsafe_adler32(out_ptr, nbytes)
    obs_adler32 == exp_adler32 || return LibDeflateErrors.zlib_bad_adler32

    return nbytes
end

"""
    zlib_compress!(compressor, output::Array, input)

Zlib compress from `input` to `output`. `input` must have `pointer(x)`
and `sizeof(x)` implemented.
Return the number of bytes written, or a `LibDeflateError`.

See also: [`unsafe_zlib_compress!`](@ref)
"""
function zlib_compress!(
    decompressor::Decompressor,
    output::Array,
    input
)::Union{LibDeflateError, Int}
    GC.@preserve output input unsafe_zlib_compress!(
        decompressor,
        pointer(output),
        sizeof(output),
        pointer(input),
        sizeof(input)
    )
end

"""
    unsafe_zlib_compress!(compressor, out_ptr, max_outlen, in_ptr, len)

Zlib compress data beginning at `in_ptr` and `len` bytes onwards, into `out_ptr`.
Return the number of bytes written, or a `LibDeflateError`.

See also: [`zlib_compress!`](@ref)
"""
function unsafe_zlib_compress!(
    compressor::Compressor,
    out_ptr::Ptr,
    max_outlen::Integer,
    in_ptr::Ptr,
    len::Integer
)::Union{LibDeflateError, Int}
    max_outlen < 6 && return LibDeflateErrors.zlib_insufficient_space
    # Be sure to check that all these 4 results are zero mod 31 when big-endian ordered
    header = if compressor.level == 1
        0x0178
    elseif compressor.level == DEFAULT_COMPRESSION_LEVEL
        0x5e78
    elseif compressor.level == 12
        0xda78
    else
        0x9c78
    end
    unsafe_store!(Ptr{UInt16}(out_ptr), htol(header))
    out_ptr += 2
    n_bytes = unsafe_compress!(compressor, out_ptr, max_outlen-6, in_ptr, len)
    n_bytes isa LibDeflateError && return n_bytes
    out_ptr += n_bytes
    # Alder32 is also big-endian stored
    unsafe_store!(Ptr{UInt32}(out_ptr), hton(unsafe_adler32(in_ptr, len)))
    return n_bytes + 6
end