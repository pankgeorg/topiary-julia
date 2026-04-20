# Spaced-colon ranges inside a for binding. tree-sitter-julia's scanner
# cannot emit SPACED_RANGE_COLON inside the post-`_expression` state of a
# for_binding, so it falls back to a literal `:` and the RHS becomes a
# quote_expression instead of a range. See the reverts of 9059434 / 5bc7cdc
# for the full diagnosis. JuliaSyntax parses all of these correctly.

for i in 1 : n
    body()
end

for i in a : b : c
    body()
end

for i in 1 : 2 : 3 : 4
    body()
end

for i = 1 : n
    body()
end

for i ∈ 1 : n
    body()
end

for i in f(x) : g(y)
    body()
end
