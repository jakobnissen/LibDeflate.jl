# Returns index of next zero or Nothing if no zero is found
function unsafe_next_zero(p::Ptr{UInt8}, len::UInt, i::UInt32)::Union{Nothing, UInt32}
    mem = SizedMemory(p + i - 1, len)
    n = memchr(mem, 0x00)
    n === nothing ? nothing : n % UInt32 + i - one(UInt32)
end

# +---+---+---+---+==================================+
# |SI1|SI2|  LEN  |... LEN bytes of subfield data ...|
# +---+---+---+---+==================================+
"""
    GzipExtraField

Data structure for gzip extra data. Fields:
* `tag::NTuple{2, UInt8}` two-byte tag
* `data::UnitRange{UInt32}` location of subfield data in original vector
"""
struct GzipExtraField
    tag::Tuple{UInt8, UInt8} # (SI1, SI2)
    data::UnitRange{UInt32}
end

# The pointer points to the first byte of the first field
function parse_fields(ptr::Ptr{UInt8}, index::UInt32, remaining_bytes::UInt16)
    fields = GzipExtraField[]
    while !iszero(remaining_bytes)
        field = parse_extra_field(ptr, index, remaining_bytes)
        push!(fields, field)
        
        # We zero the range field on an empty subfield, so we take
        # that possibility into account
        field_len = ifelse(iszero(first(field.data)), zero(UInt32), last(field.data) - first(field.data) + UInt32(1))
        total_len = field_len % UInt16 + UInt16(4)
        remaining_bytes -= total_len
        ptr += total_len
        index += total_len
    end
    return fields
end

# The pointer points to the first byte of the extra fields
function parse_extra_field(ptr::Ptr{UInt8}, index::UInt32, remaining_bytes::UInt16)
    remaining_bytes < 4 && gzip_error(7)
    s1 = unsafe_load(ptr)
    s2 = unsafe_load(ptr + 1)
    iszero(s2) && gzip_error(8) # not allowed
    field_len = ltoh(unsafe_load(Ptr{UInt16}(ptr + 2)))
    field_len + 4 > remaining_bytes && gzip_error(7)
    
    # If the field is empty, we zero out the range and return that
    range = if iszero(field_len)
        UInt32(0):UInt32(0)
    else
        index+UInt32(4):index+UInt32(4)-UInt32(1)+field_len
    end
    return GzipExtraField((s1, s2), range)
end

function is_valid_extra_data(ptr::Ptr{UInt8}, remaining_bytes::UInt16)
    while !iszero(remaining_bytes)
        # First four bytes: S1, S2, field_len
        remaining_bytes < 4 && return false
        # S2 must not be zero
        iszero(unsafe_load(ptr + 1)) && return false
        field_len = ltoh(unsafe_load(Ptr{UInt16}(ptr + 2)))
        remaining_bytes < field_len + 4 && return false
        ptr += 4 + field_len
        remaining_bytes -= UInt16(4) + field_len
    end
    return true
end

"""
    GzipDecompressResult

Result of `LibDeflate`'s gzip decompression on byte vector. The fields `filename`
and `comment` specify the location of gzip feature data in the input vector.
When not applicable (e.g. the `comemnt` field is not applicable for gzip files 
without the `FCOMMENT` flag), these fields are zeroed out.

It has the following fields, all of type ``.
* `len::UInt32` length of decompressed data
* `mtime::UInt32` timestamp of original data, or zero
* `filename::UnitRange{UInt32}` location of filename (or zero)
* `comment::UnitRange{UInt32}` location of gzip comment (or zero)
* `extra::Union{Nothing, Vector{GzipExtraField}}` gzip extra data (or `nothing`)
"""
struct GzipDecompressResult
    len::UInt32
    mtime::UInt32
    filename::UnitRange{UInt32}
    comment::UnitRange{UInt32}
    extra::Union{Nothing, Vector{GzipExtraField}}
end

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
    elseif code == 8
        "Extra data invalid"
    end
    throw(LibDeflateError(message))
end

