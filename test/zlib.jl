zlib_test_data = [
    UInt8[
        0x78, 0x5e,
        0x01, 0x03, 0x00, 0xfc, 0xff, 0x66, 0x6f, 0x6f,
        0x02, 0x82, 0x01, 0x45
    ]
]

@testset "Decompression" begin
    indata = zlib_test_data[1]
    decompressor = Decompressor()
    output = zeros(UInt8, 128)

    @test zlib_decompress!(decompressor, output, indata) == 3
    @test String(output[1:3]) == "foo"
    @test zlib_decompress!(decompressor, output, indata, 3) == 3
    @test String(output[1:3]) == "foo"
    
    @test zlib_decompress!(decompressor, output, indata, 2) == LibDeflateErrors.deflate_insufficient_space
    @test zlib_decompress!(decompressor, output, indata, 4) == LibDeflateErrors.deflate_output_too_short

    @test zlib_decompress!(decompressor, output[1:2], indata, 3) == LibDeflateErrors.deflate_insufficient_space
    @test zlib_decompress!(decompressor, output[1:2], indata) == LibDeflateErrors.deflate_insufficient_space

    cp = copy(indata)

    cp[1] = 0x79
    @test zlib_decompress!(decompressor, output, cp) == LibDeflateErrors.zlib_not_deflate

    cp[1] = 0x98
    @test zlib_decompress!(decompressor, output, cp) == LibDeflateErrors.zlib_wrong_window_size
    cp[1] = 0x78

    cp[2] = 0xff
    @test zlib_decompress!(decompressor, output, cp) == LibDeflateErrors.zlib_needs_compression_dict

    cp[2] = 0x5c
    @test zlib_decompress!(decompressor, output, cp) == LibDeflateErrors.zlib_bad_header_check

    cp[2] = 0x01
    @test zlib_decompress!(decompressor, output, indata, 3) == 3
    cp[2] = 0xda
    @test zlib_decompress!(decompressor, output, indata, 3) == 3
    cp[2] = 0x9c
    @test zlib_decompress!(decompressor, output, indata, 3) == 3

    cp[end] = 0x46
    @test zlib_decompress!(decompressor, output, cp) == LibDeflateErrors.zlib_bad_adler32
end

@testset "Compression" begin
    output = zeros(UInt8, 128)
    compressor = Compressor()

    @test zlib_compress!(compressor, output, "foo") == length(first(zlib_test_data))
    @test output[1:length(first(zlib_test_data))] == first(zlib_test_data)

    @test zlib_compress!(compressor, zeros(Float64, 4), "foo") == length(first(zlib_test_data))
    @test zlib_compress!(compressor, zeros(Int8, 0), "foo") == LibDeflateErrors.zlib_insufficient_space
    @test zlib_compress!(compressor, zeros(Float64, 1), "foo") == LibDeflateErrors.deflate_insufficient_space
end