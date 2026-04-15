# Development Guide

## Project structure

Two repos work together:

- **`~/topiary-julia`** — The formatter. Rust binary using `topiary-core`. Formatting rules in `julia.scm`.
- **`~/tree-sitter-julia`** — Our grammar fork (`pankgeorg/tree-sitter-julia` branch `topiary-julia`). Based on upstream v0.25.0.

## Grammar update → formatter evaluation loop

### 1. Edit the grammar

```bash
cd ~/tree-sitter-julia
# Edit grammar.js (and/or src/scanner.c for external tokens)
```

### 2. Generate and test the parser

```bash
tree-sitter generate        # Regenerate src/parser.c from grammar.js
tree-sitter test             # Run corpus tests (test/corpus/*.txt)
```

If `generate` reports conflicts, either add to `conflicts: $ => [...]` in grammar.js or rethink the approach. All 70+ corpus tests must pass.

### 3. Test a snippet directly

```bash
printf 'your julia code' | tree-sitter parse /dev/stdin   # Quick check
printf 'code' | tree-sitter parse /dev/stdin --cst          # Full CST with anonymous tokens
```

### 4. Commit and push the grammar

```bash
git add grammar.js src/parser.c src/grammar.json src/node-types.json src/scanner.c
# Also add test/corpus/*.txt if you added test cases
git commit -m "feat(grammar): description"
git push
```

### 5. Update topiary-julia

```bash
cd ~/topiary-julia
cargo update -p tree-sitter-julia    # Pull latest grammar from git
```

### 6. Update formatting rules (if needed)

Edit `julia.scm`. Common patterns:
- New node type needs `@leaf`? Add to the leaf section at top.
- New node needs indentation? Add `@append_indent_start`/`@prepend_indent_end`.
- Semicolons displaced? Add `(parent_node ";" @delete)`.

### 7. Run the full test suite

```bash
cargo test --test format_test           # 68 hand-crafted tests (~2s)
cargo test --test roundtrip_test        # 59 tree-sitter corpus snippets (~10s)
cargo test --test ast_equivalence_test  # 828 JuliaSyntax.jl corpus (~2min)
```

### 8. Update expected counts

The ast_equivalence_test has constants at the top:
```rust
const EXPECTED_INTENTIONAL_ERRORS: usize = 88;
const EXPECTED_GRAMMAR_GAPS: usize = 56;
const EXPECTED_FORMAT_ERRORS: usize = 0;
const EXPECTED_AST_MISMATCHES: usize = 1;
```

The test fails if counts increase (regression) AND prints a message when counts decrease (improvement). Update the constants when you fix something.

## Generating the grammar gap report

Add a temporary test file to list all gaps:

```bash
cat > tests/check_gaps.rs << 'EOF'
mod common;
const JULIASYNTAX_CORPUS: &str = include_str!("corpus/juliasyntax_parser.jl");

#[test]
fn list_grammar_gaps() {
    let snippets = common::extract_juliasyntax_snippets(JULIASYNTAX_CORPUS);
    let mut gaps: Vec<(usize, &str, &str)> = Vec::new();
    for s in &snippets {
        if !s.is_intentional_error() && common::source_has_errors(&s.code) {
            gaps.push((s.line_num, &s.code, &s.expected));
        }
    }
    eprintln!("Grammar gaps: {}", gaps.len());
    for (line, code, expected) in &gaps {
        eprintln!("  L{line}: {code:?}  =>  {expected}");
    }
}
EOF
cargo test --test check_gaps -- --nocapture 2>&1 | grep '  L'
rm tests/check_gaps.rs
```

## Key files

| File | Purpose |
|------|---------|
| `julia.scm` | ALL formatting rules — Topiary query captures |
| `src/main.rs` | CLI binary (stdin/file → format → stdout) |
| `tests/common/mod.rs` | Shared helpers: `format_julia()`, `source_has_errors()`, `tree_to_sexp()`, `extract_juliasyntax_snippets()` |
| `tests/format_test.rs` | Hand-crafted input→output tests (68 tests, 9 modules) |
| `tests/roundtrip_test.rs` | Tree-sitter corpus round-trip (no new ERROR nodes) |
| `tests/ast_equivalence_test.rs` | JuliaSyntax.jl corpus AST comparison (828 snippets) |
| `tests/corpus/juliasyntax_parser.jl` | JuliaSyntax.jl test corpus (extracted from v1.0) |
| `tests/corpus/*.txt` | Tree-sitter corpus files (6 files, 59 snippets) |

## Tree-sitter-julia key files

| File | Purpose |
|------|---------|
| `grammar.js` | Grammar definition — all rules |
| `src/scanner.c` | External scanner — strings, block comments, immediate tokens, import dots |
| `src/parser.c` | Generated parser (do NOT edit manually) |
| `test/corpus/*.txt` | Corpus tests (70 tests) |

## Common tree-sitter-julia patterns

- **Hidden rules** start with `_` (e.g., `_terminator`, `_semicolon`). They don't create nodes in the tree.
- **`token.immediate(X)`** — X must follow the previous token with no whitespace.
- **`prec(N, rule)`** — precedence for resolving ambiguity. Higher wins. `PREC.array = -1`.
- **`alias('keyword', $.identifier)`** — make a keyword usable as an identifier (e.g., `public`).
- **External scanner tokens** — declared in `externals`, implemented in `src/scanner.c`. Priority over internal tokens.

## Common Topiary captures

| Capture | Effect |
|---------|--------|
| `@leaf` | Preserve subtree content verbatim |
| `@append_hardline` | Newline after node |
| `@prepend_hardline` | Newline before node |
| `@append_space` | Space after node |
| `@append_indent_start` | Start indentation after node |
| `@prepend_indent_end` | End indentation before node |
| `@append_spaced_softline` | Space (single-line) or newline (multi-line) |
| `@append_empty_softline` | Nothing (single-line) or newline (multi-line) |
| `@delete` | Remove the matched token |
| `@prepend_antispace` | Remove one space before node |
| `@allow_blank_line_before` | Preserve double newlines |
| `@do_nothing` | Explicitly do nothing (prevents other rules) |
| `@append_input_softline` | Hardline if original had line break, space otherwise (leaf nodes only) |

## Known pitfalls

- **`(_) . (_) @prepend_hardline`** only matches the FIRST pair of consecutive named siblings in tree-sitter-julia. Use `(_) @append_hardline` instead.
- **Anonymous tokens** (like `;`) get displaced by `@append_hardline`. Fix: `(parent ";" @delete)` to remove them, letting hardlines provide breaks.
- **`@append_input_softline`** checks line breaks on the LEAF node, not parent nodes. Don't use on `(_)` inside blocks.
- **Newlines in brackets** — `\n` is lexed as `_terminator` globally. Can't be treated as whitespace inside `[...]` without lexer changes.
- **Broadcast operators** — `.==`, `.⋆` etc. are lexed as single tokens. Can't split `.` from the operator for import paths like `import A.==`.
