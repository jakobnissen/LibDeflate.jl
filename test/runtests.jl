using LibDeflate
using Test
using CodecZlib
using ScanByte

@testset "DEFLATE" begin
    include("deflate.jl")
end

@testset "gzip" begin
    include("gzip.jl")
end