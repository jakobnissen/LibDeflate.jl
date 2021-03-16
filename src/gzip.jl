# Returns index of next zero or Nothing if no zero is found
function unsafe_next_zero(p::Ptr{UInt8}, len::UInt, i::UInt32)::Union{Nothing, UInt32}
    mem = SizedMemory(p + i - 1, len)
    n = memchr(mem, 0x00)
    n === nothing ? nothing : n % UInt32 + i - one(UInt32)
end

"""
    GzipDecompressResult

Result of `LibDeflate`'s gzip decompression on byte vector. The fields `extra`,
`filename` and `comment` specify the location of gzip feature data in the input vector.
When not applicable (e.g. the `extra` field is not applicable for gzip files 
without the `FEXTRA` flag), these fields are zeroed out.

It has the following fields, all of type ``.
* `len`::UInt32` length of decompressed data
* `reserved::UInt32` internal use only, always set to zero
* `extra::UnitRange{UInt32}` location of gzip extra data (or zero)
* `filename::UnitRange{UInt32}` location of filename (or zero)
* `comment::UnitRange{UInt32}` location of gzip comment (or zero)
"""
struct GzipDecompressResult
    len::UInt32
    reserved::UInt32 # for alignment, reserve for future versions
    extra::UnitRange{UInt32}
    filename::UnitRange{UInt32}
    comment::UnitRange{UInt32}
end

# TODO: Merge this with the other LibDeflateError
@noinline function gzip_error(code::Int)
    message = if code == 1
        "Bad header"
    elseif code == 2
        "Unterminated null string"
    elseif code == 3
        "Header CRC16 checksum does not match"
    elseif code == 4
        "Payload CRC132 checksum does not match"
    elseif code == 5
        "Output data too long"
    elseif code == 6
        "Input data too short"
    elseif code == 7
        "Extra data too long"
    end
    throw(LibDeflateError(code, message))
end

function unsafe_gzip_decompress!(
    decompressor::Decompressor, 
    out_data::Vector{UInt8}, 
    max_outlen::UInt,
    in_ptr::Ptr{UInt8},
    len::UInt
)
    # 10 byte header + 2 byte compression + 8 byte tail
    len > 18 || gzip_error(6)
    # Bytes 1 - 10. Check first four bytes, skip rest
    # +---+---+---+---+---+---+---+---+---+---+
    # |ID1|ID2|CM |FLG|     MTIME     |XFL|OS | (more-->)
    # +---+---+---+---+---+---+---+---+---+---+
    ptr = in_ptr - UInt(1) # zero-indexed pointer
    header = ltoh(unsafe_load(Ptr{UInt32}(ptr + 1)))
    header & 0x00ffffff == 0x00088b1f || gzip_error(1)
    FLAG_HCRC =    !iszero(header & 0x02000000)
    FLAG_EXTRA =   !iszero(header & 0x04000000)
    FLAG_NAME =    !iszero(header & 0x08000000)
    FLAG_COMMENT = !iszero(header & 0x10000000)

    # 32-bit index because this library only works with 32-bit buffers anyway
    index = UInt32(11)

    extra = UInt32(0):UInt32(0)
    # skip XLEN
    if FLAG_EXTRA
        # +---+---+=================================+
        # | XLEN  |...XLEN bytes of "extra field"...| (more-->)
        # +---+---+=================================+
        extra_len = ltoh(unsafe_load(Ptr{UInt16}(ptr + index)))
        extra = index + UInt32(2):index + extra_len + one(UInt32)
        index += extra_len + UInt32(2)
        index > (len - 9) && gzip_error(2)
    end

    filename = UInt32(0):UInt32(0)
    if FLAG_NAME
        # +=========================================+
        # |...original file name, zero-terminated...| (more-->)
        # +=========================================+
        zero_pos = unsafe_next_zero(ptr + 1, len, index)
        (zero_pos === nothing || zero_pos > (len - 10)) && gzip_error(2)
        filename = index:zero_pos - one(UInt32)
        index = zero_pos + one(UInt32)
    end

    # Skip comment
    comment = UInt32(0):UInt32(0)
    if FLAG_COMMENT
        zero_pos = unsafe_next_zero(ptr + 1, len, index)
        (zero_pos === nothing || zero_pos > (len - 10)) && gzip_error(2)
        comment = index:zero_pos - one(UInt32)
        index = zero_pos + one(UInt32)
    end

    # Verify header CRC16, if present
    if FLAG_HCRC
        # Lower 16 bits of crc32 up to, not including, this index
        # +---+---+
        # | CRC16 |
        # +---+---+
        crc_obs_16 = unsafe_crc32(ptr + one(UInt), index - one(UInt)) % UInt16
        crc_exp_16 = ltoh(unsafe_load(Ptr{UInt16}(ptr + index)))
        crc_obs_16 == crc_exp_16 || gzip_error(3)
        index += UInt32(2)
        index > (len - 9) && gzip_error(2)
    end

    compressed_len = len - UInt(8) - index + one(UInt)

    # Skip to end to check crc32 and data len
    # +---+---+---+---+---+---+---+---+
    # |     CRC32     |     ISIZE     | END OF FILE
    # +---+---+---+---+---+---+---+---+

    uncompressed_size = ltoh(unsafe_load(Ptr{UInt32}(ptr + len - UInt(3))))
    uncompressed_size > max_outlen && gzip_error(5)
    length(out_data) < uncompressed_size && resize!(out_data, uncompressed_size)

    # Now DEFLATE decompress
    unsafe_decompress!(Base.HasLength(), decompressor, pointer(out_data), uncompressed_size,
    ptr + index, compressed_len)

    # Check for CRC
    crc_exp = ltoh(unsafe_load(Ptr{UInt32}(ptr + len - UInt(7))))
    crc_obs = unsafe_crc32(pointer(out_data), uncompressed_size % Int)
    crc_exp == crc_obs || gzip_error(4)

    GzipDecompressResult(uncompressed_size, UInt32(0), extra, filename, comment)
