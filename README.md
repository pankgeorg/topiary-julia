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

## Julia's own parser as the referee (`jlparse`, default on)

Every formatting is checked by **JuliaSyntax** — the parser Julia 1.13 ships — compiled to
WebAssembly ([`jlparse/`](jlparse/README.md)) and run in-process by wasmtime; no Julia install
needed:

- an output that parses to a different tree than the input is never written;
- code tree-sitter-julia can't parse (grammar gaps such as `&x`, `1 := 2`, `[x\n, y]`) is
  left verbatim and the rest of the file is formatted (`note: f.jl:3:5: left `&` verbatim`);
- the same for any node whose formatting would change its meaning (e.g. `[x +y]`, `- 2`);
- syntax errors are reported with JuliaSyntax's messages: `f.jl:1:4: error: Expected `)` …`.

`--no-verify` gives plain Topiary; `topiary-julia jl-parse [--sem]` prints JuliaSyntax's tree.

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
ast_equivalence_test: 693/694 pass — JuliaSyntax.jl corpus, 99.9% AST preservation
jlparse_test:         904/904 pass — JuliaSyntax-in-Wasm: native node-for-node check,
                      verify unit tests, verified formatting of the JuliaSyntax corpus
                      (828 snippets: 661 clean, 18 protected, 149 not valid as a file)
                      and of the 69 known grammar gaps (40 formatted with the gap left
                      verbatim, 29 not valid as a file) — see jlparse/GAPS.md
```

On Julia 1.13's `base/*.jl` (164 files, 3.6 MB), verified formatting succeeds on 164/164
(plain Topiary 157/164) and catches 5 files where plain Topiary silently changes meaning
(spaced ranges `for i = 1 : n` misparsed by tree-sitter; `""" doc""" name` → `"""…"""name`).

### AST equivalence breakdown (828 snippets)

| Category | Count |
|----------|-------|
| Intentional errors (skipped) | 88 |
| Grammar gaps (tree-sitter can't parse) | 48 |
| Testable | 694 |
| — Passed | 693 |
| — Format errors | 0 |
| — AST mismatches | 1 (`[1 :a]` juxtaposition vs hcat) |

### Grammar gaps (48) by category

| Category | Count | Status |
|----------|-------|--------|
| Partial-parse (by design) | 16 | Won't fix — JuliaSyntax production-specific tests |
| `$` as operator | 6 | Hard — upstream #161 |
| Multi-paren juxtaposition | 3 | Hard — upstream #92 |
| Lexer `.operator` conflicts | 3 | Hard — lexer architecture |
| Array newlines before comma | 3 | Hard — `_terminator` design |
| `begin`/`end` as indexing values | 2 | **Fixed** (arithmetic cases via BEGIN_IDENTIFIER scanner) |
| Other one-offs | 15 | Varies |

## TODO

- [x] **Operator subscript suffixes** — `+₁`, `-->₁`, `×ᵀ`. Fixed via OPERATOR_SUFFIX regex.
- [x] **Semicolons in vectors** — `[x,y ; z]`, `[x=1, ; y=2]`. Fixed for JuMP filter patterns.
- [ ] **Array newlines before commas** — `[x\n, y]` fails because `\n` is lexed as `_terminator`. Needs external scanner or `_terminator` redesign. (3 snippets)
- [ ] **`$` as operator** — `$$a`, `function $f end`. Upstream #161. (6 snippets)
- [x] **`begin`/`end` as indexing values** — `a[begin+1:end]` via BEGIN_IDENTIFIER scanner. Remaining: `$sym -> begin` (arrow edge case).
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
