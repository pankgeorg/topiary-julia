#!/usr/bin/env julia
#
# AST equivalence check using JuliaSyntax (via Meta.parseall)
#
# For every .jl file in Julia's base/ and test/ directories:
#   1. Parse with JuliaSyntax (before formatting)
#   2. Format with topiary-julia
#   3. Parse formatted code with JuliaSyntax (after formatting)
#   4. Compare ASTs (ignoring line numbers)
#
# Usage: julia scripts/julia_ast_check.jl [path/to/topiary-julia-binary]

using Dates

include("_ast_check.jl")
using .AstCheck

# ─── Configuration ───────────────────────────────────────────────

const FORMATTER = if length(ARGS) >= 1
    ARGS[1]
else
    # Try release first, then debug
    rel = joinpath(@__DIR__, "..", "target", "release", "topiary-julia")
    dbg = joinpath(@__DIR__, "..", "target", "debug", "topiary-julia")
    isfile(rel) ? rel : dbg
end

const JULIA_SHARE = joinpath(Sys.BINDIR, Base.DATAROOTDIR, "julia")
const FOLDERS = ["base", "test"]

# ─── Categories ──────────────────────────────────────────────────

struct FileResult
    path::String
    category::Symbol  # :pass, :parse_error_before, :format_error, :parse_error_after, :ast_mismatch
    detail::String
end

# ─── Main ────────────────────────────────────────────────────────

function run_check()
    # Verify formatter exists
    if !isfile(FORMATTER)
        error("Formatter not found at $FORMATTER.\nRun: cargo build --release")
    end

    # Collect all .jl files
    files = String[]
    for folder in FOLDERS
        dir = joinpath(JULIA_SHARE, folder)
        isdir(dir) || continue
        for (root, _, filenames) in walkdir(dir)
            for f in filenames
                endswith(f, ".jl") || continue
                push!(files, joinpath(root, f))
            end
        end
    end
    sort!(files)

    println("Julia AST Equivalence Check (JuliaSyntax)")
    println("==========================================")
    println("Formatter:  $FORMATTER")
    println("Source:     $JULIA_SHARE")
    println("Files:      $(length(files))")
    println()

    results = FileResult[]
    t0 = time()

    for (i, path) in enumerate(files)
        relpath_str = relpath(path, JULIA_SHARE)

        # Read file
        code = try
            read(path, String)
        catch
            push!(results, FileResult(relpath_str, :read_error, "cannot read"))
            continue
        end

        # Skip empty files
        if isempty(strip(code))
            push!(results, FileResult(relpath_str, :pass, "empty"))
            continue
        end

        # 1. Parse before formatting
        ast_before = safe_parseall(code)
        if ast_before === nothing
            push!(results, FileResult(relpath_str, :parse_error_before, "JuliaSyntax can't parse original"))
            continue
        end

        # 2. Format
        formatted, success = format_code(code, FORMATTER)
        if !success || isempty(formatted)
            push!(results, FileResult(relpath_str, :format_error, "formatter failed"))
            continue
        end

        # 3. Parse after formatting
        ast_after = safe_parseall(formatted)
        if ast_after === nothing
            push!(results, FileResult(relpath_str, :parse_error_after, "JuliaSyntax can't parse formatted output"))
            continue
        end

        # 4. Compare
        if ast_before == ast_after
            push!(results, FileResult(relpath_str, :pass, ""))
        else
            # Find first difference for debugging
            detail = find_first_diff(ast_before, ast_after)
            push!(results, FileResult(relpath_str, :ast_mismatch, detail))
        end

        # Progress
        if i % 50 == 0
            elapsed = time() - t0
            rate = i / elapsed
            eta = (length(files) - i) / rate
            print("\r  $(i)/$(length(files)) files ($(round(rate, digits=1))/s, ETA $(round(Int, eta))s)  ")
        end
    end
    println("\r  Done. $(length(files)) files in $(round(time() - t0, digits=1))s                    ")

    # ─── Report ──────────────────────────────────────────────────

    pass = count(r -> r.category == :pass, results)
    parse_before = count(r -> r.category == :parse_error_before, results)
    format_err = count(r -> r.category == :format_error, results)
    parse_after = count(r -> r.category == :parse_error_after, results)
    mismatch = count(r -> r.category == :ast_mismatch, results)
    read_err = count(r -> r.category == :read_error, results)

    testable = length(results) - parse_before - read_err
    ast_correct = pass

    println()
    println("Results")
    println("-------")
    println("Total files:              $(length(results))")
    println("  Parse error (before):   $parse_before (JuliaSyntax can't parse original)")
    println("  Read error:             $read_err")
    println("  Testable:               $testable")
    println("    Pass:                 $pass")
    println("    Format error:         $format_err")
    println("    Parse error (after):  $parse_after (formatting broke parsing)")
    println("    AST mismatch:         $mismatch (formatting changed AST)")
    if testable > 0
        pct = round(ast_correct / testable * 100, digits=2)
        println()
        println("AST preservation rate:    $ast_correct/$testable ($pct%)")
    end

    # Show failures
    if format_err > 0
        println("\n--- Format errors (all) ---")
        for r in filter(r -> r.category == :format_error, results)
            println("  $(r.path)")
        end
    end

    if parse_after > 0
        println("\n--- Parse errors after formatting (all) ---")
        for r in filter(r -> r.category == :parse_error_after, results)
            println("  $(r.path): $(r.detail)")
        end
    end

    if mismatch > 0
        println("\n--- AST mismatches (all) ---")
        for r in filter(r -> r.category == :ast_mismatch, results)
            println("  $(r.path): $(r.detail)")
        end
    end

    return results
end

# ─── Run ─────────────────────────────────────────────────────────

results = run_check()
