#!/usr/bin/env julia
# _ast_check.jl — shared AST-equivalence helpers.
#
# Produces an Expr tree from Julia source (via `Meta.parseall`), strips
# LineNumberNodes, flattens nested `:toplevel` / `:block` wrappers, and
# compares two trees structurally. Also wraps a subprocess call to
# `topiary-julia` for formatting.
#
# Consumers:
#   - scripts/julia_ast_check.jl    (Julia base/test coverage check)
#   - scripts/smoke_sample_gen.jl   (build the corpus sample baseline)
#   - scripts/smoke_test.jl         (run the corpus smoke test)

module AstCheck

export flatten_toplevel, strip_lines, safe_parseall,
       format_code, find_first_diff

"""
Flatten `:toplevel` wrappers when they appear as children of another
`:toplevel` or `:block`. JuliaSyntax wraps `a; b` at top level into
`:toplevel(a, b)` but `a\\nb` becomes two separate items. These are
semantically equivalent — the formatter may convert between them.
Flattening makes the comparison robust to that representational
difference.
"""
function flatten_toplevel(args)
    result = []
    for a in args
        if a isa Expr && a.head == :toplevel
            append!(result, a.args)
        else
            push!(result, a)
        end
    end
    return result
end

"""
Strip `LineNumberNode`s from an `Expr` tree so line changes don't cause
mismatches. Also flattens nested `:toplevel` in positions where it's
equivalent to separate statements.
"""
function strip_lines(ex)
    if ex isa Expr
        args = filter(a -> !(a isa LineNumberNode), ex.args)
        args = map(strip_lines, args)
        if ex.head == :toplevel || ex.head == :block
            args = flatten_toplevel(args)
        end
        return Expr(ex.head, args...)
    else
        return ex
    end
end

"""
Parse Julia source into a cleaned `Expr` (no line numbers). Returns
`nothing` on parse error.
"""
function safe_parseall(code::String)
    try
        expr = Meta.parseall(code; filename = "none")
        return strip_lines(expr)
    catch
        return nothing
    end
end

"""
Format `code` via the `topiary-julia` CLI binary at `formatter`.
Returns `(formatted::String, success::Bool)`. `--tolerate-parsing-errors`
matches how the formatter is invoked in practice.
"""
function format_code(code::String, formatter::String)
    try
        inp = IOBuffer(code)
        out = IOBuffer()
        err = IOBuffer()
        proc = run(
            pipeline(
                `$formatter --tolerate-parsing-errors --skip-idempotence`,
                stdin = inp, stdout = out, stderr = err,
            ),
            wait = true,
        )
        return (String(take!(out)), proc.exitcode == 0)
    catch
        return ("", false)
    end
end

"""
Find the first structural difference between two `Expr` trees. Returns
`nothing` when equivalent, otherwise a short string like
`toplevel.args[3].args[1]: head :(=) vs :(call)` pointing at the
divergence.
"""
function find_first_diff(a, b, path = "toplevel")
    if typeof(a) != typeof(b)
        return "$path: type $(typeof(a)) vs $(typeof(b))"
    end
    if a isa Expr && b isa Expr
        if a.head != b.head
            return "$path: head $(a.head) vs $(b.head)"
        end
        for i in 1:max(length(a.args), length(b.args))
            if i > length(a.args)
                return "$path.args[$i]: missing in original (extra: $(repr(b.args[i])))"
            elseif i > length(b.args)
                return "$path.args[$i]: missing in formatted (was: $(repr(a.args[i])))"
            else
                diff = find_first_diff(a.args[i], b.args[i], "$path.args[$i]")
                if diff !== nothing
                    return diff
                end
            end
        end
        return nothing
    end
    if a != b
        return "$path: $(repr(a)) vs $(repr(b))"
    end
    return nothing
end

end # module AstCheck
