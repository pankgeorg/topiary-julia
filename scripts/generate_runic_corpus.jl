#!/usr/bin/env julia
# Generate a comparison corpus: input snippets formatted by Runic.jl
# Output: tests/corpus/runic_comparison.txt
# Format: pairs of (input, runic_output) separated by markers

using Runic

# Collect test cases as (category, input, runic_output)
results = Tuple{String, String, String}[]

function add_test(category::String, input::String)
    try
        output = Runic.format_string(input)
        push!(results, (category, input, output))
    catch e
        @warn "Runic failed on: $(repr(input))" exception=e
    end
end

# ──── Operator spacing ────────────────────────────────────────────

for op in ("+", "-", "==", "!=", "===", "!==", "<", "<=", ">=", ">",
           "&&", "||", ".+", ".==", ".<", ".<=")
    add_test("operator_spacing", "a$(op)b")
    add_test("operator_spacing", "a $(op)b")
    add_test("operator_spacing", "a$(op) b")
    add_test("operator_spacing", "a  $(op)  b")
end

# Exceptions: no space around : and ^
add_test("operator_spacing", "a : b")
add_test("operator_spacing", "a:b")
add_test("operator_spacing", "a : b : c")
add_test("operator_spacing", "a:b:c")
add_test("operator_spacing", "a ^ b")
add_test("operator_spacing", "a^b")

# Assignment operators
for op in ("=", "+=", "-=", "*=", "/=", ".=", ".+=")
    add_test("assignment_spacing", "a$(op)b")
    add_test("assignment_spacing", "a $(op) b")
    add_test("assignment_spacing", "a$(op)  b")
end

# ──── Type annotations ────────────────────────────────────────────

add_test("type_annotations", "a::T")
add_test("type_annotations", "a :: T")
add_test("type_annotations", "a  ::  T")
add_test("type_annotations", "f(::T)::T = 1")
add_test("type_annotations", "f(:: T) :: T = 1")
add_test("type_annotations", "a<:T")
add_test("type_annotations", "a <: T")
add_test("type_annotations", "a>:T")
add_test("type_annotations", "a >: T")
add_test("type_annotations", "V{<:T}")
add_test("type_annotations", "V{<: T}")
add_test("type_annotations", "V{>:T}")
add_test("type_annotations", "V{>: T}")

# ──── Arrow functions ─────────────────────────────────────────────

add_test("arrow", "a->b")
add_test("arrow", "a -> b")
add_test("arrow", "x -> x^2")
add_test("arrow", "(x, y) -> x + y")

# ──── Ternary ─────────────────────────────────────────────────────

add_test("ternary", "a ? b : c")
add_test("ternary", "a  ?  b  :  c")
add_test("ternary", "a ?\nb :\nc")
add_test("ternary", "a ? b : c ? d : e")

# ──── Function definitions ────────────────────────────────────────

add_test("function_def", "function f()\n    x\nend")
add_test("function_def", "function f()\nx\nend")
add_test("function_def", "function f(x, y)\n    x + y\nend")
add_test("function_def", "function f(x; y=1)\n    x + y\nend")
add_test("function_def", "f(x) = x + 1")
add_test("function_def", "f(x)=x+1")
add_test("function_def", "function f end")
add_test("function_def", "function f()\n    x\n    y\nend")
add_test("function_def", "function f() x end")
add_test("function_def", "function f()\n    x\n    y\n    z\nend")

# ──── If/elseif/else ──────────────────────────────────────────────

add_test("if_else", "if a\n    x\nend")
add_test("if_else", "if a\nx\nend")
add_test("if_else", "if a\n    x\nelse\n    y\nend")
add_test("if_else", "if a\n    x\nelseif b\n    y\nend")
add_test("if_else", "if a\n    x\nelseif b\n    y\nelse\n    z\nend")
add_test("if_else", "if a x end")
add_test("if_else", "if a; x; end")
add_test("if_else", "if a; x; else; y; end")

# ──── For/while loops ─────────────────────────────────────────────

add_test("loops", "for i in I\n    x\nend")
add_test("loops", "for i in I\nx\nend")
add_test("loops", "for i=1:10\nend")
add_test("loops", "for i = 1:10\n    x\nend")
add_test("loops", "for i in I, j in J\n    x\nend")
add_test("loops", "while x\n    y\nend")
add_test("loops", "while x\ny\nend")

