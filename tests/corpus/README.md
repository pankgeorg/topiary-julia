# Test Corpus

External test data used by the topiary-julia test suite.

## tree-sitter-julia corpus (`*.txt`)

Source: https://github.com/tree-sitter/tree-sitter-julia/tree/v0.25.0/test/corpus

Files: `collections.txt`, `definitions.txt`, `expressions.txt`, `literals.txt`,
`operators.txt`, `statements.txt`

Version: **v0.25.0** (tag `e0f9dcd1`, 2025-11-08)

Used by: `roundtrip_test.rs` — verifies formatting doesn't introduce parse errors.

## JuliaSyntax.jl corpus (`juliasyntax_parser.jl`)

Source: https://github.com/JuliaLang/JuliaSyntax.jl/blob/main/test/parser.jl

Version: fetched from **main** branch (JuliaSyntax.jl v1.0.2, 2025-03-28)

Contains ~828 Julia code snippets covering the full grammar.

Used by: `ast_equivalence_test.rs` — verifies formatting preserves the tree-sitter
AST structure (strongest correctness guarantee).

## Updating

```bash
# tree-sitter-julia corpus (match the tag in Cargo.toml)
for f in collections definitions expressions literals operators statements; do
  curl -sL "https://raw.githubusercontent.com/tree-sitter/tree-sitter-julia/v0.25.0/test/corpus/${f}.txt" \
    -o "tests/corpus/${f}.txt"
done

# JuliaSyntax.jl corpus
curl -sL "https://raw.githubusercontent.com/JuliaLang/JuliaSyntax.jl/main/test/parser.jl" \
  -o "tests/corpus/juliasyntax_parser.jl"
```
