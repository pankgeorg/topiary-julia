# Constructs that produce ERROR / MISSING nodes under tree-sitter-julia.
# Sources: JuliaSyntax.jl test corpus. Each of these is a real parse
# failure (not a semantic misparse), so the v1 minimizer should localize
# each one to its minimal sub-expression.

function f(public)
    public + 3
end

let x = outer i = rhs
    body
end

arr = [a
  ;]

arr = [x=1, ; y=2]

# @$ macro interpolation lookup
macrocall = @$ y
