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
            LibDeflate.SizedMemory(test_comment), LibDeflate.SizedMemory(test_filename),
            nothing, true
        )
        decompressed = transcode(GzipDecompressor, outdata[1:n_bytes])
        @test decompressed == Vector{UInt8}(data)

        gzip_compress!(
            compressor, outdata, data;
            comment=test_comment, filename=test_filename, extra=data_test_cases[1], header_crc=false
        )
        decompressed = transcode(GzipDecompressor, outdata)
        @test decompressed == Vector{UInt8}(data)

        # Resize for next iteration
        resize!(outdata, 1250)
    end
end


complex_test_case = UInt8[
    # header
    0x1f, 0x8b, 0x08, 0x1e, 0xb3, 0x2c, 0x51, 0x60, 0xff, 0x00,

    # Extra data
    0x0a, 0x00, 0x42, 0x43, 0x02, 0x00, 0xa1, 0x4c,
    0x02, 0x03, 0x00, 0x00,

    # Filename: "filename.fna"
    0x66, 0x69, 0x6c, 0x65, 0x6e, 0x61, 0x6d, 0x65, 0x2e, 0x66, 0x6e, 0x61, 0x00,

    # Complicated unicode comment "αβ学中文"
    0xce, 0xb1, 0xce, 0xb2, 0xe5, 0xad, 0xa6, 0xe4, 0xb8, 0xad, 0xe6, 0x96, 0x87, 0x00,

    # CRC16
    0x78, 0x18,
    
    # Data: compressed "Abracadabra"
    0x01, 0x0b, 0x00, 0xf4, 0xff, 0x41, 0x62, 0x72, 0x61, 0x63, 0x61, 0x64, 0x61, 0x62, 0x72, 0x61,
    
    # CRC32
    0x60, 0x76, 0x76, 0x91,
    
    # isize
    0x0b, 0x00, 0x00, 0x00
]

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

    # Hard test case
    res = gzip_decompress!(decompressor, outdata, complex_test_case)
    @test res.len == 11
    @test res.mtime == 0x60512cb3
    @test length(res.extra) == 2
    @test first(res.extra).tag == (0x42, 0x43)
    @test first(res.extra).data == 0x00000011:0x00000012
    @test last(res.extra).tag == (0x02, 0x03)
    @test last(res.extra).data === nothing # empty field
    @test String(complex_test_case[res.filename]) == "filename.fna"
    @test String(complex_test_case[res.comment]) == "αβ学中文"
    @test String(copy(outdata)) == "Abracadabra"

end