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

- **`julia.scm`** — All formatting rules (~470 lines)
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
- String/command literals preserved as `@leaf`
- Comments preserved
- Blank line preservation between definitions
- Semicolons as statement separators normalized to newlines
- Multi-binding `for`/`let` comma placement
- Qualified macro spacing (`A.@foo a b`)

## Test results

```
format_test:          68/68 pass   — hand-crafted input→output tests
roundtrip_test:       59/59 pass   — tree-sitter corpus, no new ERROR nodes
ast_equivalence_test: 681/682 pass — JuliaSyntax.jl corpus, 99.9% AST preservation
```

### AST equivalence breakdown (828 snippets)

| Category | Count |
|----------|-------|
| Intentional errors (skipped) | 88 |
| Grammar gaps (tree-sitter can't parse) | 58 |
| Testable | 682 |
| — Passed | 681 |
| — Format errors | 0 |
| — AST mismatches | 1 (`[1 :a]` juxtaposition vs hcat) |

## Known limitations

### Formatter
- `(_) . (_) @prepend_hardline` unreliable in tree-sitter-julia (only matches first pair of consecutive siblings)
- `[1 :a]` — tree-sitter parses as juxtaposition, reformatting changes to vector_expression

### Tree-sitter-julia grammar (58 gaps)
- **`$` as operator** (7) — `$$a`, `function $f end` — upstream #161
- **Operator subscript suffixes** (3) — `+₁`, `-->₁` — needs scanner work
- **Multi-paren juxtaposition** (3) — `(2)(3)x`, `(x-1)y` — upstream #92
- **`var"..."` identifiers** (2) — needs scanner — upstream #92
- **Partial-parse tests** (~16) — JuliaSyntax production-specific, not toplevel
- **Array newlines before commas** (3) — `[x\n, y]` — newline lexed as terminator
- Other one-offs (~24)

## TODO

- [ ] **Array newlines before commas/semicolons** — `[x\n, y]`, `[x \n, ]`, `[a \n ;]` fail because `\n` is lexed as `_terminator` even inside brackets. Fix requires either moving newline handling to the external scanner or redesigning `_terminator` to be context-aware. (3 snippets)
- [ ] **Operator subscript suffixes** — `+₁`, `-->₁`, `×ᵀ`. Julia supports 121 suffix characters on operators. Needs `token(seq(op, optional(suffix_pattern)))` wrapping in grammar.js or scanner support. (3 snippets)
- [ ] **`$` as operator** — `$$a`, `$a->b`, `function $f end`. `$` is currently syntactic (interpolation-only). Upstream issue #161. (7 snippets)
- [ ] **`var"..."` non-standard identifiers** — `var"."`, `@var"'"`. Needs `immediate_identifier` concept in scanner. Upstream issue #92. (2 snippets)
- [ ] **Upstream contributions** — Open PRs on `tree-sitter/tree-sitter-julia` for the fixes in our fork
- [ ] **Topiary upgrade** — Track topiary-core updates for better anonymous token handling

## Dependencies

- `topiary-core` 0.7.3
- `topiary-tree-sitter-facade` 0.7.3
- `tree-sitter-julia` from [`pankgeorg/tree-sitter-julia`](https://github.com/pankgeorg/tree-sitter-julia/tree/topiary-julia) branch `topiary-julia`
- JuliaSyntax.jl v1.0 (test corpus only, in `Project.toml`)

## Related

- [Topiary](https://github.com/tweag/topiary) — the formatting engine
- [tree-sitter-julia](https://github.com/tree-sitter/tree-sitter-julia) — upstream grammar
- [pankgeorg/tree-sitter-julia](https://github.com/pankgeorg/tree-sitter-julia/pull/1) — our grammar fork with fixes
