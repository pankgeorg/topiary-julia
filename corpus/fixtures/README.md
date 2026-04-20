# Minimizer fixtures

Julia source files known to exercise tree-sitter-julia parse failures.

The minimizer (`corpus/minimize_gaps.jl`) reads every `*.jl` under this
directory, runs it through tree-sitter-julia, and — for files that error —
walks the JuliaSyntax.jl CST to bisect down to the minimal sub-expression
that still triggers the error.

## Adding a case

Drop any `.jl` file in this directory. Name it something descriptive
(`for_spaced_range.jl`, `numeric_field_access.jl`, etc.). One file per
semantic family of bug is easiest to audit, but bigger files work too —
the minimizer will shrink them.

## Regenerating outputs

```bash
julia --project=corpus/minimizer corpus/minimize_gaps.jl
```

Writes:
- `tests/corpus/localized_gaps.toml` — machine-readable, consumed by `build.rs`
- `corpus/results/gaps_report.md` — human-readable report

## What counts as a "gap" (v1)

The minimizer detects **parse errors** — cases where tree-sitter-julia
emits ERROR or MISSING nodes. Semantic misparses (tree-sitter produces a
valid-looking tree that structurally disagrees with JuliaSyntax) are out
of scope for v1; catching them requires running the translator as an
oracle. See `corpus/fixtures/semantic_misparses/` for cases the minimizer
will flag once v2 lands.