"""
    gzip_decompress!(::Decompressor, out::Vector{UInt8}, in::Vector{UInt8}, max_len=typemax(Int))

Gzip decompress the input data into `out`, and resize `out` to fit. Throws an error
if `out` would be resized to larger than `max_len`. Returns a `GzipDecompressResult`.

See also: [`unsafe_gzip_decompress!`](@ref)
"""
function gzip_decompress!(
    decompressor::Decompressor,
    out_data::Vector{UInt8},
    in_data::Union{Vector{UInt8}, String, SubString{String}};
    max_len::Integer=typemax(Int),
)
    result = unsafe_gzip_decompress!(decompressor, out_data, UInt(max_len),
    pointer(in_data), sizeof(in_data) % UInt)

    length(out_data) == result.len || resize!(out_data, result.len)
    return result
end

"""
    unsafe_gzip_decompress!(decompressor::Decompressor, outdata::Vector{UInt8},
        max_outlen::UInt, in_ptr::Ptr{UInt8}, len::UInt)

Use the `Decompressor` to decompress gzip data at `in_ptr` and `len` bytes forward
into `outdata`. If there is not enough room at `outdata`, resize `outdata`, except
if it would be biffer than `max_outlen`, in that case throw an error.

Return a `GzipDecompressResult`

See also: [`gzip_decompress!`](@ref)
"""
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
    mtime = ltoh(unsafe_load(Ptr{UInt32}(ptr + 5)))

    # 32-bit index because this library only works with 32-bit buffers anyway
    # (skip MTIME, XFL, OS), they're not useful anyway
    index = UInt32(11)

    extra = nothing
    if FLAG_EXTRA
        # +---+---+=================================+
        # | XLEN  |...XLEN bytes of "extra field"...| (more-->)
        # +---+---+=================================+
        extra_len = ltoh(unsafe_load(Ptr{UInt16}(ptr + index)))
        extra = parse_fields(ptr + index + 2, index + UInt32(2), extra_len)
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

    GzipDecompressResult(uncompressed_size, mtime, filename, comment, extra)
end

"Computes maximal output length of a gzip compression"
function max_out_len(input_len::UInt, comment_len::UInt, filename_len::UInt, extra_len::UInt16, header_crc::Bool)
    # Taken from libdeflate source code
    # with slight modifications
    static = 10 + 8 + 9 # header + footer + padding

    n_chunks = max(cld(input_len, 10000), 1)
    len = static + input_len + 5 * n_chunks # 5 byte overhead per chunk
    len += comment_len + !iszero(comment_len) # incl. null byte
    len += filename_len + !iszero(filename_len) # incl. null byte
    len += extra_len + 2 * !iszero(extra_len) # incl. 2-byte leader
    len += 2*header_crc
    return len
end

"""
    gzip_compress!(
        compressor::Compressor,
        output::Vector{UInt8},
        input::Vector{UInt8},
        comment::Union{String, SubString{String}, Vector{UInt8}, Nothing}=nothing,
        filename::Union{String, SubString{String}, Vector{UInt8}, Nothing}=nothing,
        extra::Union{String, SubString{String}, Vector{UInt8}, Nothing}=nothing,
        header_crc::Bool=false
    )

Gzip compress `input` into `output` and resizing output to fit. Returns `output`.

Adds optional data `comment`, `filename`, `extra` and `header_crc`:
* `comment` and `filename` must not include the byte `0x00`.
* `extra` must be at most `typemax(UInt16)` bytes long.
* `header_crc` is true, add the header CRC checksum.

See also: [`unsafe_gzip_compress!`](@ref)
"""
function gzip_compress!(
    compressor::Compressor,
    output::Vector{UInt8},
    input::Union{String, SubString{String}, Vector{UInt8}};
    comment::Union{String, SubString{String}, Vector{UInt8}, Nothing}=nothing,
    filename::Union{String, SubString{String}, Vector{UInt8}, Nothing}=nothing,
    extra::Union{String, SubString{String}, Vector{UInt8}, Nothing}=nothing,
    header_crc::Bool=false
)
    # Resize output to maximal possible length
    maxlen = max_out_len(
        sizeof(input) % UInt,
        comment === nothing ? UInt(0) : sizeof(comment) % UInt,
        filename === nothing ? UInt(0) : sizeof(filename) % UInt,
        extra === nothing ? UInt16(0) : sizeof(extra) % UInt16,
        header_crc
    )
    # We add 8 extra bytes to make sure Libdeflate don't error due to off-by-one errors 
    resize!(output, maxlen + 8)

    mem_comment = comment === nothing ? nothing : SizedMemory(comment)
    mem_filename = filename === nothing ? nothing : SizedMemory(filename)
    mem_extra = extra === nothing ? nothing : SizedMemory(extra)

    n_bytes = unsafe_gzip_compress!(
        compressor,
        pointer(output),
        sizeof(output) % UInt,
        pointer(input),
        sizeof(input) % UInt,
        mem_comment,
        mem_filename,
        mem_extra,
        header_crc
    )

    resize!(output, n_bytes % UInt)
    return output
