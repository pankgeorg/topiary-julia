#!/usr/bin/env julia
# build_corpus.jl — Enumerate the corpus from a locked Manifest.toml.
#
#   Reads ./Manifest.toml (committed). For each package, finds its installed
#   source under ~/.julia/packages/$NAME/$HASH, walks src/**/*.jl and
#   ext/**/*.jl, classifies it into a primary family via reverse-dep tracing
#   (Pluto > MTK > JuMP > Turing > Other), and writes ./corpus.json.
#
#   The Julia stdlib is added as a separate `Stdlib` family.
#
#   Run with:  julia --project=. build_corpus.jl

using TOML
using JSON
using SHA: sha256

const CORPUS_DIR    = @__DIR__
const MANIFEST_PATH = joinpath(CORPUS_DIR, "Manifest.toml")
const OUT_PATH      = joinpath(CORPUS_DIR, "corpus.json")
const PACKAGES_DIR  = expanduser("~/.julia/packages")

# Family precedence: a package's family is the first root (in this order) that
# transitively depends on it. Keeps each file counted exactly once in the table.
const FAMILY_ROOTS = [
    ("Pluto",  "Pluto"),
    ("MTK",    "ModelingToolkit"),
    ("JuMP",   "JuMP"),
    ("Turing", "Turing"),
]

# Packages not reachable from any root fall into "Other". Stdlib goes into
# a dedicated "Stdlib" family (handled separately — stdlib packages are IN the
# manifest but their source lives under the Julia install, not ~/.julia/packages).

# ─── Manifest parsing ──────────────────────────────────────────────

"""
    load_manifest_deps() -> Dict{String, ManifestEntry}

Parse `Manifest.toml` into a dict keyed by package name. Each entry records
the package's UUID, version (if any), and direct dependency names.
"""
struct ManifestEntry
    name::String
    uuid::String
    version::Union{String, Nothing}
    git_tree_sha1::Union{String, Nothing}
    deps::Vector{String}
end

function load_manifest_deps()
    raw = TOML.parsefile(MANIFEST_PATH)
    result = Dict{String, ManifestEntry}()
    for (name, entries) in raw["deps"]
        # Manifest.toml lists each package as an array (multiple versions
        # possible in principle). We use the single entry.
        entry = entries[1]
        uuid = get(entry, "uuid", "")
        version = get(entry, "version", nothing)
        git_tree_sha1 = get(entry, "git-tree-sha1", nothing)
        deps_raw = get(entry, "deps", String[])
        # `deps` can be a list of names OR a dict (when UUID disambiguation
        # is needed). Normalize to a list of names.
        deps = if deps_raw isa Dict
            collect(keys(deps_raw))
        else
            String.(deps_raw)
        end
        result[name] = ManifestEntry(name, uuid, version, git_tree_sha1, deps)
    end
    return result
end

# ─── Reverse-dependency graph ──────────────────────────────────────

"""
    transitive_closure(manifest, root_name) -> Set{String}

Return the set of package names reachable from `root_name` (inclusive) by
following direct dependency edges.
"""
function transitive_closure(manifest::Dict{String, ManifestEntry}, root::String)
    haskey(manifest, root) || return Set{String}()
    seen = Set{String}([root])
    frontier = [root]
    while !isempty(frontier)
        pkg = pop!(frontier)
        for dep in manifest[pkg].deps
            if !(dep in seen)
                push!(seen, dep)
                push!(frontier, dep)
            end
        end
    end
    return seen
end

"""
    classify_families(manifest) -> (family_map::Dict{String,String}, transitive_of::Dict{String, Vector{String}})

Return:
- `family_map`: package name → primary family (one of "Pluto", "MTK", "JuMP",
  "Turing", or "Other"). Uses FAMILY_ROOTS precedence.
- `transitive_of`: package name → all family tags (for richer secondary analysis).
"""
function classify_families(manifest::Dict{String, ManifestEntry})
    closures = Dict{String, Set{String}}(
        family => transitive_closure(manifest, root) for (family, root) in FAMILY_ROOTS
    )
    family_map = Dict{String, String}()
    transitive_of = Dict{String, Vector{String}}()
    for (pkg, _) in manifest
        matched = String[]
        for (family, _) in FAMILY_ROOTS
            pkg in closures[family] && push!(matched, family)
        end
        primary = isempty(matched) ? "Other" : matched[1]
        family_map[pkg] = primary
        transitive_of[pkg] = isempty(matched) ? ["Other"] : matched
    end
    return family_map, transitive_of
end

# ─── Source file enumeration ───────────────────────────────────────

