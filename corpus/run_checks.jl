#!/usr/bin/env julia
# run_checks.jl — Compute three coverage metrics for every file in corpus.json.
#
#   metric 1: parse_ok         — tree-sitter-julia parses without ERROR/MISSING.
#   metric 2: roundtrip_ok     — JuliaSyntax.parseall(before) == parseall(after-format).
#   metric 3: structure_match  — Translator.translate(ts_sexp) == juliasyntax_sexp.
#
#   Writes one JSONL row per file to results/metrics.jsonl so Ctrl-C leaves
#   a partially usable result.
#
#   Run with: julia --project=. run_checks.jl [--limit N] [--family F]

using JSON
using JuliaSyntax
using SHA: sha256

include("translator.jl")
using .Translator

const CORPUS_JSON = joinpath(@__DIR__, "corpus.json")
const RESULTS_DIR = joinpath(@__DIR__, "results")
const METRICS_PATH = joinpath(RESULTS_DIR, "metrics.jsonl")
const BIN = normpath(joinpath(@__DIR__, "..", "target", "release", "topiary-julia"))

# ─── Primitives ────────────────────────────────────────────────────

"Run `topiary-julia parse < code`. Returns (exit_code, stdout).
Exit code 2 (parse errors) is expected — don't raise."
function ts_parse_sexp(code::AbstractString)
    out = IOBuffer()
    inp = IOBuffer(code)
    proc = try
        run(pipeline(`$BIN parse`, stdin=inp, stdout=out, stderr=devnull),
            wait=true)
    catch e
        # Non-zero exit throws. Extract the exit code from ProcessFailedException.
        if e isa Base.ProcessFailedException
            return (e.procs[1].exitcode, strip(String(take!(out))))
        end
        return (-1, "")
    end
    return (proc.exitcode, strip(String(take!(out))))
end

"Run the formatter. Returns (success, formatted_text)."
function ts_format(code::AbstractString)
    out = IOBuffer()
    err = IOBuffer()
    inp = IOBuffer(code)
    try
        proc = run(pipeline(`$BIN --tolerate-parsing-errors --skip-idempotence`,
                            stdin=inp, stdout=out, stderr=err), wait=true)
        return (proc.exitcode == 0, String(take!(out)))
    catch
        return (false, "")
    end
end

"JuliaSyntax canonical sexp. Returns nothing if parse fails."
function js_sexp(code::AbstractString)::Union{String, Nothing}
    try
        tree = parseall(SyntaxNode, code)
        buf = IOBuffer()
        show(buf, MIME"text/x.sexpression"(), tree)
        return String(take!(buf))
    catch
        return nothing
    end
end

"True if a JuliaSyntax parse tree has no `:error` leaves (anywhere)."
function js_parses_clean(code::AbstractString)::Bool
    try
        tree = parseall(SyntaxNode, code)
        return !js_tree_has_error(tree)
    catch
        return false
    end
end

function js_tree_has_error(node::SyntaxNode)
    kind(node) == K"error" && return true
    for c in (children(node) === nothing ? [] : children(node))
        js_tree_has_error(c) && return true
    end
    return false
end

# Structural diff between two JuliaSyntax trees via their sexp strings.
# Two trees are considered equal if their sexp output matches exactly.
function js_trees_match(a::AbstractString, b::AbstractString)
    sa = js_sexp(a)
    sb = js_sexp(b)
    (sa === nothing || sb === nothing) && return false, "parse_failed"
    sa == sb && return true, ""
    # First-diff marker for debugging.
    return false, _first_diff(sa, sb)
end

function _first_diff(a::String, b::String)::String
    n = min(length(a), length(b))
    i = 1
    while i <= n && a[i] == b[i]
        i = nextind(a, i)
    end
    # Surround the diff point with a short window.
    ctx = 30
    s = max(1, i - ctx)
    ae = min(length(a), i + ctx)
    be = min(length(b), i + ctx)
    return "diff@$i: $(SubString(a, s, ae)) | $(SubString(b, s, be))"
end

# ─── Metric 3: structure match via translator ──────────────────────

# Classify a translator output for bucketing. Returns `root_cause` string.
function _walk_for_missing(n::Translator.Node)::Union{String, Nothing}
    startswith(n.kind, "no_translation_rule:") && return n.kind
    for c in n.children
        r = _walk_for_missing(c)
        r === nothing || return r
    end
    return nothing
end

function structure_check(code::AbstractString, ts_exit::Int, ts_sexp_str::AbstractString)
    # If tree-sitter itself couldn't parse, metric 3 is N/A.
    ts_exit == 0 || return (false, "ts_parse_error")
    js = js_sexp(code)
    js === nothing && return (false, "js_parse_error")
    local ts_tree, translated, actual
    try
        ts_tree = Translator.parse_sexp(ts_sexp_str)
    catch e
        return (false, "sexp_reader_error")
    end
    try
        translated = Translator.translate(ts_tree)
    catch e
        return (false, "translator_exception:$(typeof(e).name.name)")
    end
    # Flag any untranslated node kinds.
    missing_rule = _walk_for_missing(translated)
    if missing_rule !== nothing
        return (false, missing_rule)
    end
    actual = Translator.sexp_string(translated)
    actual == js && return (true, "")
    return (false, "rule_output_mismatch:" * _summarize_mismatch(actual, js))
