#!/usr/bin/env julia
# debug_one.jl — show the translator output vs the expected JuliaSyntax sexp
# for a single file or snippet. Usage:
#   julia --project=. debug_one.jl <path-or-snippet>
#   julia --project=. debug_one.jl --code 'x = 1'

using JuliaSyntax
include("translator.jl")
using .Translator

const BIN = normpath(joinpath(@__DIR__, "..", "target", "release", "topiary-julia"))

function ts_sexp(code)
    out = IOBuffer()
    run(pipeline(`$BIN parse`, stdin=IOBuffer(code), stdout=out, stderr=devnull),
        wait=true)
    strip(String(take!(out)))
end

function js_sexp(code)
    tree = parseall(SyntaxNode, code)
    buf = IOBuffer()
    show(buf, MIME"text/x.sexpression"(), tree)
    String(take!(buf))
end

function main()
    length(ARGS) >= 1 || error("usage: debug_one.jl <path> | --code '<code>'")
    code = ARGS[1] == "--code" ? ARGS[2] : read(ARGS[1], String)
    ts = ts_sexp(code)
    js = js_sexp(code)
    translated = Translator.translate(Translator.parse_sexp(ts))
    actual = Translator.sexp_string(translated)

    # First diff position
    n = min(length(actual), length(js))
    i = 1
    while i <= n && actual[i] == js[i]
        i = nextind(actual, i)
    end

    println("=== TS sexp ===")
    println(ts)
    println()
    println("=== Expected (JS) ===")
    println(js)
    println()
    println("=== Actual (translator) ===")
    println(actual)
    println()
    println("=== First diff at char $i ===")
    ctx = 80
    s = max(1, i - ctx)
    ae = min(length(actual), i + ctx)
    be = min(length(js), i + ctx)
    println("actual: …$(SubString(actual, s, ae))…")
    println("expect: …$(SubString(js, s, be))…")
    println()
    println("match? ", actual == js)
end

main()
