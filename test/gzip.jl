data_test_cases = [
    [0x42, 0x43, 0x02, 0x00, 0xa1, 0x4c],
    [0x02, 0x03, 0x00, 0x00],
    [0x00, 0x01, 0x04, 0x00, 0x01, 0x02, 0x03, 0x04,
    0xff, 0xf1, 0x01, 0x00, 0xff],
]

@testset "Is valid data" begin
    test_valid(v) = is_valid_extra_data(pointer(v), UInt16(length(v)))
    for data in data_test_cases
        @test test_valid(data)
        data[2] = 0x00
        @test !test_valid(data)
        data[2] = 0xff
        push!(data, 0x00)
        @test !test_valid(data)
        pop!(data)
        @test !test_valid(data[1:end-1])
        data = empty!(copy(data))
        @test test_valid(data)
    end
end

@testset "Parse fields" begin
    test_parse(v) = LibDeflate.parse_fields(pointer(v), UInt32(1), UInt16(length(v)))
    for data in data_test_cases
        # We merely test it doesn't fail
        @test test_parse(data) !== nothing 
        data[2] = 0x00
        @test_throws LibDeflateError test_parse(data)
        data[2] = 0xa0
        push!(data, 0x00)
        @test_throws LibDeflateError test_parse(data)
        pop!(data)
        @test_throws LibDeflateError test_parse(data[1:end-1])
        data = empty!(copy(data))
        @test test_parse(data) !== nothing 
    end
end

test_data = [
    "",
    "Abracadabra!",
    "En af dem der red med fane",
    rand(UInt8, 1000)
]

test_comment = "This is a comment"
test_filename = "testfile.foo"

@testset "Compression" begin
    outdata = zeros(UInt8, 1250)
    compressor = Compressor()
    for data in test_data
        n_bytes = unsafe_gzip_compress!(
            compressor, pointer(outdata), UInt(length(outdata)),
            pointer(data), UInt(sizeof(data)),
            ScanByte.SizedMemory(test_comment), ScanByte.SizedMemory(test_filename),
            nothing, true
        )
        decompressed = transcode(GzipDecompressor, outdata[1:n_bytes])
        @test decompressed == Vector{UInt8}(data)

        gzip_compress!(
            compressor, outdata, data;
            comment=test_comment, filename=test_filename, extra=nothing, header_crc=false
        )
        decompressed = transcode(GzipDecompressor, outdata)
        @test decompressed == Vector{UInt8}(data)

        # Resize for next iteration
        resize!(outdata, 1250)
    end
end

@testset "Decompression" begin
    decompressor = Decompressor()
    outdata = zeros(UInt8, 5) # begin with small buffer, let it resize
    for data in test_data
        compressed = transcode(GzipCompressor, data)

        result = unsafe_gzip_decompress!(
            decompressor, outdata, UInt(1001),
            pointer(compressed), UInt(length(compressed)),
        )
        @test outdata[1:result.len] == Vector{UInt8}(data)

        empty!(outdata)
        result = gzip_decompress!(decompressor, outdata, compressed)
        @test outdata[1:result.len] == Vector{UInt8}(data)

        resize!(outdata, 5)

    end
end