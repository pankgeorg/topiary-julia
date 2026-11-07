# Build jlparse/parser.wasm from jlparse/parser.jl with WasmCodegen.jl (optimized: wasm-opt -O3,
# WasmCodegen's default). Run it in the environment of WasmCodegen.jl's examples/juliasyntax:
#
#   julia +1.13 --project=path/to/WasmCodegen.jl/examples/juliasyntax jlparse/build.jl
#
# Adapted from that example's build.jl.
using WasmCodegen
include("parser.jl")

t = @elapsed c = WasmCodegen.with_trim_patches() do _, _
    WasmCodegen.compile([WasmCodegen.Entry(f, at) for (f, at) in ENTRIES])
end
write(joinpath(@__DIR__, "parser.wasm"), c.bytes)
println("parser.wasm: $(length(c.bytes)) bytes, $(length(c.cgm.funcs)) functions, exceptions $(c.cgm.exceptions), ",
        "$(length(c.cgm.image.globals)) serialized objects, compiled in $(round(t, digits=1)) s, ",
        "Julia $(VERSION), WasmCodegen $(pkgversion(WasmCodegen))")
