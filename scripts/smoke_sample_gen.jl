#!/usr/bin/env julia
# smoke_sample_gen.jl — stratified random sampler for the real-world
# corpus smoke test.
#
# Reads `corpus/corpus.json` (produced by corpus/build_corpus.jl), draws
# a weighted random sample per family, and runs the format + JuliaSyntax
# AST-equivalence check on every sampled file so the emitted TOML is
# self-baselined. The companion `smoke_test.jl` reads this TOML and
# flags any regression (expected_pass = true → now failing) or
# improvement (expected_pass = false → now passing).
#
# Usage:
#   julia --project=corpus/minimizer scripts/smoke_sample_gen.jl \
#       [--seed 42] [--target 180] [--out <path>] \
#       [--corpus corpus/corpus.json] [--bin <topiary-julia>]

using Dates
using JSON
using Random
using SHA: sha256
using TOML

include(joinpath(@__DIR__, "_ast_check.jl"))
using .AstCheck

const REPO_ROOT = normpath(joinpath(@__DIR__, ".."))
const DEFAULT_CORPUS = joinpath(REPO_ROOT, "corpus", "corpus.json")
const DEFAULT_BIN = joinpath(REPO_ROOT, "target", "release", "topiary-julia")
const DEFAULT_OUT = joinpath(REPO_ROOT, "tests", "corpus", "smoke_sample.toml")

# Per-family sampling weights. Stdlib and MTK get extra weight per user
# request — they're the two families most worth stressing.
const DEFAULT_WEIGHTS = Dict(
    "Stdlib" => 0.25,
    "MTK"    => 0.25,
    "Pluto"  => 0.10,
    "JuMP"   => 0.10,
    "Turing" => 0.10,
    "Other"  => 0.10,
)

function normalize_origin(path::AbstractString)
    home = homedir()
    startswith(path, home) ? "~" * path[nextind(path, lastindex(home)):end] : path
end

function parse_args()
    args = Dict{Symbol,Any}(
        :seed => 42,
        :target => 180,
        :out => DEFAULT_OUT,
        :corpus => DEFAULT_CORPUS,
        :bin => DEFAULT_BIN,
    )
    i = 1
    while i <= length(ARGS)
        a = ARGS[i]
        if a == "--seed"
            args[:seed] = Base.parse(Int, ARGS[i+1]); i += 2
        elseif a == "--target"
            args[:target] = Base.parse(Int, ARGS[i+1]); i += 2
        elseif a == "--out"
            args[:out] = ARGS[i+1]; i += 2
        elseif a == "--corpus"
            args[:corpus] = ARGS[i+1]; i += 2
        elseif a == "--bin"
            args[:bin] = ARGS[i+1]; i += 2
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
Check one file: read, parse before, format, parse after, compare.
Returns (:pass | :format_error | :parse_error_before | :parse_error_after
         | :ast_mismatch, detail).
