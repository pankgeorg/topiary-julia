#!/usr/bin/env julia
# test_translator.jl — sanity tests for the Translator module.
#
# For each snippet, parse it with both tree-sitter-julia (via the CLI) and
# JuliaSyntax.jl. Translate the ts output and compare to the JuliaSyntax output.
#
# Run with: julia --project=. test_translator.jl
# Requires: cargo build --release (for the topiary-julia binary).

include("translator.jl")
using .Translator
using JuliaSyntax

const BIN = normpath(joinpath(@__DIR__, "..", "target", "release", "topiary-julia"))

function ts_sexp(code::String)::String
    # Shell out to `topiary-julia parse`.
    out = IOBuffer()
    inp = IOBuffer(code)
    run(pipeline(`$BIN parse`, stdin=inp, stdout=out, stderr=devnull), wait=true)
    return strip(String(take!(out)))
end

function js_sexp(code::String)::String
    tree = parseall(SyntaxNode, code)
    buf = IOBuffer()
    show(buf, MIME"text/x.sexpression"(), tree)
    return String(take!(buf))
end

const SNIPPETS = [
    "x = 1",
    "a + b",
    "f(a, b)",
    "1:3",
    "a.b",
    "x::Int",
    "x where T",
    "function f(a,b) a+b end",
    "if c; x else y end",
    "for i in xs; end",
    "while c; end",
    "try; catch e; end",
    "module M; x end",
    "struct S end",
    "abstract type A end",
    "primitive type P 8 end",
    "import A",
    "using A",
    "[1,2,3]",
    "{a, b}",
    "(1,2)",
    "a ? b : c",
    "@foo x",
    "x -> x+1",
    "x...",
    ":sym",
    "const x = 1",
    "return x",
    "begin x end",
    "[1 2; 3 4]",
    "a[1,2]",
    "a'",
    "2x",
    "a || b",
    "x .+ y",
    "f.(x)",
]

function run_tests()
    passed = 0
    failed = String[]
    for s in SNIPPETS
        ts = ts_sexp(s)
        js = js_sexp(s)
        ts_tree = Translator.parse_sexp(ts)
        translated = Translator.translate(ts_tree)
        actual = Translator.sexp_string(translated)
        if actual == js
            passed += 1
            println("✓  ", repr(s))
        else
            push!(failed, "$(repr(s))\n  expected: $js\n  got:      $actual\n  from ts:  $ts")
            println("✗  ", repr(s))
        end
    end
    println()
    println("$passed / $(length(SNIPPETS)) passed.")
    if !isempty(failed)
        println("\nFailures:")
        for f in failed
            println("  ", replace(f, "\n" => "\n  "))
        end
        exit(1)
    end
end

run_tests()
