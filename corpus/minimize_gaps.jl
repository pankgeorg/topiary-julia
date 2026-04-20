#!/usr/bin/env julia
# minimize_gaps.jl — find minimal tree-sitter-julia parse failures.
#
# For every input Julia file:
#   1. Run tree-sitter-julia on the whole file. Clean parse → skip.
#   2. Parse with JuliaSyntax to get a CST with byte ranges.
#   3. Bisect the CST: for each node, slice the source to the node's
#      byte range and re-run tree-sitter on that slice. If the slice
#      still errors, recurse into its children. If no child alone
#      triggers the error, this node is the minimal witness.
#
# Inputs:
#   --fixtures <dir>  Directory to walk for *.jl files (default: ./fixtures)
#   --corpus <path>   corpus.json produced by build_corpus.jl (optional)
#   --limit <N>       Cap number of files processed (useful for smoke tests)
#   --bin <path>      Path to `topiary-julia` binary (default: built release)
#
# Outputs:
#   tests/corpus/localized_gaps.toml     machine-readable, read by build.rs
#   corpus/results/gaps_report.md        human-readable report
#
# Usage:
#   julia --project=corpus/minimizer corpus/minimize_gaps.jl

using JuliaSyntax
using TOML
using Dates
using JSON: JSON  # optional — only when --corpus is passed

const REPO_ROOT = normpath(joinpath(@__DIR__, ".."))
const DEFAULT_BIN = joinpath(REPO_ROOT, "target", "release", "topiary-julia")
const DEFAULT_FIXTURES = joinpath(@__DIR__, "fixtures")
const OUT_TOML = joinpath(REPO_ROOT, "tests", "corpus", "localized_gaps.toml")
const REPORT_MD = joinpath(@__DIR__, "results", "gaps_report.md")

# ─── Tree-sitter invocation ────────────────────────────────────────

struct TsResult
    output::String
    errored::Bool   # true if exit 2 OR output contains ERROR/MISSING nodes
end

"""
    ts_parse(bin, code) -> TsResult

Run `topiary-julia parse` on `code` and classify the result. Exit code 2
means the grammar returned ERROR/MISSING nodes. Exit 0 means a clean
parse. Anything else is treated as an infrastructure failure.
"""
function ts_parse(bin::AbstractString, code::AbstractString)
    out = IOBuffer()
    inp = IOBuffer(code)
    try
        run(pipeline(`$bin parse`, stdin = inp, stdout = out, stderr = devnull), wait = true)
        return TsResult(strip(String(take!(out))), false)
    catch e
        if e isa Base.ProcessFailedException
            code = e.procs[1].exitcode
            text = strip(String(take!(out)))
            # Exit 2 = parse errors; treat anything non-zero as an error.
            return TsResult(text, code != 0)
        end
        rethrow()
    end
end

# ─── Bisection ─────────────────────────────────────────────────────

struct Finding
    code::String        # minimal snippet that still errors
    js_sexp::String     # JuliaSyntax s-expression for the same code
    ts_output::String   # tree-sitter output (with ERROR nodes)
    origin::String      # <path>:<line>
end

"""
    bisect!(findings, bin, code, file_code, origin)

Walk the JuliaSyntax CST rooted at `node`. For each node, slice the
source by its byte range, re-run tree-sitter on that slice, and descend
only if the slice still errors. A node is recorded as a finding if it
errors AND none of its descendants produces its own finding.
"""
function bisect!(findings::Vector{Finding}, bin, node, file_code, origin)
    r = JuliaSyntax.byte_range(node)
    # Guard: sometimes JuliaSyntax emits zero-width nodes or ranges that
    # extend past EOF when `ignore_errors=true`. Skip those — a zero-
    # width or out-of-bounds slice isn't a meaningful minimization target.
    (isempty(r) || last(r) > ncodeunits(file_code)) && return
    # Slice by raw bytes — JuliaSyntax can emit ranges that don't align
    # with char boundaries around multi-byte UTF-8 (e.g. at the edge of
    # a trivia token). String(::Vector{UInt8}) tolerates malformed UTF-8
    # by keeping the bytes as-is; tree-sitter will then either parse or
    # reject them, both of which are fine.
    snippet = String(codeunits(file_code)[r])
    # Empty/whitespace-only snippet can't be a useful finding.
    isempty(strip(snippet)) && return

    result = ts_parse(bin, snippet)
    result.errored || return  # this slice parses clean — no need to recurse

    n_before = length(findings)
    # JuliaSyntax.children returns `nothing` for leaves, not an empty iterator.
    kids = JuliaSyntax.children(node)
    if kids !== nothing
        for child in kids
            bisect!(findings, bin, child, file_code, origin)
        end
    end
    if length(findings) == n_before
        # No child captured the failure in isolation — this node is minimal.
        line = first(JuliaSyntax.source_location(node))
        js_sexp = sprint(io -> show(io, MIME"text/x.sexpression"(), node))
        push!(findings, Finding(snippet, js_sexp, result.output, "$origin:$line"))
    end