"""
function check_file(path::String, bin::String)
    code = try
        read(path, String)
    catch
        return (:read_error, "cannot read")
    end
    isempty(strip(code)) && return (:pass, "empty")

    ast_before = safe_parseall(code)
    ast_before === nothing && return (:parse_error_before, "JuliaSyntax can't parse original")

    formatted, ok = format_code(code, bin)
    (!ok || isempty(formatted)) && return (:format_error, "formatter failed")

    ast_after = safe_parseall(formatted)
    ast_after === nothing && return (:parse_error_after, "JuliaSyntax can't parse formatted output")

    if ast_before == ast_after
        return (:pass, "")
    else
        return (:ast_mismatch, find_first_diff(ast_before, ast_after))
    end
end

function sample_indices(rng, n_available::Int, n_want::Int)
    # Draw n_want indices from 1:n_available without replacement.
    n_want >= n_available && return collect(1:n_available)
    return randperm(rng, n_available)[1:n_want]
end

function main()
    args = parse_args()
    isfile(args[:bin]) || error("topiary-julia not found at $(args[:bin]) — build with `cargo build --release`")
    isfile(args[:corpus]) || error("corpus.json not found at $(args[:corpus]) — run corpus/build_corpus.jl first")

    corpus = JSON.parsefile(args[:corpus])
    families = corpus["families"]
    rng = Random.MersenneTwister(args[:seed])

    # Work out per-family target counts proportional to weights × family size,
    # then scale down if the total exceeds --target.
    planned = Dict{String,Int}()
    for (fam, entries) in families
        w = get(DEFAULT_WEIGHTS, fam, 0.10)
        planned[fam] = round(Int, w * length(entries))
    end
    total = sum(values(planned))
    if total > args[:target]
        scale = args[:target] / total
        for fam in keys(planned)
            planned[fam] = max(1, round(Int, planned[fam] * scale))
        end
    end

    println("Sampling plan (seed=$(args[:seed]), target≈$(args[:target])):")
    for fam in sort(collect(keys(families)))
        entries = families[fam]
        n_want = get(planned, fam, 0)
        println("  $fam: $n_want / $(length(entries))")
    end
    println()

    # Draw the sample. Sort each family by path first so the seed gives a
    # reproducible selection regardless of dict iteration order.
    entries = Vector{Dict{String,Any}}()
    for fam in sort(collect(keys(families)))
        fam_entries = sort(collect(families[fam]), by = e -> e["path"])
        idx = sample_indices(rng, length(fam_entries), planned[fam])
        for i in idx
            push!(entries, fam_entries[i])
        end
    end
    sort!(entries, by = e -> e["path"])
    println("Sampled $(length(entries)) files total.\n")

    # Run the baseline check on every sampled file.
    t0 = time()
    records = Vector{Dict{String,Any}}()
    pass_by_fam = Dict{String,Int}()
    fail_by_fam = Dict{String,Int}()
    for (i, e) in enumerate(entries)
        path = e["path"]
        fam = e["family"]
        if !isfile(path)
            @warn "file disappeared between build_corpus and sample_gen" path
            continue
        end
        code_bytes = read(path)
        sha = bytes2hex(sha256(code_bytes))
        category, detail = check_file(path, args[:bin])
        expected_pass = category == :pass
        expected_pass ? (pass_by_fam[fam] = get(pass_by_fam, fam, 0) + 1) :
                        (fail_by_fam[fam] = get(fail_by_fam, fam, 0) + 1)
        push!(records, Dict{String,Any}(
            "path" => normalize_origin(path),
            "family" => fam,
            "sha" => sha,
            "expected_pass" => expected_pass,
            "category" => String(category),
            "note" => String(detail),
        ))
        if i % 25 == 0
            rate = i / (time() - t0)
            eta = (length(entries) - i) / rate
            print("\r  baselined $i / $(length(entries)) ($(round(rate, digits=1))/s, ETA $(round(Int, eta))s)  ")
        end
    end
    println("\r  baselined $(length(records)) files in $(round(time() - t0, digits=1))s                          ")

    # Emit TOML. Keep `files` under a single `[[file]]` array so the
    # schema is forward-compatible with extra per-file fields.
    mkpath(dirname(args[:out]))
    open(args[:out], "w") do io
        println(io, "# Auto-generated by scripts/smoke_sample_gen.jl. Do not hand-edit.")
        println(io, "#")
        println(io, "# `scripts/smoke_test.jl` reads this file, replays the check on every")
        println(io, "# entry, and flags: regression = was expected_pass, now failing;")
        println(io, "# improvement = was failing, now passing; drift = sha changed.")
        println(io)
        meta = Dict{String,Any}(
            "seed" => args[:seed],
            "target" => args[:target],
            "generated" => Dates.format(now(), "yyyy-mm-ddTHH:MM:SS"),
            "weights" => DEFAULT_WEIGHTS,
            "pass_by_family" => pass_by_fam,
            "fail_by_family" => fail_by_fam,
        )
        TOML.print(io, Dict("meta" => meta))
        println(io)
        TOML.print(io, Dict("file" => records))
    end

    # Final summary.
    n_pass = count(r -> r["expected_pass"], records)
    n_fail = length(records) - n_pass
    println()
    println("Baseline: $n_pass pass, $n_fail fail")
    for fam in sort(collect(keys(families)))
        p = get(pass_by_fam, fam, 0)
        f = get(fail_by_fam, fam, 0)
        total = p + f
        total == 0 && continue
        pct = round(p / total * 100, digits = 1)
        println("  $fam: $p/$total pass ($pct%)")
    end
    println("\nWrote ", relpath(args[:out], REPO_ROOT))
end

main()
