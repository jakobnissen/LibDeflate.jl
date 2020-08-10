push!(LOAD_PATH, "../..")

using LibDeflate
using Test

@testset "Compressor/Decompressor" begin
    address(x) = UInt(Base.unsafe_convert(Ptr{Nothing}, x))

    for T in [Decompressor, Compressor]
        a = T()
        b = T()
        c = T()

        @test pointer_from_objref(a) != pointer_from_objref(c)
        @test pointer_from_objref(a) != pointer_from_objref(b)
        @test pointer_from_objref(b) != pointer_from_objref(c)
        @test address(a) != address(c)
        @test address(a) != address(b)
        @test address(b) != address(c)
    end

    c = Compressor()
    @test c.level == Compressor(6).level
end

@testset "Round trip" begin
    INPUT_DATA = [
        "",
        "Abracadabra!",
        "A man, a plan, a canal, Panama!",
        "No, no, no, no, no, no, no, no, no, no, no!",
        "sXXbYltTe]EDP`kRNUoEPVRnkq]gS^cquEv^BVTwAhtjFGGQBC",
        rand(UInt8, 2048),
    ]
    outbuffer = Vector{UInt8}(undef, 4096)
    backbuffer = copy(outbuffer)
    
    compressor = Compressor()
    decompressor = Decompressor()

    for i in INPUT_DATA
        v = Vector{UInt8}(i)
        c_bytes = compress!(compressor, outbuffer, v)
        d_bytes = decompress!(decompressor, backbuffer, outbuffer[1:c_bytes])
        @test backbuffer[1:d_bytes] == v

        d_bytes = decompress!(decompressor, backbuffer, outbuffer[1:c_bytes], length(v))
        @test backbuffer[1:d_bytes] == v
    end
end
