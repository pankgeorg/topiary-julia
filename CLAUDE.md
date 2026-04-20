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

### 7. Run the tests

Every corpus snippet is its own `#[test]`; cargo runs them in parallel.
Filter by name to iterate on a single case.

```bash
cargo test                                # full suite (~25s wall, parallel)
cargo test --test format_test             # hand-crafted input→output cases
cargo test --test roundtrip_test          # tree-sitter corpus, one test per snippet
cargo test --test ast_equivalence_test    # JuliaSyntax.jl corpus, one test per line

# Target a single snippet (JuliaSyntax line 197):
cargo test --test ast_equivalence_test ast_line_0197

# Target all known grammar gaps:
cargo test --test ast_equivalence_test grammar_gap

# Target a line range (any line 0100-0199):
cargo test --test ast_equivalence_test ast_line_01

# Target one round-trip case:
cargo test --test roundtrip_test rt_expressions_some_name
```

Never run watch-mode commands (`cargo watch`, `tree-sitter test --watch`,
etc.) — they leave orphaned processes behind. Use one-shot invocations and
targeted filters for iteration speed.

### 8. Update `tests/corpus/expectations.toml`

Each snippet classified as an expected failure is listed here:

```toml
[[juliasyntax]]
line = 197
status = "grammar_gap"    # or "format_error" | "ast_mismatch"
note  = "x.3 — numeric field access"

[[roundtrip]]
file  = "expressions"
name  = "some header"
note  = "why it regresses"
```

Behavior:
- **Unlisted snippet fails** → regression. Fix the cause, or add the
  snippet to `expectations.toml`.
- **Listed snippet passes** → `expect_*` assertion reports "resolved".
  Remove the entry from `expectations.toml` and the positive-path test
  takes over.

The TOML is consumed by `build.rs`, which emits one `#[test]` per snippet
into `$OUT_DIR`. Cargo re-runs the build script when the TOML or any
corpus file changes.

## Real-world-corpus smoke test (`scripts/smoke-test.sh`)

Runs format + JuliaSyntax AST-equivalence on a stratified random sample
of the real-world Julia corpus (~180 files, ~15%). Catches regressions
the per-snippet suites miss. Budget: ≤ 3 min wall.

```bash
./scripts/smoke-test.sh                                   # replay the current sample

# regenerate the sample (also updates the baseline; run this after a
# grammar fix lands, so improvements flip to expected_pass = true):
julia --project=corpus/minimizer scripts/smoke_sample_gen.jl --seed 42 --target 180
```

Flags:
- `./scripts/smoke-test.sh --sample <path>` — point at a different sample TOML
- `--budget <seconds>` — adjust the wall-clock watchdog (default 180)

Exit code 0 ⇔ zero regressions. Improvements and source drifts are
informational. The sample TOML is `tests/corpus/smoke_sample.toml` and
is self-baselined (each entry records `expected_pass` + content SHA).

## Localizing new grammar gaps (`corpus/minimize_gaps.jl`)

When a real Julia file trips tree-sitter-julia, run the minimizer to
bisect it down to the minimal failing sub-expression using JuliaSyntax
as the oracle for structure.

```bash
# one-time: set up the minimizer's Julia env (JuliaSyntax + JSON)
julia --project=corpus/minimizer -e 'using Pkg; Pkg.instantiate()'

# each time: run against corpus/fixtures/*.jl (and optionally a corpus.json)
cargo build --release                              # minimizer calls the release binary
julia --project=corpus/minimizer corpus/minimize_gaps.jl
julia --project=corpus/minimizer corpus/minimize_gaps.jl --corpus corpus/corpus.json
```

Outputs:
- `tests/corpus/localized_gaps.toml` — machine-readable, read by `build.rs`.
  Each entry emits one `#[test] fn ts_gap_NNNN()` that asserts the snippet
  still fails under tree-sitter.
- `corpus/results/gaps_report.md` — human-readable report. Index + per-
  snippet detail (code, JuliaSyntax parse, tree-sitter output).

Adding a new broken file: drop it in `corpus/fixtures/` (one per semantic
family is cleanest) and re-run the minimizer. Fixing a gap: regenerate;
the matching `ts_gap_NNNN` test will start failing with `resolved` — commit
the regenerated TOML.

**Scope (v1):** detects only parse errors (`ERROR` / `MISSING` nodes).
Semantic misparses — tree-sitter produces a valid-looking but structurally
wrong tree, e.g. `for i in 1 : n` landing as `quote_expression` — are out
of scope until the minimizer grows a translator-backed comparison pass.
Known semantic cases are parked in `corpus/fixtures/semantic_misparses/`.

## Generating the grammar gap list

The list lives in `tests/corpus/expectations.toml`. If you want a fresh
enumeration after a grammar change:

```bash
cargo test --test ast_equivalence_test grammar_gap 2>&1 | grep '^test ast_line_'
```

To find *new* grammar gaps that aren't yet listed:

```bash
cargo test --test ast_equivalence_test 2>&1 | awk '/Input does not parse cleanly/{getline; print}'
```

## Key files

| File | Purpose |
|------|---------|
| `julia.scm` | ALL formatting rules — Topiary query captures |
| `src/main.rs` | CLI binary (stdin/file → format → stdout) |
| `build.rs` | Codegen: reads corpus + `expectations.toml`, writes one `#[test]` per snippet into `$OUT_DIR` |
| `tests/common/mod.rs` | Shared helpers: `format_julia()`, `source_has_errors()`, `tree_to_sexp()`, `assert_ast_equivalent()`, `assert_roundtrip_clean()`, `expect_grammar_gap()` |
| `tests/format_test.rs` | Hand-crafted input→output tests |
| `tests/roundtrip_test.rs` | Entry point — includes generated tree-sitter corpus tests |
| `tests/ast_equivalence_test.rs` | Entry point — includes generated JuliaSyntax corpus tests |
| `tests/corpus/expectations.toml` | Snippets expected to fail (grammar gaps, format errors, AST mismatches) |
| `tests/corpus/localized_gaps.toml` | Minimized parse failures from real Julia files (generated by `corpus/minimize_gaps.jl`) |
| `tests/corpus/juliasyntax_parser.jl` | JuliaSyntax.jl test corpus (extracted from v1.0) |
| `tests/corpus/*.txt` | Tree-sitter corpus files (6 files, 59 snippets) |
| `corpus/minimize_gaps.jl` | Bisection tool — walks JuliaSyntax CST to minimize tree-sitter parse failures |
| `corpus/minimizer/` | Minimal Julia env for the minimizer (JuliaSyntax + JSON) |
| `corpus/fixtures/` | User-supplied Julia files to feed the minimizer |
| `corpus/results/gaps_report.md` | Human-readable output of the minimizer |
| `scripts/smoke-test.sh` | Wrapper to run the real-world-corpus smoke test |
| `scripts/smoke_sample_gen.jl` | Stratified random sampler that writes the sample TOML with self-baselined `expected_pass` per file |
| `scripts/smoke_test.jl` | Replay — flags regressions / improvements / drifts |
| `scripts/_ast_check.jl` | Shared AstCheck module (strip_lines, safe_parseall, format_code, find_first_diff) |
| `tests/corpus/smoke_sample.toml` | Committed sample + baseline read by smoke_test |

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