end

"""
    unsafe_gzip_compress!(
        compressor::Compressor,
        out_ptr::Ptr{UInt8}, out_len::UInt,
        in_ptr::Ptr{UInt8}, in_len::UInt,
        comment::Union{ScanByte.SizedMemory, Nothing},
        filename::Union{ScanByte.SizedMemory, Nothing},
        extra::Union{ScanByte.SizedMemory, Nothing},
        header_crc::Bool
    )::Int

Use the `Compressor` to gzip compress input `in_len` bytes from `in_ptr`, into `out_ptr`.
If the resulting gzip data could be longer than `out_len`, throw an error.
Optionally, include gzip comment, filename or extra data. These should be represented
by a `SizedMemory` object, or `nothing` if it should be skipped.
* `comment` and `filename` must not include the byte `0x00`.
* `extra` must be at most `typemax(UInt16)` bytes long.
If `header_crc` is true, add the header CRC checksum.

Returns the number of bytes written to `out_ptr`.

See also: [`gzip_compress!`](@ref)
"""
function unsafe_gzip_compress!(
    compressor::Compressor,
    out_ptr::Ptr{UInt8},
    out_len::UInt,
    in_ptr::Ptr{UInt8},
    in_len::UInt,
    comment::Union{SizedMemory, Nothing},
    filename::Union{SizedMemory, Nothing},
    extra::Union{SizedMemory, Nothing},
    header_crc::Bool,
)    
    # Check output len is long enough
    max_out_len(
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
        header_crc
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
        # Validate extra data
        is_valid_extra_data(pointer(extra), length(extra) % UInt16) || gzip_error(8)
        header |= 0x04000000
    end
    header = ifelse(header_crc, header | 0x02000000, header)
    ptr = out_ptr - 1
    unsafe_store!(Ptr{UInt32}(ptr + 1), htol(header))

    # Add system time (take lower 32 bits if it overflows)
    unsafe_store!(Ptr{UInt32}(ptr + 5), htol(unsafe_trunc(UInt32, time())))

    # Add system (unknown) and XFL (zero)
    unsafe_store!(Ptr{UInt16}(ptr + 9), htol(0x00ff))

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
    if header_crc
        header_crc = unsafe_crc32(ptr + one(UInt), index - one(UInt)) % UInt16
        unsafe_store!(Ptr{UInt16}(ptr + index), htol(header_crc))
        index += UInt(2)
    end

    # Add in compressed data
    remaining_outdata = out_len - index + 1 - 8 # tail
    n_compressed = unsafe_compress!(compressor, ptr + index, remaining_outdata, in_ptr, in_len)
    index += n_compressed

    # Add in crc32 of uncompressed data
    crc = unsafe_crc32(in_ptr, in_len)
    unsafe_store!(Ptr{UInt32}(ptr + index), htol(crc))
    index += 4

    # Add in isize (uncompressed size)
    unsafe_store!(Ptr{UInt32}(ptr + index), htol(in_len % UInt32))
    return (index + 3) % Int # 4 bytes isize - off-by-one
end