end

function _summarize_mismatch(a::String, b::String)::String
    # Find the first non-matching token to bucket by. Heuristic: extract the
    # first `(kind` that differs.
    n = min(length(a), length(b))
    i = 1
    while i <= n && a[i] == b[i]
        i = nextind(a, i)
    end
    # Back up to the nearest '(' so we report a node boundary.
    j = i
    while j > 1 && a[j] != '('
        j = prevind(a, j)
    end
    snippet = SubString(a, j, min(length(a), j + 40))
    return string(snippet)
end

# ─── Driver ────────────────────────────────────────────────────────

struct CliArgs
    limit::Union{Int, Nothing}
    family::Union{String, Nothing}
end

function _parse_args()
    limit = nothing
    family = nothing
    i = 1
    while i <= length(ARGS)
        a = ARGS[i]
        if a == "--limit"
            limit = Base.parse(Int, ARGS[i+1])
            i += 2
        elseif a == "--family"
            family = ARGS[i+1]
            i += 2
        else
            error("Unknown arg: $a")
        end
    end
    return CliArgs(limit, family)
end

function _read_code(path::AbstractString)::Union{String, Nothing}
    try
        return read(path, String)
    catch
        return nothing
    end
end

function main()
    args = _parse_args()
    isdir(RESULTS_DIR) || mkdir(RESULTS_DIR)

    isfile(BIN) || error("topiary-julia binary not found at $BIN; run `cargo build --release` first.")

    @info "Loading corpus" CORPUS_JSON
    corpus = JSON.parsefile(CORPUS_JSON)
    families = corpus["families"]
    total = sum(length(v) for v in values(families))
    @info "Corpus loaded" files=total manifest_sha=corpus["manifest_sha"] julia_version=corpus["julia_version"]

    # Flatten to an ordered list. If --family given, restrict.
    flat = Dict{String, Any}[]
    for fam in corpus["family_order"]
        (args.family === nothing || args.family == fam) || continue
        for entry in families[fam]
            push!(flat, entry)
        end
    end
    if args.limit !== nothing
        flat = flat[1:min(args.limit, length(flat))]
    end

    @info "Processing" files=length(flat)

    open(METRICS_PATH, "w") do io
        # Header line with meta.
        meta = Dict(
            "_meta" => true,
            "julia_version" => corpus["julia_version"],
            "manifest_sha" => corpus["manifest_sha"],
            "binary" => BIN,
            "binary_mtime" => try
                string(mtime(BIN))
            catch
                ""
            end,
            "count" => length(flat),
            "timestamp" => string(Dates.now() isa Dates.DateTime ? Dates.now() : now()),
        )
        JSON.print(io, meta); write(io, '\n')
        flush(io)

        t0 = time()
        for (i, entry) in enumerate(flat)
            path = entry["path"]
            code = _read_code(path)
            row = Dict{String, Any}(
                "path" => path,
                "family" => entry["family"],
                "pkg" => entry["pkg"],
                "version" => entry["version"],
                "transitive_of" => entry["transitive_of"],
            )
            if code === nothing
                row["parse_ok"] = false
                row["roundtrip_ok"] = false
                row["structure_match"] = false
                row["error"] = "read_failed"
                JSON.print(io, row); write(io, '\n')
                _progress(i, length(flat), t0)
                continue
            end

            # Wrap every file in try/catch so a single bad file can't abort
            # the whole run. Unexpected exceptions surface as `error` field.
            try
                # ── Metric 1: tree-sitter parse OK ────────────────────
                ts_exit, ts_sexp_str = ts_parse_sexp(code)
                parse_ok = (ts_exit == 0)
                row["parse_ok"] = parse_ok

                # ── Metric 2: round-trip ───────────────────────────────
                ok_format, formatted = ts_format(code)
                if ok_format
                    match_ok, diff_info = js_trees_match(code, formatted)
                    row["roundtrip_ok"] = match_ok
                    if !match_ok
                        row["roundtrip_failure"] = diff_info
                    end
                else
                    row["roundtrip_ok"] = false
                    row["roundtrip_failure"] = "format_failed"
                end

                # ── Metric 3: structure match via translator ─────────
                match_ok, root_cause = structure_check(code, ts_exit, ts_sexp_str)
                row["structure_match"] = match_ok
                if !match_ok
                    row["structure_failure"] = root_cause
                end
            catch e
                row["parse_ok"] = get(row, "parse_ok", false)
                row["roundtrip_ok"] = get(row, "roundtrip_ok", false)
                row["structure_match"] = false
                row["error"] = "$(typeof(e).name.name): " * first(sprint(showerror, e), 200)
            end

            JSON.print(io, row); write(io, '\n')
            flush(io)
            _progress(i, length(flat), t0)
        end
    end
    println()
    @info "Done" metrics_path=METRICS_PATH
end

using Dates

function _progress(i, n, t0)
    if i % 25 == 0 || i == n
        elapsed = time() - t0
        rate = i / max(elapsed, 0.001)
        eta = (n - i) / max(rate, 0.001)
        print("\r  $i / $n  ($(round(rate, digits=1)) files/s, ETA $(round(Int, eta))s)  ")
    end
end

main()
