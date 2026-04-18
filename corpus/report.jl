#!/usr/bin/env julia
# report.jl — Aggregate `results/metrics.jsonl` into a human-readable report.
#
# Produces:
#   results/report.md       — per-family table + impact-sorted failure buckets
#   results/failures/       — per-file failure summaries by category

using JSON
using Printf

const CORPUS_DIR  = @__DIR__
const METRICS     = joinpath(CORPUS_DIR, "results", "metrics.jsonl")
const REPORT_MD   = joinpath(CORPUS_DIR, "results", "report.md")
const FAILURES    = joinpath(CORPUS_DIR, "results", "failures")

const FAMILY_ORDER = ["Pluto", "MTK", "JuMP", "Turing", "Stdlib", "Other"]

function read_rows()
    rows = Dict{String, Any}[]
    meta = Dict{String, Any}()
    for line in eachline(METRICS)
        isempty(line) && continue
        row = JSON.parse(line)
        if get(row, "_meta", false) === true
            meta = row
        else
            push!(rows, row)
        end
    end
    return meta, rows
end

# ─── Bucketing ─────────────────────────────────────────────────────

"""
Normalize a `structure_failure` / `roundtrip_failure` string to a stable
bucket key for sorting & grouping. Keeps the semantic prefix (no_translation_rule,
rule_output_mismatch, etc.) and shortens the detail to its first token.
"""
function bucket_key(failure::AbstractString)
    if startswith(failure, "no_translation_rule:")
        return failure  # kind is enough of a key
    elseif startswith(failure, "rule_output_mismatch:")
        # First node kind in the mismatch window gives a useful bucket.
        tail = failure[22:end]
        # Look for the first `(name` token.
        m = match(r"\(([A-Za-z_][A-Za-z0-9_\-:.]*)", tail)
        if m === nothing
            return "rule_output_mismatch:?"
        end
        return "rule_output_mismatch:$(m.captures[1])"
    elseif startswith(failure, "sexp_reader_error") ||
           startswith(failure, "translator_exception:") ||
           failure == "ts_parse_error" ||
           failure == "js_parse_error" ||
           failure == "format_failed" ||
           failure == "parse_failed"
        return failure
    elseif startswith(failure, "diff@")
        # round-trip first-diff markers. Bucket by the JuliaSyntax head right
        # before the diff point.
        m = match(r"\(([A-Za-z_][A-Za-z0-9_\-:.]*)[^)]*$", failure)
        return m === nothing ? "diff:?" : "roundtrip_diff:$(m.captures[1])"
    else
        return failure
    end
end

# ─── Family aggregation ────────────────────────────────────────────

struct FamilySummary
    name::String
    count::Int
    parse_ok::Int
    roundtrip_ok::Int
    structure_match::Int
end

function family_summaries(rows)
    groups = Dict{String, Vector{Any}}()
    for r in rows
        fam = get(r, "family", "Other")
        push!(get!(groups, fam, []), r)
    end
    summaries = FamilySummary[]
    for fam in FAMILY_ORDER
        rs = get(groups, fam, [])
        isempty(rs) && continue
        push!(summaries, FamilySummary(
            fam, length(rs),
            count(r -> get(r, "parse_ok", false), rs),
            count(r -> get(r, "roundtrip_ok", false), rs),
            count(r -> get(r, "structure_match", false), rs),
        ))
    end
    # Total row.
    push!(summaries, FamilySummary(
        "All", length(rows),
        count(r -> get(r, "parse_ok", false), rows),
        count(r -> get(r, "roundtrip_ok", false), rows),
        count(r -> get(r, "structure_match", false), rows),
    ))
    return summaries
end

pct(num::Int, denom::Int) = denom == 0 ? "n/a" : @sprintf("%.1f%%", 100 * num / denom)

# ─── Bucket aggregation ────────────────────────────────────────────

function bucket_failures(rows)
    # Return Dict{bucket => (kind, count, family_counts)} where kind is
    # "parse"/"roundtrip"/"structure".
    buckets = Dict{Tuple{String, String}, Dict{String, Any}}()  # (kind, bucket) => info

    function inc!(kind::String, key::String, fam::String)
        k = (kind, key)
        b = get!(buckets, k, Dict{String, Any}("count" => 0, "families" => Dict{String, Int}()))
        b["count"] += 1
        b["families"][fam] = get(b["families"], fam, 0) + 1
    end

    for r in rows
        fam = get(r, "family", "Other")
        if !get(r, "parse_ok", false)
            inc!("parse", "parse_failed", fam)
        end
        if !get(r, "roundtrip_ok", false)
            inc!("roundtrip", bucket_key(get(r, "roundtrip_failure", "?")), fam)
        end
        if !get(r, "structure_match", false)
            inc!("structure", bucket_key(get(r, "structure_failure", "?")), fam)
        end
    end
    return buckets
