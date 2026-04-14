# topiary-julia — Project Status

A Julia code formatter powered by [Topiary](https://github.com/tweag/topiary) (tree-sitter query-based formatting in Rust).

## Architecture

- **`julia.scm`** — Formatting rules (tree-sitter queries with Topiary captures)
- **`src/main.rs`** — CLI wrapper (stdin/file → format → stdout/file)
- **Grammar**: `pankgeorg/tree-sitter-julia` branch `topiary-julia` (based on v0.25.0 + fixes)

## Test Results

| Suite | Tests | Description |
|-------|-------|-------------|
| `format_test` | 68 pass | Explicit input→output tests in 9 modules |
| `roundtrip_test` | 59 snippets | tree-sitter corpus: no new ERROR nodes |
| `ast_equivalence_test` | 828 snippets | JuliaSyntax.jl corpus: AST preserved after formatting |

### AST Equivalence (JuliaSyntax.jl corpus)

```
Total snippets:    828
Skipped (parse):   170  (88 intentional errors + 82 tree-sitter gaps)
Format failures:     0
AST preserved:     628  (95.4% of testable)
AST changed:         5
Parse errors:       25  (7 unique edge cases)
```

### Format test modules

```
cargo test --test format_test functions::     # 12 tests
cargo test --test format_test control_flow::  #  9 tests
cargo test --test format_test types::         #  5 tests
cargo test --test format_test operators::     #  8 tests
cargo test --test format_test blocks::        #  7 tests
cargo test --test format_test imports::       #  6 tests
cargo test --test format_test macros::        #  3 tests
cargo test --test format_test collections::   #  8 tests
cargo test --test format_test idempotence::   # 10 tests
```

## What works

- Block indentation: function, if/elseif/else, for, while, try/catch/finally, struct, module, begin, let, quote, do, macro
- Operator spacing: `=`, `+`, `->`, `?:`, `where`, `::`, all binary operators
- Keyword spacing: all Julia keywords
- Argument lists with softline wrapping (no inner padding)
- Named/keyword arguments with semicolon separator
- Import/using/export with comma spacing, `as` support, relative dots preserved
- Macro calls: space-separated args, paren/bracket forms preserved (no space insertion)
- Comprehensions with `for`/`if` clauses
- Matrix expressions preserved as `@leaf` (spaces and semicolons are semantic)
- String/command literals preserved as `@leaf`
- Comments preserved
- Blank line preservation between definitions
- Abstract/primitive types (single-line)
- Where clauses
- Do blocks with arguments
- Broadcast syntax (`f.(x)`, `.+`)

## Known limitations

### Formatter (julia.scm)
- Multi-binding `for`/`let` comma placement (comma starts next line)
- Semicolons-as-statement-separators (`a;b;c`) get misplaced
- `(_) . (_) @prepend_hardline` is unreliable in tree-sitter-julia (only matches first pair)
- Qualified macro spacing (`A.@foo a b`) loses space before args

### Tree-sitter-julia grammar gaps (82 non-intentional parse failures)
- **Fixable (Tier 2)**: Semicolons in brackets `[;]`, `{a ;; b}` (#120); Advanced imports `import A.:+` (#74)
- **Blocked on scanner**: `var"..."` identifiers (#92); operator suffixes `+₁` 
- **Architectural**: `$` as operator (#161); `public` as contextual identifier; emoji identifiers

## Git history

### topiary-julia (this repo)
```
933be56 chore: point tree-sitter-julia at pankgeorg fork
aecdd64 Reorganize test infrastructure
b98e00f Fix semicolons and improve v0.25.0 block handling
131e918 Upgrade to tree-sitter-julia v0.25.0
cc5ebec Fix relative import dots and add macro call tests
2e0e549 Fix matrix expressions, prefix ops, and block type annotations
47a1111 Refine formatting rules and expand test coverage
0063189 Add AST equivalence test against JuliaSyntax.jl corpus
4a57e9a Initial implementation of topiary-julia
```

### pankgeorg/tree-sitter-julia (branch: topiary-julia)
```
61dbc05 docs: update plan checklist with completed items
c750671 chore: regenerate parser
7d9f0f6 feat(grammar): expand Unicode identifier start characters
b3a5fcf fix(grammar): allow trailing comma in tuple destructuring (#164)
18dccd1 feat(grammar): add public to KEYWORDS, add public_statement tests
4c56bb1 docs: add topiary-julia improvement plan
+ aviatesk PRs #182 (CLI 0.26.6) and #183 (typegroup syntax)
```

## Dependencies

- `topiary-core` 0.7.3
- `topiary-tree-sitter-facade` 0.7.3  
- `tree-sitter-julia` from `pankgeorg/tree-sitter-julia` branch `topiary-julia`
- JuliaSyntax.jl v1.0 (test corpus only, tracked in `Project.toml`)