# ──── Try/catch ───────────────────────────────────────────────────

add_test("try_catch", "try\n    x\ncatch\n    y\nend")
add_test("try_catch", "try\n    x\ncatch err\n    y\nend")
add_test("try_catch", "try\n    x\ncatch\n    y\nfinally\n    z\nend")
add_test("try_catch", "try\n    x\ncatch err\n    y\nfinally\n    z\nend")

# ──── Struct ──────────────────────────────────────────────────────

add_test("struct", "struct A\n    x\nend")
add_test("struct", "struct A\nx\nend")
add_test("struct", "mutable struct A\n    x\nend")
add_test("struct", "struct A end")
add_test("struct", "struct A\n    x::Int\n    y::Float64\nend")

# ──── Module ──────────────────────────────────────────────────────

add_test("module", "module A\nx\nend")
add_test("module", "module A\n    x\nend")
add_test("module", "baremodule A\n    x\nend")

# ──── Begin/let/quote/do ──────────────────────────────────────────

add_test("blocks", "begin\n    x\nend")
add_test("blocks", "begin\nx\nend")
add_test("blocks", "begin x end")
add_test("blocks", "let\n    x\nend")
add_test("blocks", "let a = 1\n    x\nend")
add_test("blocks", "quote\n    x\nend")
add_test("blocks", "open() do\n    a\nend")
add_test("blocks", "open() do io\n    a\nend")

# ──── Tuples ──────────────────────────────────────────────────────

add_test("tuples", "(a, b)")
add_test("tuples", "(a,b)")
add_test("tuples", "( a, b )")
add_test("tuples", "(a,)")
add_test("tuples", "(a, b, c)")
add_test("tuples", "a, b")
add_test("tuples", "a,b")

# ──── Function calls ──────────────────────────────────────────────

add_test("calls", "f(a, b)")
add_test("calls", "f(a,b)")
add_test("calls", "f( a, b )")
add_test("calls", "f(a; b=1)")
add_test("calls", "f(a; b = 1)")
add_test("calls", "f(a; b=1, c=2)")
add_test("calls", "f(\n    a,\n    b,\n)")
add_test("calls", "f(\n    a,\n    b\n)")
add_test("calls", "f(a,\nb)")

# ──── Arrays ──────────────────────────────────────────────────────

add_test("arrays", "[a, b]")
add_test("arrays", "[a,b]")
add_test("arrays", "[ a, b ]")
add_test("arrays", "[a, b, c]")
add_test("arrays", "[\n    a,\n    b,\n]")
add_test("arrays", "[a,\nb]")
add_test("arrays", "[a b; c d]")
add_test("arrays", "[a b\nc d]")

# ──── Curly braces ────────────────────────────────────────────────

add_test("curly", "A{T}")
add_test("curly", "A{T, S}")
add_test("curly", "A{T,S}")
add_test("curly", "A{ T, S }")

# ──── Comprehensions ──────────────────────────────────────────────

add_test("comprehension", "[x for x in X]")
add_test("comprehension", "[x for x in X if x > 0]")
add_test("comprehension", "[x for x in X, y in Y]")
add_test("comprehension", "(x for x in X)")

# ──── Import/using ────────────────────────────────────────────────

add_test("import", "using A")
add_test("import", "using A, B")
add_test("import", "using A: a, b")
add_test("import", "import A")
add_test("import", "import A: a, b")
add_test("import", "import A as a")
add_test("import", "using A:\n    a,\n    b")
add_test("import", "export a, b")
add_test("import", "public a, b")

# ──── Where ───────────────────────────────────────────────────────

add_test("where", "A where {T}")
add_test("where", "A where{T}")
add_test("where", "A where B")
add_test("where", "A where {T} where {S}")

# ──── Keyword spacing ─────────────────────────────────────────────

add_test("keyword_spacing", "struct  A end")
add_test("keyword_spacing", "mutable  struct  A end")
add_test("keyword_spacing", "abstract  type  A end")
add_test("keyword_spacing", "primitive  type  A 64 end")
add_test("keyword_spacing", "function  f() end")
add_test("keyword_spacing", "module  A\nend")
add_test("keyword_spacing", "return  1")
add_test("keyword_spacing", "return 1")

# ──── Semicolons ──────────────────────────────────────────────────

