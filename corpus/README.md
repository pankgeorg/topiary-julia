# topiary-julia corpus-based coverage tests

A reproducible corpus measuring three coverage metrics on real-world Julia
code (Pluto, JuMP, Turing, ModelingToolkit + transitive deps + Julia stdlib):

1. **Parse-OK** — does tree-sitter-julia parse the file with zero ERROR/MISSING nodes?
2. **Roundtrip-OK** — does `JuliaSyntax.parseall(original)` == `JuliaSyntax.parseall(format(original))`?
3. **Structure-match** — does tree-sitter-julia's CST (translated) match JuliaSyntax.jl's AST exactly?

## Usage

Requires a committed `Manifest.toml` (included here for reproducibility).

```bash
# 1. One-time setup: instantiate the dep environment.
julia --project=. -e 'using Pkg; Pkg.instantiate()'

# 2. Enumerate the corpus (reads Manifest.toml, writes corpus.json).
julia --project=. build_corpus.jl

# 3. Build the formatter once.
(cd .. && cargo build --release)

# 4. Run all three metrics on every file (writes results/metrics.jsonl).
julia --project=. run_checks.jl

# 5. Aggregate the report (writes results/report.md and failure dumps).
julia --project=. report.jl
```

`results/` is regenerated each run and is gitignored.

## Family categorization

Each package in the manifest is assigned one **primary family** using precedence:

```
Pluto > MTK > JuMP > Turing > Other
```

If a package is transitively reachable from Pluto (say, via `MacroTools`),
it's tagged `Pluto` in the table even though JuMP also depends on it. A
secondary `transitive_of` list in each file's metadata records all roots
that pull the package in, so richer cross-family analysis is possible.

The Julia stdlib (`$(Sys.BINDIR)/../share/julia/{base,test}/**/*.jl`) is a
separate `Stdlib` family.

## Output schema

### `corpus.json`

```json
{
  "julia_version": "1.12.5+0",
  "manifest_sha": "<sha256 of Manifest.toml>",
  "families": {
    "Pluto": [{"path": "...", "pkg": "Pluto", "version": "0.20.3", "transitive_of": ["Pluto"]}, ...],
    "MTK": [...],
    "JuMP": [...],
    "Turing": [...],
    "Stdlib": [...],
    "Other": [...]
  }
}
```

### `results/metrics.jsonl` (one line per file, streamed)

```json
{"path": "...", "family": "MTK", "pkg": "ModelingToolkit",
 "parse_ok": true, "roundtrip_ok": false, "structure_match": false,
 "roundtrip_failure": "first_diff=(block/...)  node_kind=quote_expression",
 "structure_failure": "no_translation_rule:broadcast_call_expression"}
```

### `results/report.md`

Per-family table + failure buckets sorted by impact (see docs in `report.jl`).

Per-file diffs dumped to `results/failures/{parse,roundtrip,structure}/<root_cause>/<file>.diff`.
