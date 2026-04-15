# topiary-julia

A Julia code formatter powered by [Topiary](https://github.com/tweag/topiary) — tree-sitter query-based formatting in Rust.

## Usage

```bash
# Format stdin
echo 'function f(x,y) x+y end' | cargo run

# Format a file in place
cargo run -- -f myfile.jl

# Check without modifying (exit 1 if changes needed)
cargo run -- --check -f myfile.jl
```

## How it works

Topiary formats code by matching tree-sitter parse trees against query patterns (`.scm` files). The queries annotate nodes with formatting directives like `@append_space`, `@append_hardline`, `@append_indent_start`, `@leaf`, etc.

- **`julia.scm`** — All formatting rules (~480 lines)
- **`src/main.rs`** — CLI wrapper
- **Grammar** — [`pankgeorg/tree-sitter-julia`](https://github.com/pankgeorg/tree-sitter-julia/tree/topiary-julia) branch `topiary-julia` (v0.25.0 + fixes)

## What it formats

- Block indentation: `function`, `if`/`elseif`/`else`, `for`, `while`, `try`/`catch`/`finally`, `struct`, `module`, `begin`, `let`, `quote`, `do`, `macro`
- Operator spacing: `=`, `+`, `->`, `?:`, `where`, `::`, all binary/unary operators
- Keyword spacing: all Julia keywords
- Argument lists with softline wrapping
- Named/keyword arguments with semicolon separator
- Import/using/export with comma spacing, `as` support, relative dots
- Macro calls: space-separated args, paren/bracket forms preserved
- Comprehensions with `for`/`if` clauses
- Matrix expressions preserved as `@leaf` (spaces and semicolons are semantic)
- Bracescat expressions preserved as `@leaf`
- String/command/`var"..."` literals preserved as `@leaf`
- Comments preserved
- Blank line preservation between definitions
- Semicolons as statement separators normalized to newlines
- Multi-binding `for`/`let` comma placement
- Qualified macro spacing (`A.@foo a b`)

## Test results

```
format_test:          68/68 pass   — hand-crafted input→output tests
roundtrip_test:       59/59 pass   — tree-sitter corpus, no new ERROR nodes
ast_equivalence_test: 688/689 pass — JuliaSyntax.jl corpus, 99.9% AST preservation
```

### AST equivalence breakdown (828 snippets)

| Category | Count |
|----------|-------|
| Intentional errors (skipped) | 88 |
| Grammar gaps (tree-sitter can't parse) | 52 |
| Testable | 689 |
| — Passed | 688 |
| — Format errors | 0 |
| — AST mismatches | 1 (`[1 :a]` juxtaposition vs hcat) |

### Grammar gaps (52) by category

| Category | Count | Status |
|----------|-------|--------|
| Partial-parse (by design) | 16 | Won't fix — JuliaSyntax production-specific tests |
| `$` as operator | 6 | Hard — upstream #161 |
| Multi-paren juxtaposition | 3 | Hard — upstream #92 |
| Lexer `.operator` conflicts | 3 | Hard — lexer architecture |
| Array newlines before comma | 3 | Hard — `_terminator` design |
| `begin`/`end` as indexing values | 2 | Hard — needs deeper parser changes |
| Other one-offs | 19 | Varies |

## TODO

- [x] **Operator subscript suffixes** — `+₁`, `-->₁`, `×ᵀ`. Fixed via OPERATOR_SUFFIX regex.
- [x] **Semicolons in vectors** — `[x,y ; z]`, `[x=1, ; y=2]`. Fixed for JuMP filter patterns.
- [ ] **Array newlines before commas** — `[x\n, y]` fails because `\n` is lexed as `_terminator`. Needs external scanner or `_terminator` redesign. (3 snippets)
- [ ] **`$` as operator** — `$$a`, `function $f end`. Upstream #161. (6 snippets)
- [ ] **`begin`/`end` as indexing values** — `a[begin]`, `a[end-1]`. Needs deeper parser changes. (2 snippets)
- [ ] **Upstream contributions** — Open PRs on `tree-sitter/tree-sitter-julia` for the fixes in our fork
- [ ] **Topiary upgrade** — Track topiary-core updates

## Dependencies

- `topiary-core` 0.7.3
- `topiary-tree-sitter-facade` 0.7.3
- `tree-sitter-julia` from [`pankgeorg/tree-sitter-julia`](https://github.com/pankgeorg/tree-sitter-julia/tree/topiary-julia) branch `topiary-julia`
- JuliaSyntax.jl v1.0 (test corpus only, in `Project.toml`)

## Related

- [Topiary](https://github.com/tweag/topiary) — the formatting engine
- [tree-sitter-julia](https://github.com/tree-sitter/tree-sitter-julia) — upstream grammar
- [pankgeorg/tree-sitter-julia](https://github.com/pankgeorg/tree-sitter-julia/pull/1) — our grammar fork with fixes