end

"""
    process_file(bin, path, code)

Return the Findings for a single file, or an empty vector if the file
parses clean under tree-sitter.
"""
function process_file(bin, origin, code)::Vector{Finding}
    findings = Finding[]
    full = ts_parse(bin, code)
    full.errored || return findings
    tree = try
        parseall(SyntaxNode, code; ignore_errors = true)
    catch e
        @warn "JuliaSyntax parseall failed on $origin: $e"
        return findings
    end
    bisect!(findings, bin, tree, code, origin)
    findings
end

# ─── Input collection ──────────────────────────────────────────────

"""
Strip the user's `\$HOME` from a path, returning e.g.
`~/.julia/packages/Pluto/abcd/src/foo.jl`. Keeps the TOML and report
portable across machines with different usernames.
"""
function normalize_origin(path::AbstractString)
    home = homedir()
    startswith(path, home) ? "~" * path[nextind(path, lastindex(home)):end] : path
end

"""
    collect_fixtures(dir) -> Vector{Tuple{origin, code}}
"""
function collect_fixtures(dir)
    isdir(dir) || return Tuple{String,String}[]
    out = Tuple{String,String}[]
    for (root, _dirs, files) in walkdir(dir)
        for f in files
            endswith(f, ".jl") || continue
            path = joinpath(root, f)
            origin = relpath(path, REPO_ROOT)
            push!(out, (origin, read(path, String)))
        end
    end
    sort!(out, by = first)
    out
end

"""
Read `corpus.json` (as written by build_corpus.jl) and return
(origin, code) pairs for every file listed. The corpus is a
`families` dict of arrays; we flatten across families and dedupe
paths (a single package can be reachable from multiple family
roots).
"""
function collect_from_corpus_json(path)
    isfile(path) || error("--corpus: file not found: $path")
    data = JSON.parsefile(path)
    haskey(data, "families") || error("--corpus: no `families` key in $path")
    out = Tuple{String,String}[]
    seen = Set{String}()
    for (_family, entries) in data["families"]
        for entry in entries
            file_path = entry["path"]
            (file_path in seen) && continue
            push!(seen, file_path)
            isfile(file_path) || continue
            push!(out, (normalize_origin(file_path), read(file_path, String)))
        end
    end
    out
end

# ─── Dedup & sort ──────────────────────────────────────────────────

function dedup(findings::Vector{Finding})
    seen = Set{String}()
    out = Finding[]
    for f in findings
        f.code in seen && continue
        push!(seen, f.code)
        push!(out, f)
    end
    # Deterministic order: shortest snippets first, ties by code.
    sort!(out, by = f -> (length(f.code), f.code))
    out
end

# ─── Output writers ────────────────────────────────────────────────

function write_toml(path, findings::Vector{Finding})
    mkpath(dirname(path))
    open(path, "w") do io
        println(io, "# Minimal tree-sitter-julia parse failures.")
        println(io, "#")
        println(io, "# Generated by `corpus/minimize_gaps.jl`. Do not hand-edit — regenerate")
        println(io, "# the script's output and commit the whole file.")
        println(io, "#")
        println(io, "# Consumed by `build.rs`, which emits one `#[test]` per entry. Each")
        println(io, "# test asserts tree-sitter-julia still errors on the snippet; when a")
        println(io, "# snippet starts parsing clean, the test fails with `resolved` so the")
        println(io, "# entry gets removed here.")
        println(io)
        data = Dict("snippet" => [
            Dict(
                "code" => f.code,
                "js_sexp" => f.js_sexp,
                "origin" => f.origin,
            ) for f in findings
        ])
        TOML.print(io, data)
    end
end