"""
    package_src_dir(pkg, entry) -> String | Nothing

Find `~/.julia/packages/PKG/SLUG/` from the manifest's git-tree-sha1.
The SLUG is a 10-char prefix of a fixed derivation of the sha. In practice
there's usually exactly one entry under the package directory and we just
pick it, preferring one whose Project.toml's uuid matches the manifest's.
"""
function package_install_dir(entry::ManifestEntry)
    pkg_dir = joinpath(PACKAGES_DIR, entry.name)
    isdir(pkg_dir) || return nothing
    candidates = readdir(pkg_dir)
    isempty(candidates) && return nothing

    # Prefer the entry whose Project.toml UUID matches the manifest's.
    matched = String[]
    for slug in candidates
        proj = joinpath(pkg_dir, slug, "Project.toml")
        if isfile(proj)
            try
                p = TOML.parsefile(proj)
                if get(p, "uuid", "") == entry.uuid
                    push!(matched, slug)
                end
            catch
                # Ignore unreadable Project.toml.
            end
        end
    end
    # Fall back to the first candidate with a src/ dir.
    if isempty(matched)
        for slug in candidates
            if isdir(joinpath(pkg_dir, slug, "src"))
                return joinpath(pkg_dir, slug)
            end
        end
        return nothing
    end
    return joinpath(pkg_dir, matched[1])
end

"""
    collect_jl_files(dir, subdirs=["src","ext"]) -> Vector{String}

Walk the given subdirectories and return all `.jl` files (absolute paths).
"""
function collect_jl_files(install_dir::String; subdirs = ["src", "ext"])
    files = String[]
    for sub in subdirs
        root_dir = joinpath(install_dir, sub)
        isdir(root_dir) || continue
        for (root, _, filenames) in walkdir(root_dir)
            for fn in filenames
                if endswith(fn, ".jl")
                    push!(files, joinpath(root, fn))
                end
            end
        end
    end
    sort!(files)
    return files
end

# ─── Stdlib enumeration ────────────────────────────────────────────

function stdlib_files()
    share = joinpath(Sys.BINDIR, Base.DATAROOTDIR, "julia")
    files = String[]
    for sub in ("base", "test")
        root_dir = joinpath(share, sub)
        isdir(root_dir) || continue
        for (root, _, filenames) in walkdir(root_dir)
            for fn in filenames
                endswith(fn, ".jl") || continue
                push!(files, joinpath(root, fn))
            end
        end
    end
    sort!(files)
    return files
end

# ─── Build corpus ──────────────────────────────────────────────────

function build()
    @info "Loading manifest" MANIFEST_PATH
    manifest = load_manifest_deps()
    @info "Parsed manifest" packages = length(manifest)

    family_map, transitive_of = classify_families(manifest)

    families = Dict{String, Vector{Dict{String, Any}}}(
        f => Dict{String, Any}[] for (f, _) in FAMILY_ROOTS
    )
    families["Other"] = Dict{String, Any}[]
    families["Stdlib"] = Dict{String, Any}[]

    missing_pkgs = String[]
    total_files = 0

    for (name, entry) in manifest
        install_dir = package_install_dir(entry)
        if install_dir === nothing
            # Probably a Julia stdlib (no version) or not yet installed.
            # Stdlib files are added en masse from the Julia install below.
            entry.version === nothing || push!(missing_pkgs, name)
            continue
        end

        files = collect_jl_files(install_dir)
        isempty(files) && continue
        family = family_map[name]
        for f in files
            push!(families[family], Dict(
                "path" => f,
                "pkg" => name,
                "version" => something(entry.version, ""),
                "family" => family,
                "transitive_of" => transitive_of[name],
            ))
            total_files += 1
        end
    end

    # Stdlib family (from the Julia install, not from ~/.julia/packages).
    for f in stdlib_files()
        push!(families["Stdlib"], Dict(
            "path" => f,
            "pkg" => "Julia",
            "version" => string(VERSION),
            "family" => "Stdlib",
            "transitive_of" => ["Stdlib"],
        ))
        total_files += 1
    end

    # Compute Manifest SHA for reproducibility signing.
    manifest_sha = bytes2hex(sha256(read(MANIFEST_PATH)))

    corpus = Dict(
        "julia_version" => string(VERSION),
        "manifest_sha" => manifest_sha,
        "family_order" => ["Pluto", "MTK", "JuMP", "Turing", "Stdlib", "Other"],
        "counts" => Dict(f => length(v) for (f, v) in families),
        "families" => families,
    )

    open(OUT_PATH, "w") do io
        JSON.print(io, corpus, 2)
    end

    @info "Wrote corpus" OUT_PATH total_files
    for f in ("Pluto", "MTK", "JuMP", "Turing", "Stdlib", "Other")
        @info "  $f" files = length(families[f])
    end
    if !isempty(missing_pkgs)
        @info "Packages in manifest but not found under $PACKAGES_DIR" count = length(missing_pkgs) examples = first(missing_pkgs, 5)
    end
end

build()