end

# ─── Report rendering ──────────────────────────────────────────────

function render_report(io::IO, meta, rows)
    println(io, "# topiary-julia corpus coverage report")
    println(io)
    jv  = get(meta, "julia_version", "?")
    sha = get(meta, "manifest_sha", "?")
    tot = length(rows)
    ts  = get(meta, "timestamp", "?")
    println(io, "_Julia $jv · Manifest $(first(sha, 12))… · $tot files · run $(ts)_")
    println(io)

    # Family table.
    println(io, "## Family summary")
    println(io)
    println(io, "| Family  |  Files | Parse OK | Roundtrip OK | Structure Match |")
    println(io, "|---------|-------:|---------:|-------------:|----------------:|")
    for f in family_summaries(rows)
        fam = f.name == "All" ? "**All**" : f.name
        println(io, "| $fam | $(f.count) | $(pct(f.parse_ok, f.count)) | $(pct(f.roundtrip_ok, f.count)) | $(pct(f.structure_match, f.count)) |")
    end
    println(io)

    # Failure buckets sorted by impact.
    println(io, "## Failure buckets (sorted by impact)")
    println(io)
    buckets = bucket_failures(rows)
    ordered = sort(collect(buckets), by=kv -> -kv[2]["count"])
    println(io, "| # | Kind | Bucket | Count | Top families |")
    println(io, "|--:|------|--------|------:|--------------|")
    for (rank, ((kind, key), info)) in enumerate(ordered)
        fams = sort(collect(info["families"]), by = kv -> -kv[2])
        fam_str = join(["$(k)=$(v)" for (k, v) in first(fams, 3)], ", ")
        println(io, "| $rank | $kind | `$key` | $(info["count"]) | $fam_str |")
    end
    println(io)

    println(io, "See `results/failures/{parse,roundtrip,structure}/<bucket>/*` for per-file diffs.")
end

# ─── Per-file failure dumps ────────────────────────────────────────

function sanitize(s::AbstractString)
    replace(String(s), r"[^A-Za-z0-9_\-:.]+" => "_")
end

function dump_failures(rows)
    isdir(FAILURES) && rm(FAILURES; recursive=true)
    mkpath(FAILURES)

    function dump_one(kind::String, bucket::String, row, extra::String)
        dir = joinpath(FAILURES, kind, sanitize(bucket))
        mkpath(dir)
        path_tag = replace(row["path"], "/" => "_")
        fname = sanitize(path_tag)
        open(joinpath(dir, fname * ".txt"), "w") do io
            println(io, "file:      ", row["path"])
            println(io, "family:    ", row["family"])
            println(io, "package:   ", row["pkg"], " ", row["version"])
            println(io, "kind:      ", kind)
            println(io, "bucket:    ", bucket)
            println(io)
            println(io, extra)
        end
    end

    for r in rows
        fam = r["family"]
        if !get(r, "parse_ok", false)
            dump_one("parse", "parse_failed", r, "")
        end
        if !get(r, "roundtrip_ok", false)
            key = bucket_key(get(r, "roundtrip_failure", "?"))
            dump_one("roundtrip", key, r, "failure: " * get(r, "roundtrip_failure", "?"))
        end
        if !get(r, "structure_match", false)
            key = bucket_key(get(r, "structure_failure", "?"))
            dump_one("structure", key, r, "failure: " * get(r, "structure_failure", "?"))
        end
    end
end

function main()
    isfile(METRICS) || error("Missing $METRICS — run run_checks.jl first")
    meta, rows = read_rows()
    isempty(rows) && error("No data rows in $METRICS")

    # Summary report.
    open(REPORT_MD, "w") do io
        render_report(io, meta, rows)
    end
    @info "Wrote report" REPORT_MD rows=length(rows)

    # Per-file failure dumps (sampling by bucket so we don't make 10k files).
    dump_failures(rows)
    @info "Dumped failures" FAILURES

    # Echo summary to stdout.
    print(stdout, read(REPORT_MD, String))
end

main()