function write_report(path, findings::Vector{Finding}, n_scanned, n_errored)
    mkpath(dirname(path))
    open(path, "w") do io
        println(io, "# Tree-sitter-julia parse-gap report")
        println(io)
        println(io, "Generated: ", Dates.format(now(), "yyyy-mm-ddTHH:MM:SS"))
        println(io, "Scanned: ", n_scanned, " files")
        println(io, "With errors: ", n_errored, " files")
        println(io, "Minimal snippets (after dedup): ", length(findings))
        println(io)
        println(io, "Regenerate with:")
        println(io)
        println(io, "```bash")
        println(io, "julia --project=corpus/minimizer corpus/minimize_gaps.jl")
        println(io, "```")
        println(io)

        if isempty(findings)
            println(io, "No parse failures found. 🎉")
            return
        end

        # Index table
        println(io, "## Index")
        println(io)
        println(io, "| # | Preview | Origin |")
        println(io, "|---|---------|--------|")
        for (i, f) in enumerate(findings)
            preview = replace(f.code, "\n" => "⏎")
            if length(preview) > 60
                preview = first(preview, 57) * "..."
            end
            # Escape pipe characters for markdown.
            preview = replace(preview, "|" => "\\|")
            println(io, "| $i | `", preview, "` | `", f.origin, "` |")
        end
        println(io)

        # Per-snippet details
        for (i, f) in enumerate(findings)
            println(io, "## Snippet ", i)
            println(io)
            println(io, "**Origin:** `", f.origin, "`")
            println(io)
            println(io, "**Code:**")
            println(io)
            println(io, "```julia")
            println(io, f.code)
            println(io, "```")
            println(io)
            println(io, "**JuliaSyntax parse:**")
            println(io)
            println(io, "```sexp")
            println(io, f.js_sexp)
            println(io, "```")
            println(io)
            println(io, "**Tree-sitter-julia output:**")
            println(io)
            println(io, "```sexp")
            println(io, f.ts_output)
            println(io, "```")
            println(io)
        end
    end
end

# ─── Main ──────────────────────────────────────────────────────────

function parse_args()
    args = Dict{Symbol,Any}(
        :fixtures => DEFAULT_FIXTURES,
        :corpus => nothing,
        :limit => typemax(Int),
        :bin => DEFAULT_BIN,
    )
    i = 1
    while i <= length(ARGS)
        arg = ARGS[i]
        if arg == "--fixtures"
            args[:fixtures] = ARGS[i+1]
            i += 2
        elseif arg == "--corpus"
            args[:corpus] = ARGS[i+1]
            i += 2
        elseif arg == "--limit"
            # Base.parse — `using JuliaSyntax` shadows the unqualified name.
            args[:limit] = Base.parse(Int, ARGS[i+1])
            i += 2
        elseif arg == "--bin"
            args[:bin] = ARGS[i+1]
            i += 2
        elseif arg == "-h" || arg == "--help"
            println(stderr, read(@__FILE__, String))
            exit(0)
        else
            error("unknown argument: $arg (see --help)")
        end
    end
    args
end

function main()
    args = parse_args()
    bin = args[:bin]
    isfile(bin) || error("topiary-julia binary not found at $bin — build with `cargo build --release`")

    inputs = Tuple{String,String}[]
    append!(inputs, collect_fixtures(args[:fixtures]))
    if args[:corpus] !== nothing
        append!(inputs, collect_from_corpus_json(args[:corpus]))
    end
    if length(inputs) > args[:limit]
        inputs = inputs[1:args[:limit]]
    end
    println("Scanning ", length(inputs), " file(s)...")
    if isempty(inputs)
        @warn "No input files. Add Julia files to $(args[:fixtures]) or pass --corpus."
    end

    findings = Finding[]
    n_errored = 0
    for (idx, (origin, code)) in enumerate(inputs)
        file_findings = process_file(bin, origin, code)
        if !isempty(file_findings)
            n_errored += 1
            append!(findings, file_findings)
        end
        if idx % 50 == 0
            println("  processed $idx / $(length(inputs))")
        end
    end

    deduped = dedup(findings)
    println("Files with tree-sitter parse errors: ", n_errored)
    println("Minimal snippets (raw): ", length(findings))
    println("Minimal snippets (deduped): ", length(deduped))

    write_toml(OUT_TOML, deduped)
    write_report(REPORT_MD, deduped, length(inputs), n_errored)
    println("Wrote ", relpath(OUT_TOML, REPO_ROOT))
    println("Wrote ", relpath(REPORT_MD, REPO_ROOT))
end

main()