add_test("semicolons", "begin\n    a;\n    b;\nend")
add_test("semicolons", "function f()\n    x;\n    return y\nend")
add_test("semicolons", "a; b; c")

# ──── Continuation indent ─────────────────────────────────────────

add_test("continuation", "a +\nb")
add_test("continuation", "a +\n    b")
add_test("continuation", "a =\nb")
add_test("continuation", "a =\n    b")
add_test("continuation", "x = if a\n    b\nend")

# ──── For loop normalization ──────────────────────────────────────

add_test("for_in", "for i = 1:10\n    x\nend")
add_test("for_in", "for i in 1:10\n    x\nend")
add_test("for_in", "for i ∈ 1:10\n    x\nend")

# ──── Trailing whitespace ─────────────────────────────────────────

add_test("whitespace", "a = 1  ")
add_test("whitespace", "a = 1\t")

# ──── Comments ────────────────────────────────────────────────────

add_test("comments", "a # comment")
add_test("comments", "a  # comment")
add_test("comments", "a   # comment")
add_test("comments", "# just a comment")

# ──── Multiline structures ────────────────────────────────────────

add_test("multiline", "function f(\n    a,\n    b,\n)\n    a + b\nend")
add_test("multiline", "if a &&\n    b\n    x\nend")
add_test("multiline", "struct Foo{T} <: AbstractFoo\n    x::T\n    y::Int\nend")

# ──── Macros ──────────────────────────────────────────────────────

add_test("macros", "@inline f(x) = x")
add_test("macros", "@show x")
add_test("macros", "@assert x == 1")
add_test("macros", "@f(a, b)")
add_test("macros", "@f a b")

# ──── String literals ─────────────────────────────────────────────

add_test("strings", "\"hello\"")
add_test("strings", "\"hello \$world\"")
add_test("strings", "r\"pattern\"")

# ──── Dot calls ───────────────────────────────────────────────────

add_test("dot_calls", "f.(x)")
add_test("dot_calls", "f.(x, y)")
add_test("dot_calls", "x .+ y")
add_test("dot_calls", "x .== y")

# ──── Abstract/primitive type ─────────────────────────────────────

add_test("abstract_type", "abstract type A end")
add_test("abstract_type", "abstract type A <: B end")
add_test("abstract_type", "primitive type A 64 end")

# ──── Pairs/dicts ─────────────────────────────────────────────────

add_test("pairs", "a => b")
add_test("pairs", "Dict(a => b, c => d)")
add_test("pairs", "Dict(\n    a => b,\n    c => d,\n)")

# ──── Real-world patterns ─────────────────────────────────────────

add_test("real_world", """
function solve(prob::Problem, alg::Algorithm; kwargs...)
    setup = initialize(prob, alg)
    result = run_solver(setup; kwargs...)
    return result
end
""")

add_test("real_world", """
struct ModelConfig{T<:Real}
    learning_rate::T
    batch_size::Int
    epochs::Int
end
""")

add_test("real_world", """
function train(model, data; epochs=10, lr=0.01)
    for epoch in 1:epochs
        for batch in data
            loss = compute_loss(model, batch)
            update!(model, loss, lr)
        end
    end
    return model
end
""")

add_test("real_world", """
module MyPackage

using LinearAlgebra
using Statistics: mean, std

export solve, MyType

struct MyType{T}
    x::T
    y::T
end

function solve(mt::MyType)
    return mt.x + mt.y
end

end
""")

add_test("real_world", """
@testset "my tests" begin
    @test f(1) == 2
    @test f(2) == 4
    @test_throws ErrorException f(-1)
end
""")

# ──── Write output ────────────────────────────────────────────────

open(joinpath(@__DIR__, "..", "tests", "corpus", "runic_comparison.txt"), "w") do io
    for (category, input, output) in results
        println(io, "=====")
        println(io, "category: ", category)
        println(io, "---input---")
        print(io, input)
        if !endswith(input, "\n")
            println(io)
        end
        println(io, "---runic---")
        print(io, output)
        if !endswith(output, "\n")
            println(io)
        end
    end
    println(io, "=====")
end

println("Generated $(length(results)) test pairs")
println("Categories:")
cats = Dict{String, Int}()
for (c, _, _) in results
    cats[c] = get(cats, c, 0) + 1
end
for (c, n) in sort(collect(cats))
    println("  $c: $n")
end
