# jlparse: Julia's own parser in topiary-julia

`parser.wasm` is `Base.JuliaSyntax` (the parser shipped with Julia 1.13) compiled to WebAssembly
GC + exception handling by [WasmCodegen.jl](https://github.com/gbaraldi/WasmCodegen.jl)
(`examples/juliasyntax`, main 316bbaf), optimized with `wasm-opt -O3`. topiary-julia runs it
in-process on [wasmtime](https://wasmtime.dev) 50 (`src/jlparse.rs`) to

1. **verify** every formatting: input and output are parsed by JuliaSyntax and compared
   (normal form in `src/jlparse.rs`, `Sem`); an output that means something else is never
   written;
2. **protect grammar gaps**: code tree-sitter-julia can't parse but JuliaSyntax can is left
   verbatim — the smallest JuliaSyntax node around it is swapped for a placeholder for
   Topiary and put back after (`src/format.rs`); the same happens to a node whose
   formatting would change its meaning;
3. report **syntax errors** with JuliaSyntax's diagnostics (`file:line:col: error: …`).

`--no-verify` restores plain Topiary. `topiary-julia jl-parse [--sem]` prints JuliaSyntax's
tree; `topiary-julia verify BEFORE AFTER` compares two files.

## Files

- `parser.jl` — the entry points: WasmCodegen's `examples/juliasyntax/parser.jl` plus
  `src_set4` (4 source bytes per call) and `out_flags` (raw flags). Only numbers cross the
  boundary.
- `build.jl` — builds `parser.wasm` (committed, 735 KB).

## Rebuilding parser.wasm

```bash
git clone https://github.com/gbaraldi/WasmCodegen.jl
cd WasmCodegen.jl/examples/juliasyntax
julia +1.13 --project=. -e 'using Pkg; Pkg.instantiate()'
julia +1.13 --project=. path/to/topiary-julia/jlparse/build.jl    # ~2.5 min
```

`tests/jlparse_test.rs::matches_native_reference` checks the module against native
JuliaSyntax node for node (`tests/corpus/jlparse_reference.json`, from the example's
`reference.jl`; regenerate it with Julia 1.13 when the module's Julia version changes).

## Compiled-code cache

Cranelift compiles the module in ~2 s; the result is cached at first use in
`$TOPIARY_JULIA_CACHE`, else `$XDG_CACHE_HOME/topiary-julia`, else `~/.cache/topiary-julia`
(key: module hash + wasmtime compatibility hash), and later runs load it in ~7 ms.
`TOPIARY_JULIA_CACHE=off` disables the cache.

## Debugging

`RUST_LOG=topiary_julia=debug topiary-julia f.jl` logs each round of the protect loop (which
regions are protected, where tree-sitter still fails, why an output didn't verify).
`topiary-julia jl-parse --sem < f.jl` prints the normal form that is compared.

## Reports

- `GAPS.md` — what happens to each of the 69 known grammar gaps
  (`scripts/gaps_report.py`).
- `scripts/jlparse_realworld.sh BINARY FILES…` — verified vs. `--no-verify` per file
  (exit codes, times, notes).