end

"Computes maximal output length of a gzip compression"
function max_out_len(input_len::UInt, comment_len::UInt, filename_len::UInt, extra_len::UInt16, header_crc::Bool)
    # From Mark Adler, StackOverflow (https://stackoverflow.com/a/23578269/10992667)
    static = 10 + 8 # header + tail
    n_chunks = fld(input_len, 16383) + 1
    len = static + input_len + 5 * n_chunks # 5 byte overhead per chunk
    len += comment_len + !iszero(comment_len) # incl. null byte
    len += filename_len + !iszero(filename_len) # incl. null byte
    len += extra_len + 2 * !iszero(extra_len) # incl. 2-byte leader
    len += 2*header_crc
    return len
end

# Returns length of compressed data (Int)
function unsafe_gzip_compress!(
    compressor::Compressor,
    out_ptr::Ptr{UInt8},
    out_len::UInt,
    in_ptr::Ptr{UInt8},
    in_len::UInt,
    comment::Union{SizedMemory, Nothing},
    filename::Union{SizedMemory, Nothing},
    extra::Union{SizedMemory, Nothing},
    crc_header::Bool,
)    
    # Check output len is long enough
    maxlen = max_out_len(
        in_len,
        comment === nothing ? UInt(0) : length(comment),
        filename === nothing ? UInt(0) : length(filename),
        if extra === nothing
            UInt16(0)
        else
            # No more than typemax(UInt16) bytes for extra field
            length(extra) > typemax(UInt16) && gzip_error(7)
            length(extra) % UInt16
        end,
        crc_header
    ) > out_len && gzip_error(5)

    # Write first four bytes - magix number, compression type, flags
    header = 0x00088b1f
    if comment !== nothing
        # Check for absence of zero byte
        memchr(comment, 0x00) === nothing || gzip_error(2)
        header |= 0x10000000
    end
    if filename !== nothing
        # Check for absence of zero byte
        memchr(filename, 0x00) === nothing || gzip_error(2)
        header |= 0x08000000
    end
    if extra !== nothing
        header |= 0x04000000
    end
    header = ifelse(crc_header, header | 0x02000000, header)
    ptr = out_ptr - 1
    unsafe_store!(Ptr{UInt32}(ptr + 1), htol(header))

    # Add system time (take lower 32 bits if it overflows)
    unsafe_store!(Ptr{UInt32}(ptr + 5), htol(unsafe_trunc(UInt32, time())))

    # Add system (always UNIX) and XFL (zero)
    unsafe_store!(Ptr{UInt16}(ptr + 9), htol(0x0003))

    index = UInt(11)
    
    # Add in extra data
    if extra !== nothing
        unsafe_store!(Ptr{UInt16}(ptr + index), htol(length(extra) % UInt16))
        unsafe_copyto!(ptr + index + 2, pointer(extra), length(extra))
        index += UInt(2) + length(extra)
    end

    # Add in filename
    if filename !== nothing
        unsafe_copyto!(ptr + index, pointer(filename), length(filename))
        index += length(filename) + one(UInt) # null byte
        unsafe_store!(ptr + index - 1, 0x00)
    end

    # Add in comment
    if comment !== nothing
        unsafe_copyto!(ptr + index, pointer(comment), length(comment))
        index += length(comment) + one(UInt) # null byte
        unsafe_store!(ptr + index - 1, 0x00)
    end

    # Add in CRC16
    if crc_header
        header_crc = unsafe_crc32(ptr + one(UInt), index - one(UInt)) % UInt16
        unsafe_store!(Ptr{UInt16}(ptr + index), htol(header_crc))
        index += UInt(2)
    end

    # Add in compressed data
    remaining_outdata = out_len - index + 1 - 8 # tail
    n_compressed = unsafe_compress!(compressor, ptr + index, remaining_outdata, in_ptr, in_len)
    index += n_compressed

    # Add in crc
    crc = unsafe_crc32(in_ptr, in_len)
    unsafe_store!(Ptr{UInt32}(ptr + index), htol(crc))
    index += 4

    # Add in isize
    unsafe_store!(Ptr{UInt32}(ptr + index), htol(in_len % UInt32))
    return (index + 3) % Int # 4 bytes isize - off-by-one
end
