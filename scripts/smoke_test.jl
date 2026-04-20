#!/usr/bin/env julia
# smoke_test.jl — replay the corpus smoke-test sample and flag deltas.
#
# Reads a sample TOML (default: tests/corpus/smoke_sample.toml) written
# by scripts/smoke_sample_gen.jl, re-runs the format + JuliaSyntax
# AST-equivalence check on every listed file, and reports:
#
#   regression  — expected_pass=true, now failing (test failure)
#   improvement — expected_pass=false, now passing (informational)
#   drift       — sha on disk differs from baseline (informational, skipped)
#
# Exit code 0 on zero regressions, 1 otherwise.
#
# Usage:
#   julia --project=corpus/minimizer scripts/smoke_test.jl \
#       [--sample tests/corpus/smoke_sample.toml] \
#       [--bin target/release/topiary-julia] [--budget 180]

using SHA: sha256
using TOML

include(joinpath(@__DIR__, "_ast_check.jl"))
using .AstCheck

const REPO_ROOT = normpath(joinpath(@__DIR__, ".."))
const DEFAULT_SAMPLE = joinpath(REPO_ROOT, "tests", "corpus", "smoke_sample.toml")
const DEFAULT_BIN = joinpath(REPO_ROOT, "target", "release", "topiary-julia")

function parse_args()
    args = Dict{Symbol,Any}(
        :sample => DEFAULT_SAMPLE,
        :bin => DEFAULT_BIN,
        :budget => 180.0,  # seconds
    )
    i = 1
    while i <= length(ARGS)
        a = ARGS[i]
        if a == "--sample"
            args[:sample] = ARGS[i+1]; i += 2
        elseif a == "--bin"
            args[:bin] = ARGS[i+1]; i += 2
        elseif a == "--budget"
            args[:budget] = Base.parse(Float64, ARGS[i+1]); i += 2
        elseif a == "-h" || a == "--help"
            println(stderr, read(@__FILE__, String))
            exit(0)
        else
            error("unknown argument: $a (see --help)")
        end
    end
    args
end

"""
De-normalize `~` at the start of a path back into `\$HOME`.
"""
function resolve_path(path::AbstractString)
    startswith(path, "~") ? joinpath(homedir(), path[3:end]) : path
end

function run_one(path::String, expected_sha::String, expected_pass::Bool,
                 bin::String)::NamedTuple
    resolved = resolve_path(path)
    if !isfile(resolved)
        return (status = :drift, detail = "file missing on disk")
    end
    bytes = read(resolved)
    sha = bytes2hex(sha256(bytes))
    if sha != expected_sha
        return (status = :drift, detail = "sha mismatch (baseline $(expected_sha[1:12])…, disk $(sha[1:12])…)")
    end

    code = String(bytes)
    isempty(strip(code)) && return (status = :pass, detail = "")

    ast_before = safe_parseall(code)
    ast_before === nothing && return (
        status = expected_pass ? :regression : :fail,
        detail = "JuliaSyntax can't parse original",
    )

    formatted, ok = format_code(code, bin)
    (!ok || isempty(formatted)) && return (
        status = expected_pass ? :regression : :fail,
        detail = "formatter failed",
    )

    ast_after = safe_parseall(formatted)
    ast_after === nothing && return (
        status = expected_pass ? :regression : :fail,
        detail = "JuliaSyntax can't parse formatted output",
    )

    if ast_before == ast_after
        return expected_pass ? (status = :pass, detail = "") :
                               (status = :improvement, detail = "")
    else
        diff = find_first_diff(ast_before, ast_after)
        return (
            status = expected_pass ? :regression : :fail,
            detail = diff === nothing ? "AST differs" : diff,
        )
    end
end

function main()
    args = parse_args()
    isfile(args[:bin]) || error("topiary-julia not found at $(args[:bin]) — build with `cargo build --release`")
    isfile(args[:sample]) || error("sample TOML not found at $(args[:sample])")

    data = TOML.parsefile(args[:sample])
    files = get(data, "file", Vector{Dict{String,Any}}())
    println("Smoke test: $(length(files)) files from $(relpath(args[:sample], REPO_ROOT))")
    println("Budget: $(args[:budget])s")
    println()

    t0 = time()
    regressions = Tuple{String,String}[]
    improvements = String[]
    drifts = Tuple{String,String}[]
    still_failing = Tuple{String,String}[]
    pass = 0

    for (i, f) in enumerate(files)
        elapsed = time() - t0
        if elapsed > args[:budget]
            @error "smoke test exceeded $(args[:budget])s budget" processed = i total = length(files)
            exit(2)
        end

        result = run_one(f["path"], f["sha"], f["expected_pass"], args[:bin])
        if result.status == :pass
            pass += 1
        elseif result.status == :improvement
            push!(improvements, f["path"])
        elseif result.status == :regression
            push!(regressions, (f["path"], result.detail))
        elseif result.status == :drift
            push!(drifts, (f["path"], result.detail))
        elseif result.status == :fail
            # Still failing, as expected. No action needed.
            push!(still_failing, (f["path"], result.detail))
        end

        if i % 25 == 0
            rate = i / elapsed
            eta = (length(files) - i) / rate
            print("\r  $i / $(length(files)) ($(round(rate, digits=1))/s, ETA $(round(Int, eta))s)  ")
        end
    end
    elapsed = time() - t0
    println("\r  Done. $(length(files)) files in $(round(elapsed, digits=1))s                                   ")
    println()

    println("Results")
    println("-------")
    println("  pass         : $pass")
    println("  improvements : $(length(improvements))")
    println("  drifts       : $(length(drifts))")
    println("  still failing: $(length(still_failing))  (expected_pass=false; unchanged)")
    println("  REGRESSIONS  : $(length(regressions))")

    if !isempty(improvements)
        println("\nImprovements (update sample with smoke_sample_gen.jl to reflect):")
        for p in improvements
            println("  ✓ $p")
        end
    end

    if !isempty(drifts)
        println("\nDrifts (source content changed since sample generation):")
        for (p, d) in drifts
            println("  ~ $p — $d")
        end
    end

    if !isempty(regressions)
        println("\nREGRESSIONS:")
        for (p, d) in regressions
            println("  ✗ $p")
            println("      $d")
        end
        exit(1)
    end

    exit(0)
end

main()
