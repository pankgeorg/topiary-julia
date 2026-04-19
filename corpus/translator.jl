#!/usr/bin/env julia
# translator.jl — Translate tree-sitter-julia CST sexp → JuliaSyntax AST sexp.
#
# Input  (from `topiary-julia parse`):
#   (source_file (assignment (identifier "x") (operator "=") (integer_literal "1")))
#
# Output  (matches JuliaSyntax's `MIME"text/x.sexpression"` form):
#   (toplevel (= x 1))
#
# The goal is structural equivalence: running both translators on the same
# source should produce the same string. Mismatches fall into three buckets
# that the driver can bucket by `root_cause`:
#
#   1. `no_translation_rule:<kind>` — this tree-sitter node kind isn't mapped
#      yet. The rule for it needs to be written.
#   2. `rule_output_mismatch:<rule>:<detail>` — the rule fired but the output
#      shape still diverges from JuliaSyntax's.
#   3. `sexp_parse_error` — the sexp input couldn't be read.

module Translator

using JuliaSyntax: JuliaSyntax

export Node, parse_sexp, translate, write_sexp, sexp_string

# ─── Tree data structure ───────────────────────────────────────────

"""
    Node(kind, text, children)

A plain sexp-tree node. `text` holds the literal string for leaf nodes
(emitted by tree-sitter for identifier/operator/integer_literal/etc.), or
`nothing` otherwise.
"""
mutable struct Node
    kind::String
    text::Union{String, Nothing}   # `nothing` if not a text leaf
    children::Vector{Node}
end
Node(kind::AbstractString) = Node(String(kind), nothing, Node[])
Node(kind::AbstractString, text::AbstractString) = Node(String(kind), String(text), Node[])

# ─── Sexp reader ────────────────────────────────────────────────────
#
# Grammar:
#   node  := '(' kind (SPACE text-or-kind-rest)* ')'
#   kind  := [A-Za-z_][A-Za-z0-9_-]*  |  operator-literal
#   text  := '"' escaped '"'  (double-quoted with \\ and \" escapes)
# We also tolerate bare "-" prefix in JuliaSyntax kinds (e.g. "quote-:", ".=", "||").

function parse_sexp(s::AbstractString)
    idx = Ref(1)
    skip_ws!(s, idx)
    node = _read_node(s, idx)
    skip_ws!(s, idx)
    idx[] <= lastindex(s) && @warn "Trailing input after sexp at index $(idx[])"
    return node
end

@inline function skip_ws!(s::AbstractString, idx::Ref{Int})
    while idx[] <= lastindex(s) && isspace(s[idx[]])
        idx[] = nextind(s, idx[])
    end
end

function _read_node(s::AbstractString, idx::Ref{Int})
    idx[] <= lastindex(s) || error("Unexpected end of input")
    c = s[idx[]]
    if c != '('
        error("Expected '(' at index $(idx[]), got $(repr(c))")
    end
    idx[] = nextind(s, idx[])
    skip_ws!(s, idx)
    kind = _read_atom(s, idx)
    node = Node(kind)
    skip_ws!(s, idx)
    while idx[] <= lastindex(s) && s[idx[]] != ')'
        if s[idx[]] == '('
            push!(node.children, _read_node(s, idx))
        elseif s[idx[]] == '"'
            # Text leaf (identifier/operator text, integer text, etc.)
            txt = _read_string(s, idx)
            # Multiple text atoms within one node shouldn't happen from the
            # tree-sitter helper, but if they do, concatenate with space.
            node.text = node.text === nothing ? txt : string(node.text, " ", txt)
        else
            # Bare atom — treat as an unnamed child node with just a kind.
            atom = _read_atom(s, idx)
            push!(node.children, Node(atom))
        end
        skip_ws!(s, idx)
    end
    idx[] <= lastindex(s) || error("Missing ')' for node $(kind)")
    idx[] = nextind(s, idx[])  # consume ')'
    return node
end

const ATOM_STOPS = Set{Char}([' ', '\t', '\n', '\r', '(', ')'])

function _read_atom(s::AbstractString, idx::Ref{Int})
    start = idx[]
    while idx[] <= lastindex(s)
        c = s[idx[]]
        (c in ATOM_STOPS) && break
        idx[] = nextind(s, idx[])
    end
    return String(SubString(s, start, prevind(s, idx[])))
end

function _read_string(s::AbstractString, idx::Ref{Int})
    s[idx[]] == '"' || error("Expected '\"' at $(idx[])")
    idx[] = nextind(s, idx[])
    out = IOBuffer()
    while idx[] <= lastindex(s)
        c = s[idx[]]
        if c == '"'
            idx[] = nextind(s, idx[])
            return String(take!(out))
        elseif c == '\\'
            idx[] = nextind(s, idx[])
            next = s[idx[]]
            if next == '"' || next == '\\'
                write(out, next)
            elseif next == 'n'
                write(out, '\n')
            elseif next == 't'
                write(out, '\t')
            elseif next == 'r'
                write(out, '\r')
            else
                # Leave unknown escapes as-is (rare).
                write(out, '\\', next)
            end
            idx[] = nextind(s, idx[])
        else
            write(out, c)
            idx[] = nextind(s, idx[])
        end
    end
    error("Unterminated string literal")
end

# ─── Sexp writer ────────────────────────────────────────────────────

"""
    sexp_string(node) -> String

Render a Node tree in the same format JuliaSyntax's MIME"text/x.sexpression"
uses: `(head child1 child2 ...)` with leaves as bare text tokens.
"""
function sexp_string(node::Node)
    buf = IOBuffer()
    write_sexp(buf, node)
    return String(take!(buf))
end

function write_sexp(io::IO, node::Node)
    if node.text !== nothing && isempty(node.children)
        # Leaf: emit the text verbatim (matches JuliaSyntax which prints the
        # numeric value, identifier name, operator, etc. as bare tokens).
        write(io, node.text)
        return
    end
    write(io, '(', node.kind)
    for c in node.children
        write(io, ' ')
        write_sexp(io, c)
    end
    write(io, ')')
end

# ─── Translation rules ─────────────────────────────────────────────

"""
    translate(ts_node) -> Node

Walk a tree-sitter CST (rooted at `source_file`) and return a Node tree in
JuliaSyntax's sexp convention.

Unknown kinds produce a `no_translation_rule:<kind>` marker node so the
driver can bucket them.
"""
function translate(n::Node)::Node
    rule = get(RULES, n.kind, nothing)
    rule === nothing && return Node("no_translation_rule:$(n.kind)")
    return rule(n)
end

tr(n::Node) = translate(n)
trs(ns) = [translate(c) for c in ns]

# Helpers

function leaf(kind::String, text::AbstractString)
    Node(kind, String(text))
end

"Bare-kind leaf with no text (used for JuliaSyntax tokens like `:` in call-i)."
tok(k::AbstractString) = Node(String(k))

"Literal text token (for tokens like `1`, `x`, `+`, `:`)."
literal(t::AbstractString) = Node("", String(t))

function _child_by_kind(n::Node, kinds...)::Union{Node, Nothing}
    for c in n.children
        c.kind in kinds && return c
    end
    return nothing
end

function _children_of(n::Node, kind::String)::Vector{Node}
    filter(c -> c.kind == kind, n.children)
end

"Unwrap parenthesized_expression if it has a single child."
function _unwrap_parens(n::Node)
    if n.kind == "parenthesized_expression" && length(n.children) == 1
        return n.children[1]
    end
    return n
end

# Some tree-sitter node kinds are purely structural wrappers (comments,
# whitespace). When flattening we drop them.
const TRIVIA_KINDS = Set(["line_comment", "block_comment"])

# Pseudo-children emitted by `topiary-julia parse` to surface semantics the
# CST would otherwise hide (`mutable` keyword on struct, trailing comma on
# argument/tuple/vector lists, triple-quoted string marker).
const MARKER_KINDS = Set(["trailing_comma", "triple_quote", "triple_backtick", "relative_dot", "parameters_separator", "fold_sign", "matrix_semicolon", "blank_after", "raw_content"])

function _non_trivia(ns::Vector{Node})
    [c for c in ns if !(c.kind in TRIVIA_KINDS) && !(c.kind in MARKER_KINDS)]
end

function _has_marker(n::Node, marker::String)
    any(c -> c.kind == marker, n.children)
end

# Source-level node kinds that a leading docstring binds to. A preceding
# `string_literal` / `prefixed_string_literal` followed by one of these is
# rewritten into `(doc <string> <definition>)` at translate time.
const DOCSTRING_TARGET_KINDS = Set([
    "function_definition",
    "short_function_definition",
    "macro_definition",
    "struct_definition",
    "abstract_definition",
    "primitive_definition",
    "module_definition",
    "assignment",
    "const_statement",
    "macrocall_expression",
    "global_statement",
    "local_statement",
])

function _is_docstring_source(c::Node)
    c.kind == "string_literal" || c.kind == "prefixed_string_literal"
end

"Rewrite consecutive `(docstring, expression)` pairs into `(doc docstring expression)`.
JuliaSyntax only wraps when the string is immediately followed by an expression —
a blank line between them (detected via the Rust-side `(blank_after)` marker)
leaves the string standalone."
function _wrap_docstrings(kids::Vector{Node})::Vector{Node}
    out = Node[]
    i = 1
    n = length(kids)
    while i <= n
        c = kids[i]
        if _is_docstring_source(c) && !_has_marker(c, "blank_after") &&
           i < n && !_is_docstring_source(kids[i+1])
            doc = Node("doc")
            push!(doc.children, translate(c))
            push!(doc.children, translate(kids[i+1]))
            push!(out, doc)
            i += 2
        else
            push!(out, translate(c))
            i += 1
        end
    end
    return out
end

# ─── Individual rules ──────────────────────────────────────────────

const RULES = Dict{String, Function}()

# Top-level
RULES["source_file"] = function (n)
    r = Node("toplevel")
    for c in _wrap_docstrings(_non_trivia(n.children))
        push!(r.children, c)
    end
    return r
end

# Text leaves — emit as bare tokens. JuliaSyntax prints numeric literals,
# identifiers, booleans, and operators without any node wrapper.
function _leaf_rule(kind::String)
    return function (n::Node)
        # tree-sitter stores text on these leaves. Emit a literal with the
        # verbatim source text.
        return literal(n.text === nothing ? "" : n.text)
    end
end

# JuliaSyntax normalizes identifiers via NFC + a few Latin-lookalike mappings
# (e.g. `ɛ` U+025B → `ε` U+03B5). Use the same normalization so structure
# match compares semantically-equal identifiers.
function _normalize_identifier_text(text::String)::String
    try
        JuliaSyntax.normalize_identifier(text)
    catch
        text
    end
end

RULES["identifier"] = function (n::Node)
    text = n.text === nothing ? "" : n.text
    literal(_normalize_identifier_text(text))
end
RULES["var_identifier"]   = _leaf_rule("var_identifier")
RULES["boolean_literal"]  = _leaf_rule("boolean_literal")
RULES["operator"]         = _leaf_rule("operator")

# Numeric literals — JuliaSyntax shows integer/float values via their `show`
# form, which normalizes binary (`0b01`→`0x01`) and some float patterns.
# Mimic by parsing with Base.Meta.parse and re-showing.
function _normalize_numeric(text::String)::String
    v = try
        Base.Meta.parse(text)
    catch
        return text
    end
    v isa Number || return text
    buf = IOBuffer()
    show(buf, v)
    return String(take!(buf))
end
RULES["integer_literal"] = function (n)
    literal(n.text === nothing ? "" : _normalize_numeric(n.text))
end
RULES["float_literal"] = function (n)
    literal(n.text === nothing ? "" : _normalize_numeric(n.text))
end
# character_literal has its source text with the surrounding quotes: `'a'`.
# JuliaSyntax wraps character literals in `(char 'a')` and normalizes common
# control-char escapes (`'\u0c'` → `'\f'`, `'\u0a'` → `'\n'`, etc.) to match
# Julia's canonical character-print form.
RULES["character_literal"] = function (n)
    r = Node("char")
    text = n.text === nothing ? "" : n.text
    # Try to parse + re-emit through Julia's show; fall back on failure.
    try
        # Strip the surrounding single quotes and unescape to a Char.
        inner = _decode_tsstr(text[2:end-1])
        if length(inner) == 1
            buf = IOBuffer()
            show(buf, first(inner))
            text = String(take!(buf))
        end
    catch
        # keep original text
    end
    push!(r.children, literal(text))
    return r
end

# String / command literals

"Decode a tree-sitter `content` or `escape_sequence` text into the raw string
value (no surrounding quotes; `\\n` becomes a newline, etc.). Accepts
Julia-specific escapes that `unescape_string` rejects (e.g. `\\\$`)."
function _decode_tsstr(s::AbstractString)::String
    try
        return unescape_string(s)
    catch
        # Fallback: handle Julia's string-specific escapes (`\\\$`, `\\\"`).
        buf = IOBuffer()
        i = 1
        while i <= lastindex(s)
            c = s[i]
            if c == '\\' && i < lastindex(s)
                nx = s[nextind(s, i)]
                if nx == '\$' || nx == '"' || nx == '\\' || nx == '`'
                    write(buf, nx)
                    i = nextind(s, nextind(s, i))
                    continue
                end
                # Try unescape on this single pair; if that fails, pass raw.
                pair = s[i:nextind(s, i)]
                try
                    write(buf, unescape_string(pair))
                    i = nextind(s, nextind(s, i))
                    continue
                catch
                    write(buf, c)
                    i = nextind(s, i)
                    continue
                end
            end
            write(buf, c)
            i = nextind(s, i)
        end
        return String(take!(buf))
    end
end

"""Longest shared leading-whitespace prefix (spaces/tabs only) of two strings."""
function _common_prefix_ws(a::String, b::String)::String
    len = min(sizeof(a), sizeof(b))
    i = 1
    out = IOBuffer()
    while i <= len
        ca = a[i]; cb = b[i]
        if ca == cb && (ca == ' ' || ca == '\t')
            write(out, ca)
            i += 1
        else
            break
        end
    end
    String(take!(out))
end

"""Return the de-indent string for a triple-quoted string — the common
leading-whitespace prefix of every non-blank line *after* the first line
(the first line is exempt because it shares its source line with the
opening `\"\"\"` and therefore has no meaningful leading whitespace).
A line is "blank" if it has no non-whitespace content — such lines don't
constrain the prefix either."""
function _common_triple_indent(pieces::Vector{Any})::String
    # Determine if the string opens with a newline (so the "first line"
    # is empty and we should count the line right after the \n).
    opens_with_nl = !isempty(pieces) && pieces[1] isa String &&
                    !isempty(pieces[1]::String) && (pieces[1]::String)[1] == '\n'

    line_starts = String[]
    current_ws = IOBuffer()
    at_line_start = true
    line_has_content = false
    line_index = 1
    function finish_line!(is_final::Bool=false)
        skip_this = line_index == 1 && !opens_with_nl
        if !skip_this && (line_has_content || is_final)
            # The "final" line (right before the closing `"""`) constrains
            # the indent even when it has only whitespace — that's the
            # indentation of the closer.
            push!(line_starts, String(take!(current_ws)))
        else
            take!(current_ws)
        end
        line_has_content = false
        at_line_start = true
        line_index += 1
    end
    for p in pieces
        if p isa String
            s = p::String
            j = 1
            while j <= lastindex(s)
                c = s[j]
                if c == '\n'
                    finish_line!()
                    j = nextind(s, j)
                    continue
                end
                if at_line_start && (c == ' ' || c == '\t')
                    write(current_ws, c)
                    j = nextind(s, j)
                    continue
                end
                at_line_start = false
                line_has_content = true
                j = nextind(s, j)
            end
        else
            at_line_start = false
            line_has_content = true
        end
    end
    finish_line!(true)

    isempty(line_starts) && return ""
    result = line_starts[1]
    for ws in line_starts[2:end]
        result = _common_prefix_ws(result, ws)
        isempty(result) && return ""
    end
    return result
end

"""
Split a triple-quoted string's concatenated content + interpolation stream
the way JuliaSyntax does: strip the leading `\\n`, compute the closing
indent (the whitespace after the last `\\n`), strip that prefix from every
line, and split at `\\n` into per-line text children. Interpolations are
preserved in place as opaque `nothing` markers to slot back after splitting.
"""
function _split_triple(pieces::Vector{Any})::Vector{Any}
    # pieces: Vector of either String (text) or Any (interpolation sentinel)
    # returns a Vector of either String (line segment) or interpolation sentinel.
    isempty(pieces) && return Any[]

    # Compute the common leading-whitespace indent across all non-empty
    # text lines. Julia's documented triple-string de-indent rule: strip the
    # longest shared prefix of spaces/tabs from every line, including the
    # (possibly empty) line that precedes the closing `"""`. Computed on the
    # *original* pieces — before we strip any leading `\n`, since the first
    # source line's treatment depends on whether `"""` had content immediately
    # after it.
    indent = _common_triple_indent(pieces)
    # Drop the closing-line indent from the end of the last string piece
    # (if the string ends with `\n<whitespace>`), so the split step doesn't
    # emit a dangling whitespace-only segment.
    if pieces[end] isa String
        last = pieces[end]::String
        nl = findlast('\n', last)
        if nl !== nothing
            tail = SubString(last, nextind(last, nl), lastindex(last))
            if all(c -> c == ' ' || c == '\t', tail)
                pieces[end] = String(SubString(last, 1, nl))
            end
        end
    end

    # Strip `indent` from each line's leading position within string pieces.
    # A "line start" is right after a `\n` (or at the very start of the stream
    # iff the string opens with `\n` — the first source line after `"""` on
    # the opener stays verbatim).
    if !isempty(indent)
        opens_with_nl = !isempty(pieces) && pieces[1] isa String &&
                        !isempty(pieces[1]::String) && (pieces[1]::String)[1] == '\n'
        at_line_start = opens_with_nl  # true only if the first "line" was empty
        # Skip the first line if it's on the opener line.
        first_line_done = opens_with_nl
        for i in eachindex(pieces)
            if pieces[i] === :continuation_boundary
                # `\<newline>` continuation: the following piece starts on a
                # fresh source line and gets its indent stripped.
                at_line_start = true
                first_line_done = true
                continue
            elseif pieces[i] isa String
                s = pieces[i]::String
                buf = IOBuffer()
                j = 1
                while j <= lastindex(s)
                    if at_line_start && first_line_done &&
                       startswith(SubString(s, j, lastindex(s)), indent)
                        j += sizeof(indent)
                        at_line_start = false
                        continue
                    end
                    c = s[j]
                    write(buf, c)
                    at_line_start = (c == '\n')
                    if c == '\n'
                        first_line_done = true
                    end
                    j = nextind(s, j)
                end
                pieces[i] = String(take!(buf))
            else
                at_line_start = false
            end
        end
    end

    # Strip the leading `\n` from the first piece, *after* indent-stripping.
    # Deferring this means the first source line (right after the opening
    # `"""`) was correctly treated as blank by the indent-strip above.
    if pieces[1] isa String
        s = pieces[1]::String
        if !isempty(s) && s[1] == '\n'
            pieces[1] = s[nextind(s, 1):end]
        end
    end

    # Split each text piece at `\n` (keeping `\n` attached to the preceding
    # segment). Interpolations pass through unchanged.
    out = Any[]
    for p in pieces
        if p === :continuation_boundary
            # Boundary marker — drop, it has already served its purpose in
            # the indent-strip pass above.
            continue
        elseif p isa String
            s = p::String
            start = 1
            while start <= lastindex(s)
                nl = findnext('\n', s, start)
                if nl === nothing
                    push!(out, String(SubString(s, start, lastindex(s))))
                    break
                end
                push!(out, String(SubString(s, start, nl)))
                start = nextind(s, nl)
            end
        else
            push!(out, p)
        end
    end
    # Drop empty-string segments (JuliaSyntax omits them).
    return Any[p for p in out if !(p isa String && isempty(p))]
end

function _string_children!(r::Translator.Node, kids::Vector{Translator.Node};
                            triple::Bool=false)
    # Walk kids; merge consecutive content/escape into one literal; inline
    # interpolation_expression as separate children. Triple-quoted strings
    # get additional JuliaSyntax post-processing: leading-newline strip,
    # closing-indent strip, and per-line splitting.
    pieces = Any[]            # Vector of (String | interp_sentinel)
    buf = IOBuffer()
    had_text = false
    # Interpolation children are translated lazily; stash them into an
    # index array so we can re-materialize them after the split step.
    interps = Vector{Node}[]
    function flush!()
        if had_text
            push!(pieces, String(take!(buf)))
            had_text = false
        end
    end
    INTERP = :interp
    # Triple-quoted strings split on source-level `\n` but NOT on escape-
    # derived `\n` (from `\n`, `\r\n`, etc. in the source). Track which
    # newlines come from escape_sequence so we can protect them from the
    # splitter. We temporarily replace them with U+001E and restore after.
    ESCAPE_NL = "\x1e"
    for c in kids
        if c.kind == "content"
            text = c.text === nothing ? "" : _decode_tsstr(c.text)
            write(buf, text)
            had_text = true
        elseif c.kind == "escape_sequence"
            text = c.text === nothing ? "" : _decode_tsstr(c.text)
            if triple && (text == "\\\n" || text == "\\\r\n")
                # Line-continuation escape `\<newline>`. JuliaSyntax splits
                # the string at this boundary and strips the continuation
                # line's indent. Push a `:continuation_boundary` sentinel;
                # `_split_triple` recognises it to reset at_line_start for
                # the next piece's indent strip, then drops it.
                flush!()
                push!(pieces, :continuation_boundary)
                continue
            elseif triple && ('\n' in text || '\r' in text)
                # Protect other escape-derived newlines (literal `\n`, `\r\n`,
                # etc.) from the triple-string line-splitter.
                text = replace(text, "\n" => ESCAPE_NL, "\r" => "\r")
            end
            write(buf, text)
            had_text = true
        elseif c.kind == "string_interpolation"
            flush!()
            inner = translate(c)
            # Inner's kind is `$`; JuliaSyntax inlines its children directly.
            push!(interps, inner.children)
            push!(pieces, INTERP)
        else
            flush!()
            inner = translate(c)
            push!(interps, [inner])
            push!(pieces, INTERP)
        end
    end
    flush!()

    if triple
        pieces = _split_triple(pieces)
    end

    # Materialize pieces to child nodes. Interpolations drain from the
    # front of `interps`. Restore escape-derived `\n` (temporarily encoded
    # as U+001E) to a real `\n` so the emitted text matches the source.
    for p in pieces
        if p isa String
            text = triple ? replace(p, ESCAPE_NL => "\n") : p
            push!(r.children, literal(repr(text)))
        else
            ics = popfirst!(interps)
            for ic in ics
                push!(r.children, ic)
            end
        end
    end
end

"Detect triple-quoted / triple-backticked string via the alias child emitted by tree-sitter-julia."
function _is_triple_string(n::Node)
    any(c -> c.kind == "triple_quote" || c.kind == "triple_backtick", n.children)
end

RULES["string_literal"] = function (n)
    triple = _is_triple_string(n)
    r = Node(triple ? "string-s" : "string")
    _string_children!(r, _non_trivia(n.children); triple=triple)
    # JuliaSyntax always includes at least one text child, even for `""`.
    isempty(r.children) && push!(r.children, literal("\"\""))
    return r
end

RULES["string_interpolation"] = function (n)
    # JuliaSyntax emits `($ x)` for interpolation.
    r = Node("\$")
    for c in _non_trivia(n.children)
        push!(r.children, translate(c))
    end
    return r
end

RULES["prefixed_string_literal"] = function (n)
    # JuliaSyntax: (macrocall @PREFIX_str (string-r "content")) for user
    # macros. The `var"…"` form is special — JuliaSyntax renders it as
    # `(var NAME)` with the interior treated as an identifier.
    prefix = _child_by_kind(n, "identifier")
    prefix_name = prefix === nothing ? "?" : (prefix.text === nothing ? "?" : prefix.text)
    triple = _is_triple_string(n)
    if prefix_name == "var"
        r = Node("var")
        # Concatenate all content/escape_sequence text into a single name.
        buf = IOBuffer()
        for c in _non_trivia(n.children)
            c === prefix && continue
            if c.kind == "content" || c.kind == "escape_sequence"
                write(buf, c.text === nothing ? "" : c.text)
            end
        end
        push!(r.children, literal(String(take!(buf))))
        return r
    end
    r = Node("macrocall")
    push!(r.children, literal("@" * prefix_name * "_str"))
    inner = Node(triple ? "string-s-r" : "string-r")
    text_buf = IOBuffer()
    had_text = false
    for c in _non_trivia(n.children)
        c === prefix && continue
        if c.kind == "content"
            write(text_buf, c.text === nothing ? "" : c.text)
            had_text = true
        elseif c.kind == "escape_sequence"
            write(text_buf, c.text === nothing ? "" : c.text)
            had_text = true
        end
    end
    if had_text
        raw_bytes = take!(text_buf)
        # Apply JuliaSyntax's raw-string escape processing: halve backslash
        # runs that end at the string delimiter, convert \r/\r\n to \n, etc.
        out_io = IOBuffer()
        JuliaSyntax.unescape_raw_string(out_io, raw_bytes, 1, length(raw_bytes) + 1, false)
        s = String(take!(out_io))
        if triple
            # Apply the same indent-strip + line-split JuliaSyntax uses for
            # triple-quoted strings, then emit each line as a separate child.
            pieces = _split_triple(Any[s])
            for p in pieces
                if p isa String
                    push!(inner.children, literal(repr(p)))
                end
            end
        else
            push!(inner.children, literal(repr(s)))
        end
    end
    push!(r.children, inner)
    # Regex flag suffix: `r"abc"i` has a trailing `identifier "i"` child in
    # tree-sitter. JuliaSyntax exposes it as an extra string child of the
    # macrocall: `(macrocall @r_str (string-r "abc") "i")`.
    kids_all = _non_trivia(n.children)
    idents = filter(c -> c.kind == "identifier", kids_all)
    if length(idents) >= 2
        # First identifier is the prefix; any others are flag suffixes.
        for flag in idents[2:end]
            push!(r.children, literal(repr(flag.text === nothing ? "" : flag.text)))
        end
    end
    return r
end

RULES["command_literal"] = function (n)
    triple = _is_triple_string(n)
    r = Node(triple ? "cmdstring-s-r" : "cmdstring-r")
    # Prefer the `(raw_content "…")` child injected by the Rust side — it
    # preserves interpolation source (`$x`, `$(f(y))`) as literal text,
    # matching JuliaSyntax's cmdstring-r convention.
    raw = _child_by_kind(n, "raw_content")
    if raw !== nothing
        s = raw.text === nothing ? "" : raw.text
        if triple && !isempty(s) && s[1] == '\n'
            s = s[nextind(s, 1):end]
        end
        push!(r.children, literal(repr(s)))
        return r
    end
    # Fallback: concatenate content/escape pieces.
    text_buf = IOBuffer()
    had_text = false
    for c in _non_trivia(n.children)
        c.kind in ("content", "escape_sequence") || continue
        write(text_buf, c.text === nothing ? "" : c.text)
        had_text = true
    end
    if had_text
        s = String(take!(text_buf))
        if triple && !isempty(s) && s[1] == '\n'
            s = s[nextind(s, 1):end]
        end
        push!(r.children, literal(repr(s)))
    end
    return r
end

RULES["prefixed_command_literal"] = RULES["prefixed_string_literal"]

RULES["escape_sequence"] = _leaf_rule("escape_sequence")
RULES["content"] = _leaf_rule("content")

# Interpolation (outside strings)
RULES["interpolation_expression"] = function (n)
    r = Node("\$")
    for c in _non_trivia(n.children)
        push!(r.children, translate(c))
    end
    return r
end

# Operators, assignment, binary, unary

# Assignment: tree-sitter has (assignment LHS (operator "=") RHS).
# JuliaSyntax differentiates:
#   - `x = 1`        → (= x 1)
#   - `f(x) = body`  → (function-= (call f x) body)   — short-form function
# The distinguisher: is the LHS a call (or call wrapped in where/typed)?
function _is_short_function_lhs(n::Translator.Node)
    # Direct call / prefix-call forms count as function signatures.
    n.kind in ("call", "call-,", "call-pre", "call-i", "dotcall", "dotcall-pre",
               "dotcall-i") && return true
    # Wrappers that preserve function-definition shape on their first child.
    n.kind == "where" && !isempty(n.children) && return _is_short_function_lhs(n.children[1])
    n.kind == "::-i"  && !isempty(n.children) && return _is_short_function_lhs(n.children[1])
    n.kind == "::"    && !isempty(n.children) && return _is_short_function_lhs(n.children[1])
    return false
end

"""
Rewrite `(where ... (where (::-i call T) C_inner) ... C_outer)`
    →    `(::-i call (where ... (where T C_inner) ... C_outer))`.
JuliaSyntax emits the LHS form for long functions and the RHS form for
short-form `f()::T where C_inner where C_outer = v`. Only the RHS shape
is valid on short-form assignment LHS; the rewrite folds any nesting
depth of outer `where`s over a single `::-i` node into the return type.
"""
function _move_where_inside_typed(lhs::Translator.Node)::Translator.Node
    lhs.kind == "where" || return lhs
    # Peel nested `where`s from the outside; collect constraint-child sets
    # in the order encountered (outermost first).
    constraints_outer_first = Vector{Vector{Translator.Node}}()
    cursor = lhs
    while cursor.kind == "where" && length(cursor.children) >= 2
        push!(constraints_outer_first, cursor.children[2:end])
        cursor = cursor.children[1]
    end
    # cursor must now be `(::-i call T)` with call = function signature.
    (cursor.kind == "::-i" && length(cursor.children) == 2) || return lhs
    call = cursor.children[1]
    ret_type = cursor.children[2]
    _is_short_function_lhs(call) || return lhs
    # Wrap ret_type innermost-first: reversed constraint list.
    new_type = ret_type
    for cs in reverse(constraints_outer_first)
        w = Node("where")
        push!(w.children, new_type)
        for c in cs
            push!(w.children, c)
        end
        new_type = w
    end
    r = Node("::-i")
    push!(r.children, call)
    push!(r.children, new_type)
    return r
end

RULES["assignment"] = function (n)
    kids = _non_trivia(n.children)
    lhs = translate(kids[1])
    op_node = kids[2]
    rhs = translate(kids[3])
    head = op_node.text === nothing ? "=" : op_node.text
    if head == "="
        lhs = _move_where_inside_typed(lhs)
        if _is_short_function_lhs(lhs)
            head = "function-="
        end
    end
    r = Node(head)
    push!(r.children, lhs)
    push!(r.children, rhs)
    return r
end

RULES["compound_assignment_expression"] = function (n)
    # JuliaSyntax: `a += b` → `(op= a + b)`, `a .+= b` → `(.op= a + b)`.
    # `.=` alone is broadcast assign and emits `(.= a b)` with no inner op.
    kids = _non_trivia(n.children)
    lhs = translate(kids[1])
    op_node = kids[2]
    rhs = translate(kids[3])
    op_text = op_node.text === nothing ? "?=" : op_node.text
    if op_text == ".="
        r = Node(".=")
        push!(r.children, lhs)
        push!(r.children, rhs)
        return r
    end
    if startswith(op_text, ".") && endswith(op_text, "=") && length(op_text) > 2
        # Broadcast compound: `.+=`, `.*=`, etc. Use `chop`/`SubString` via
        # codepoint-aware indexing so UTF-8 operators like `⊻=` survive.
        r = Node(".op=")
        push!(r.children, lhs)
        inner = chop(SubString(op_text, nextind(op_text, 1)))  # drop leading `.` then trailing `=`
        push!(r.children, literal(String(inner)))
        push!(r.children, rhs)
        return r
    end
    if endswith(op_text, "=") && length(op_text) > 1
        r = Node("op=")
        push!(r.children, lhs)
        push!(r.children, literal(String(chop(op_text))))
        push!(r.children, rhs)
        return r
    end
    # Fallback (shouldn't reach here for real compound ops).
    r = Node(op_text)
    push!(r.children, lhs)
    push!(r.children, rhs)
    return r
end

# Binary: (call-i a op b). JuliaSyntax uses `||` and `&&` as direct heads,
# not call-i; detect those operators and emit accordingly.
const SYNTACTIC_BINOPS = Set(["||", "&&", "->", ":=", "<:", ">:"])

# JuliaSyntax renders chains of the same associative operator as a single
# flat `call-i` with multiple operands: `a + b + c` → `(call-i a + b c)`.
# Julia semantically defines these as variadic, so the flat form is the
# canonical AST shape. Restricted to operators that are truly associative.
const FLAT_BINOPS = Set(["+", "*", "++"])

# Chained comparisons (even with mixed operators) collapse into a single
# `(comparison …)` node: `a < b ≤ c` → `(comparison a < b ≤ c)`.
const COMPARISON_OPS = Set([
    "<", ">", "<=", ">=", "≤", "≥", "==", "===", "!==",
    "⊆", "⊇", "⊂", "⊃", "⊊", "⊋", "∈", "∉", "∋", "∌", "∼", "≈", "≉",
    "≃", "≄", "≅", "≇", "≡", "≢", "≟",
])

"""Walk a left-associative binary_expression chain matching `pred(op_text)`
and return a flat list of (operand_node, operator_text_between_it_and_next).
The last operand's operator is `""` (no follower). Used for both
same-op flattening (`+ + +`) and comparison chains (`< ≤ ≤`)."""
function _flatten_binary_with_ops(n::Node, pred)::Vector{Tuple{Node,String}}
    stack = Tuple{Node,String}[]
    function _flatten!(m::Node, trailing_op::String)
        if m.kind == "binary_expression"
            kids = _non_trivia(m.children)
            op_node = kids[2]
            op_text = op_node.text === nothing ? "" : op_node.text
            if pred(op_text)
                _flatten!(kids[1], op_text)
                push!(stack, (kids[3], trailing_op))
                return
            end
        end
        push!(stack, (m, trailing_op))
    end
    _flatten!(n, "")
    return stack
end

"""Flatten a same-op chain like `a + b + c` and return the operand nodes."""
function _flatten_binary(n::Node, op::String)::Vector{Node}
    [pair[1] for pair in _flatten_binary_with_ops(n, x -> x == op)]
end

RULES["binary_expression"] = function (n)
    kids = _non_trivia(n.children)
    op_node = kids[2]
    op_text = op_node.text === nothing ? "?" : op_node.text
    # Broadcast binary: `.+`, `.*` etc. → dotcall-i with the non-dot operator.
    # Skip this branch for broadcast comparison operators so the chained-
    # comparison handler below can produce the `(comparison … (. <) …)` form
    # when there are 3+ operands.
    if startswith(op_text, ".") && length(op_text) > 1 && op_text != "..." && op_text != ".="
        bare_dot = op_text[2:end]
        if !(bare_dot in COMPARISON_OPS)
            lhs = translate(kids[1])
            rhs = translate(kids[3])
            r = Node("dotcall-i")
            push!(r.children, lhs)
            push!(r.children, literal(bare_dot))
            push!(r.children, rhs)
            return r
        end
    end
    # `&&`, `||`, `->` are now right-associative in the grammar (tree-sitter-
    # julia af339ed) so `a && b && c` arrives as `(a && (b && c))` — the
    # default `SYNTACTIC_BINOPS` handler below emits `(&& a (&& b c))`
    # directly, no flatten-and-refold needed.
    if op_text in FLAT_BINOPS
        # `a + b + c` → `(call-i a + b c)`. Julia defines `+` and `*` as
        # variadic; JuliaSyntax renders them flat.
        operands = _flatten_binary(n, op_text)
        r = Node("call-i")
        push!(r.children, translate(operands[1]))
        push!(r.children, literal(op_text))
        for o in operands[2:end]
            push!(r.children, translate(o))
        end
        return r
    end
    # Chained comparisons (including broadcast forms): flatten `a < b ≤ c`
    # into `(comparison a < b ≤ c)` and `a .< b .< c` into
    # `(comparison a (. <) b (. <) c)`. A single pair stays a plain call-i.
    function _is_comp_op(s::String)
        s in COMPARISON_OPS && return true
        if startswith(s, ".") && length(s) > 1
            bare = s[2:end]
            return bare in COMPARISON_OPS
        end
        return false
    end
    if _is_comp_op(op_text)
        pairs = _flatten_binary_with_ops(n, _is_comp_op)
        if length(pairs) >= 3
            r = Node("comparison")
            for (i, (operand, op)) in enumerate(pairs)
                push!(r.children, translate(operand))
                if !isempty(op)
                    if startswith(op, ".") && length(op) > 1
                        # Broadcast form — emit `(. op)` as the operator node.
                        dot_wrap = Node(".")
                        push!(dot_wrap.children, literal(op[2:end]))
                        push!(r.children, dot_wrap)
                    else
                        push!(r.children, literal(op))
                    end
                end
            end
            return r
        end
        # Short (2-operand) chain: fall through. For the broadcast case we
        # skipped the dotcall-i fast path above — emit it here instead.
        if startswith(op_text, ".") && length(op_text) > 1
            lhs = translate(kids[1])
            rhs = translate(kids[3])
            r = Node("dotcall-i")
            push!(r.children, lhs)
            push!(r.children, literal(op_text[2:end]))
            push!(r.children, rhs)
            return r
        end
    end
    lhs = translate(kids[1])
    rhs = translate(kids[3])
    if op_text in SYNTACTIC_BINOPS
        r = Node(op_text)
        push!(r.children, lhs)
        push!(r.children, rhs)
        return r
    end
    r = Node("call-i")
    push!(r.children, lhs)
    push!(r.children, literal(op_text))
    push!(r.children, rhs)
    return r
end

RULES["unary_expression"] = function (n)
    kids = _non_trivia(n.children)
    op_node = kids[1]
    op_text = op_node.text === nothing ? "?" : op_node.text
    # Rust side injects `(fold_sign)` when `-<int>` / `+<int>` / etc. appears
    # with no whitespace. JuliaSyntax parses those as signed numeric literals
    # rather than `call-pre - ...`.
    if _has_marker(n, "fold_sign") && length(kids) == 2
        lit = kids[2]
        if lit.kind in ("integer_literal", "float_literal")
            txt = lit.text === nothing ? "" : lit.text
            return literal(_normalize_numeric(op_text * txt))
        end
    end
    operand = translate(kids[2])
    if startswith(op_text, ".") && length(op_text) > 1
        r = Node("dotcall-pre")
        push!(r.children, literal(op_text[2:end]))
        push!(r.children, operand)
        return r
    end
    # Syntactic operators (`<:`, `>:`, `&&`, `||`, `::`) keep the operator
    # as the head with a `-pre` suffix rather than wrapping in `call-pre`.
    if op_text in SYNTACTIC_PREFIX_OPS
        r = Node(op_text * "-pre")
        push!(r.children, operand)
        return r
    end
    r = Node("call-pre")
    push!(r.children, literal(op_text))
    push!(r.children, operand)
    return r
end

const SYNTACTIC_PREFIX_OPS = Set(["<:", ">:", "&&", "||", "::", "\$"])

RULES["range_expression"] = function (n)
    # JuliaSyntax flattens `start:step:stop` into `(call-i start : step stop)`
    # — a 3-operand range is a ternary call, not two nested binary ranges.
    # Longer chains (`a:b:c:d`) keep the left-leaning nesting of the first
    # three parts: `((call-i a : b c) : d)`.
    kids = _non_trivia(n.children)
    # tree-sitter: range_expression has either 2 children (binary `a:b`) or
    # 1 nested range_expression + 1 child (representing `a:b:c` as
    # `range(range(a,b),c)`). Detect the nested step-range pattern and flatten.
    if length(kids) == 2 && kids[1].kind == "range_expression"
        inner = _non_trivia(kids[1].children)
        # Only flatten when the inner range is itself binary (non-nested).
        # `a:b:c` → `(call-i a : b c)`. `a:b:c:d` keeps the inner nested and
        # adds `:d` on top.
        if length(inner) == 2 && inner[1].kind != "range_expression"
            r = Node("call-i")
            push!(r.children, translate(inner[1]))
            push!(r.children, literal(":"))
            push!(r.children, translate(inner[2]))
            push!(r.children, translate(kids[2]))
            return r
        end
    end
    lhs = translate(kids[1])
    rhs = translate(kids[end])
    r = Node("call-i")
    push!(r.children, lhs)
    push!(r.children, literal(":"))
    push!(r.children, rhs)
    return r
end

RULES["ternary_expression"] = function (n)
    kids = _non_trivia(n.children)
    # tree-sitter ternary is (_expression _bracket_form _bracket_form)
    # with `?` and `:` as anonymous tokens (hidden from sexp).
    r = Node("?")
    for c in kids
        push!(r.children, translate(c))
    end
    return r
end

RULES["typed_expression"] = function (n)
    kids = _non_trivia(n.children)
    r = Node("::-i")
    for c in kids
        push!(r.children, translate(c))
    end
    return r
end

RULES["unary_typed_expression"] = function (n)
    kids = _non_trivia(n.children)
    r = Node("::-pre")
    for c in kids
        push!(r.children, translate(c))
    end
    return r
end

RULES["where_expression"] = function (n)
    kids = _non_trivia(n.children)
    # Julia parses `T::Type where C` (parameter form) as `T :: (Type where C)` —
    # `where` binds tighter than `::`. Tree-sitter's CST is the opposite:
    # `(where_expression (typed_expression T Type) C)`. Rewrap so the
    # resulting AST is `(::-i T (where Type C))`, matching JuliaSyntax.
    #
    # BUT only apply this when the `::` LHS is a simple identifier/tuple
    # parameter — NOT when it's a function signature `call_expression`.
    # Function return-type annotations `f(args)::T where C` keep the
    # original nesting `(where (::-i call T) C)`.
    if length(kids) >= 2 && kids[1].kind == "typed_expression"
        te_kids = _non_trivia(kids[1].children)
        if length(te_kids) == 2 && !(te_kids[1].kind in
                ("call_expression", "broadcast_call_expression",
                 "parametrized_type_expression"))
            inner_where = Node("where")
            push!(inner_where.children, translate(te_kids[2]))
            for c in kids[2:end]
                push!(inner_where.children, translate(c))
            end
            r = Node("::-i")
            push!(r.children, translate(te_kids[1]))
            push!(r.children, inner_where)
            return r
        end
    end
    r = Node("where")
    for c in kids
        push!(r.children, translate(c))
    end
    return r
end

RULES["splat_expression"] = function (n)
    kids = _non_trivia(n.children)
    r = Node("...")
    for c in kids
        push!(r.children, translate(c))
    end
    return r
end

RULES["arrow_function_expression"] = function (n)
    kids = _non_trivia(n.children)
    lhs_raw = kids[1]
    body = translate(kids[2])
    # JuliaSyntax wraps lone-identifier params in a (tuple …) node.
    lhs = if lhs_raw.kind in ("identifier", "typed_expression", "interpolation_expression")
        t = Node("tuple")
        push!(t.children, translate(lhs_raw))
        t
    else
        translate(lhs_raw)
    end
    r = Node("->")
    push!(r.children, lhs)
    push!(r.children, body)
    return r
end

"Detect the `trailing_comma` named child emitted by tree-sitter-julia."
function _has_trailing_comma(n::Node)
    any(c -> c.kind == "trailing_comma", n.children)
end

# Calls
"""Split argument_list raw children at the `parameters_separator` named child
emitted by tree-sitter-julia. Everything after it becomes a keyword-argument
block wrapped in `(parameters …)`."""
function _args_with_parameters(args_node::Node)::Vector{Node}
    out = Node[]
    raw = args_node.children
    semi_idx = findfirst(c -> c.kind == "parameters_separator", raw)
    if semi_idx === nothing
        for c in _non_trivia(raw)
            push!(out, translate(c))
        end
    else
        for i in 1:semi_idx-1
            c = raw[i]
            (c.kind in TRIVIA_KINDS) && continue
            (c.kind in MARKER_KINDS) && continue
            push!(out, translate(c))
        end
        params = Node("parameters")
        for i in semi_idx+1:length(raw)
            c = raw[i]
            (c.kind in TRIVIA_KINDS) && continue
            (c.kind in MARKER_KINDS) && continue
            push!(params.children, translate(c))
        end
        # Keep `(parameters)` even when empty — JuliaSyntax emits it for
        # `f(a;)` to distinguish from `f(a)`.
        push!(out, params)
    end
    return out
end

"Unary prefix operators that JuliaSyntax renders with `call-pre` / `dotcall-pre`
rather than a plain call. tree-sitter emits `!(x)` as `(call_expression
(operator \"!\") (argument_list x))`, but the two ASTs represent the same
meaning — Julia semantically treats `!x` and `!(x)` identically."
const UNARY_PREFIX_CALL_OPS = Set([
    "!", "-", "+", "~", "¬", "√", "∛", "∜", "⋆", "±", "∓",
])

RULES["call_expression"] = function (n)
    kids = _non_trivia(n.children)
    # Rewrite `(call_expression (operator OP) (argument_list x))` to
    # `(call-pre OP x)` when OP is a unary-prefix operator and there's
    # exactly one positional arg with no `;`/trailing-comma quirks.
    fn_node = kids[1]
    args_node = kids[2]
    if fn_node.kind == "operator" && args_node.kind == "argument_list"
        op_text = fn_node.text === nothing ? "" : fn_node.text
        # Strip leading `.` for broadcast `.!(x)` → dotcall-pre.
        is_dot = startswith(op_text, ".") && length(op_text) > 1
        bare = is_dot ? op_text[2:end] : op_text
        if bare in UNARY_PREFIX_CALL_OPS
            pos_args = [c for c in _non_trivia(args_node.children)
                        if c.kind != "parameters_separator" && c.kind != "assignment"]
            other = [c for c in _non_trivia(args_node.children)
                     if c.kind == "parameters_separator" || c.kind == "assignment"]
            if length(pos_args) == 1 && isempty(other) && !_has_trailing_comma(args_node)
                r = Node(is_dot ? "dotcall-pre" : "call-pre")
                push!(r.children, literal(bare))
                push!(r.children, translate(pos_args[1]))
                return r
            end
        end
    end

    func = translate(kids[1])
    trailing = args_node.kind == "argument_list" && _has_trailing_comma(args_node)
    r = Node(trailing ? "call-," : "call")
    push!(r.children, func)
    if args_node.kind == "argument_list"
        for c in _args_with_parameters(args_node)
            push!(r.children, c)
        end
    else
        push!(r.children, translate(args_node))
    end
    # do_clause appears as a sibling in tree-sitter; attach into the call.
    if length(kids) >= 3
        push!(r.children, translate(kids[3]))
    end
    return r
end

# Silent marker; parent rules consume it explicitly.
RULES["trailing_comma"] = function (_)
    return Node("trailing_comma")
end

RULES["broadcast_call_expression"] = function (n)
    kids = _non_trivia(n.children)
    func = translate(kids[1])
    args_node = kids[2]
    trailing = args_node.kind == "argument_list" && _has_trailing_comma(args_node)
    r = Node(trailing ? "dotcall-," : "dotcall")
    push!(r.children, func)
    if args_node.kind == "argument_list"
        for c in _args_with_parameters(args_node)
            push!(r.children, c)
        end
    else
        push!(r.children, translate(args_node))
    end
    return r
end

RULES["argument_list"] = function (n)
    # Fallback: an argument_list exposed outside a call_expression (e.g. as
    # an arrow function's parameter list `() -> body`) is a parenthesized
    # form, so use `tuple-p`. Honour trailing-comma and `;`-introduced
    # parameters just like call sites do.
    trailing = _has_trailing_comma(n)
    r = Node(trailing ? "tuple-p-," : "tuple-p")
    for c in _args_with_parameters(n)
        push!(r.children, c)
    end
    return r
end

RULES["macrocall_expression"] = function (n)
    kids = _non_trivia(n.children)
    # Head: `macrocall-p` for parenthesized form (`@foo(a, b)`), `macrocall`
    # for bare-args form (`@foo a b`). tree-sitter's argument_list vs
    # macro_argument_list distinguishes them. Trailing comma adds `-,`.
    is_parens = length(kids) >= 2 && kids[2].kind == "argument_list"
    trailing = is_parens && _has_trailing_comma(kids[2])
    head = is_parens ? (trailing ? "macrocall-p-," : "macrocall-p") : "macrocall"
    r = Node(head)
    push!(r.children, translate(kids[1]))
    if length(kids) >= 2
        if kids[2].kind == "argument_list"
            for c in _args_with_parameters(kids[2])
                push!(r.children, c)
            end
        elseif kids[2].kind == "macro_argument_list"
            for c in _non_trivia(kids[2].children)
                push!(r.children, translate(c))
            end
        else
            push!(r.children, translate(kids[2]))
        end
    end
    # do_clause sibling
    if length(kids) >= 3
        push!(r.children, translate(kids[3]))
    end
    return r
end

RULES["macro_identifier"] = function (n)
    # JuliaSyntax represents @foo as the bare token `@foo`.
    kids = _non_trivia(n.children)
    if length(kids) == 1 && kids[1].kind == "identifier" && kids[1].text !== nothing
        return literal("@" * kids[1].text)
    end
    # Qualified or operator macro: try to serialize child.
    inner = translate(kids[1])
    # Render inner as a string prefixed by '@'.
    inner_str = sexp_string(inner)
    return literal("@" * inner_str)
end

RULES["macro_argument_list"] = function (n)
    # Exposed only when not inside a macrocall_expression (rare).
    r = Node("args")
    for c in _non_trivia(n.children)
        push!(r.children, translate(c))
    end
    return r
end

# Field access: (. value field)
RULES["field_expression"] = function (n)
    kids = _non_trivia(n.children)
    r = Node(".")
    push!(r.children, translate(kids[1]))
    field = kids[2]
    if field.kind == "identifier" && field.text !== nothing
        # JuliaSyntax prints field name as `(quote-: name)` when accessed via `.`.
        # Actually from our exploration `a.b` → `(. a b)` — field name is bare.
        push!(r.children, literal(field.text))
    else
        push!(r.children, translate(field))
    end
    return r
end

# Indexing: (ref a args...)
RULES["index_expression"] = function (n)
    kids = _non_trivia(n.children)
    # Typed comprehension: `Any[a for a in args]` becomes
    # `(typed_comprehension Any (generator …))` in JuliaSyntax, not a ref.
    if length(kids) >= 2 && kids[2].kind == "comprehension_expression"
        r = Node("typed_comprehension")
        push!(r.children, translate(kids[1]))
        comp = translate(kids[2])
        for c in comp.children
            push!(r.children, c)
        end
        return r
    end
    # `T[a; b]` / `T[a b; c d]` use `typed_vcat` / `typed_hcat` heads and
    # flatten like the plain matrix forms do.
    if length(kids) >= 2 && kids[2].kind == "matrix_expression"
        inner = translate(kids[2])   # produces vcat/hcat/vect
        head_map = Dict("vcat" => "typed_vcat", "hcat" => "typed_hcat",
                        "vect" => "typed_vcat")
        new_head = get(head_map, inner.kind, "typed_vcat")
        r = Node(new_head)
        push!(r.children, translate(kids[1]))
        for c in inner.children
            push!(r.children, c)
        end
        return r
    end
    r = Node("ref")
    push!(r.children, translate(kids[1]))
    # Second child is a vector_expression. Flatten its items.
    if length(kids) >= 2 && kids[2].kind == "vector_expression"
        for c in _non_trivia(kids[2].children)
            push!(r.children, translate(c))
        end
    else
        for c in kids[2:end]
            push!(r.children, translate(c))
        end
    end
    return r
end

# Adjoint: a' → (call-post a ')
RULES["adjoint_expression"] = function (n)
    kids = _non_trivia(n.children)
    r = Node("call-post")
    push!(r.children, translate(kids[1]))
    push!(r.children, literal("'"))
    return r
end

# Type parameter: A{T}
RULES["parametrized_type_expression"] = function (n)
    kids = _non_trivia(n.children)
    # Trailing comma on the inner `{ … , }` bumps head to `curly-,`.
    trailing = length(kids) >= 2 && kids[2].kind == "curly_expression" &&
               _has_trailing_comma(kids[2])
    r = Node(trailing ? "curly-," : "curly")
    push!(r.children, translate(kids[1]))
    if length(kids) >= 2 && kids[2].kind == "curly_expression"
        for c in _non_trivia(kids[2].children)
            push!(r.children, translate(c))
        end
    else
        for c in kids[2:end]
            push!(r.children, translate(c))
        end
    end
    return r
end

# Parenthesized: unwrap single-child case.
RULES["parenthesized_expression"] = function (n)
    kids = _non_trivia(n.children)
    # JuliaSyntax with default keep_parens=false drops the wrapper.
    if length(kids) == 1
        return translate(kids[1])
    end
    # Multi-child: `(a; b)` is a parenthesized block; JuliaSyntax uses the
    # `block-p` head (vs bare `block` for `begin … end`).
    r = Node("block-p")
    for c in kids
        push!(r.children, translate(c))
    end
    return r
end

# Tuples
RULES["tuple_expression"] = function (n)
    trailing = _has_trailing_comma(n)
    # JuliaSyntax: (tuple-p x y) or (tuple-p-, x y) for trailing-comma form.
    r = Node(trailing ? "tuple-p-," : "tuple-p")
    for c in _args_with_parameters(n)
        push!(r.children, c)
    end
    return r
end

RULES["open_tuple"] = function (n)
    r = Node("tuple")
    for c in _non_trivia(n.children)
        push!(r.children, translate(c))
    end
    return r
end

# Arrays / matrices
RULES["vector_expression"] = function (n)
    trailing = _has_trailing_comma(n)
    r = Node(trailing ? "vect-," : "vect")
    for c in _non_trivia(n.children)
        c.kind == "trailing_comma" && continue
        push!(r.children, translate(c))
    end
    return r
end

RULES["matrix_expression"] = function (n)
    kids = _non_trivia(n.children)
    has_semi = _has_marker(n, "matrix_semicolon")
    # Shapes in JuliaSyntax:
    #   `[a b]`         (no `;`, multi-col)  → (hcat a b)         — no row wrapper
    #   `[a b;]` or similar with `;`          → (vcat (row a b))   — row kept
    #   `[a; b]`        (n rows × 1 col)      → (vcat a b)         — flattened
    #   `[a b; c d]`                          → (vcat (row a b) (row c d))
    rows = [c for c in kids if c.kind == "matrix_row"]
    # Single-row, multi-col, no `;` → hcat.
    if length(rows) == 1 && length(_non_trivia(rows[1].children)) >= 2 && !has_semi
        r = Node("hcat")
        for c in _non_trivia(rows[1].children)
            push!(r.children, translate(c))
        end
        return r
    end
    # Otherwise vcat; flatten rows only when every row has a single element.
    all_single = all(r -> length(_non_trivia(r.children)) == 1, rows)
    r = Node("vcat")
    for c in kids
        if c.kind == "matrix_row" && all_single
            inner = _non_trivia(c.children)
            push!(r.children, translate(inner[1]))
        else
            push!(r.children, translate(c))
        end
    end
    return r
end

RULES["matrix_row"] = function (n)
    r = Node("row")
    for c in _non_trivia(n.children)
        push!(r.children, translate(c))
    end
    return r
end

RULES["comprehension_expression"] = function (n)
    kids = _non_trivia(n.children)
    r = Node("comprehension")
    # JuliaSyntax: each `for` clause becomes its own `(iteration …)` child
    # of `(generator body …)`. Multiple `for` clauses appear as siblings:
    #   `[f(i,j) for j in 1:n for i in 1:j]`
    #     → `(generator body (iteration j) (iteration i))`
    # A trailing `if p(x)` wraps the immediately-preceding iteration into
    # a `(filter iteration body)` node.
    body = translate(kids[1])
    rest = kids[2:end]
    inner = Node("generator")
    push!(inner.children, body)
    iters = Node[]
    for c in rest
        if c.kind == "for_clause"
            iter = Node("iteration")
            for fb in _non_trivia(c.children)
                fb.kind == "for_binding" || continue
                push!(iter.children, translate(fb))
            end
            push!(iters, iter)
        elseif c.kind == "if_clause"
            # Wrap the last iteration in `(filter iter cond…)`.
            if !isempty(iters)
                cond = translate(c)
                wrapper = Node("filter")
                push!(wrapper.children, iters[end])
                for fc in cond.children
                    push!(wrapper.children, fc)
                end
                iters[end] = wrapper
            end
        end
    end
    for it in iters
        push!(inner.children, it)
    end
    push!(r.children, inner)
    return r
end

RULES["generator"] = function (n)
    kids = _non_trivia(n.children)
    r = Node("generator")
    push!(r.children, translate(kids[1]))
    # Collect iterations with optional filter wrapping, same as comprehension_expression.
    iters = Node[]
    for c in kids[2:end]
        if c.kind == "for_clause"
            iter = Node("iteration")
            for fb in _non_trivia(c.children)
                fb.kind == "for_binding" || continue
                push!(iter.children, translate(fb))
            end
            push!(iters, iter)
        elseif c.kind == "if_clause"
            if !isempty(iters)
                cond = translate(c)
                wrapper = Node("filter")
                push!(wrapper.children, iters[end])
                for fc in cond.children
                    push!(wrapper.children, fc)
                end
                iters[end] = wrapper
            end
        end
    end
    for it in iters
        push!(r.children, it)
    end
    return r
end

RULES["for_binding"] = function (n)
    kids = _non_trivia(n.children)
    # for_binding: optional("outer"), var, (operator "in"/"="/"∈"), iter
    # Emit as (in var iter) like JuliaSyntax.
    r = Node("in")
    # Filter to non-operator children.
    non_op = [c for c in kids if c.kind != "operator"]
    for c in non_op
        push!(r.children, translate(c))
    end
    return r
end

RULES["for_clause"] = function (n)
    # Shouldn't be reached except via fallback (generator handles it).
    r = Node("iteration")
    for c in _non_trivia(n.children)
        c.kind == "for_binding" || continue
        push!(r.children, translate(c))
    end
    return r
end

RULES["if_clause"] = function (n)
    kids = _non_trivia(n.children)
    r = Node("filter")
    for c in kids
        push!(r.children, translate(c))
    end
    return r
end

RULES["curly_expression"] = function (n)
    trailing = _has_trailing_comma(n)
    r = Node(trailing ? "braces-," : "braces")
    for c in _non_trivia(n.children)
        push!(r.children, translate(c))
    end
    return r
end

# Quote
RULES["quote_expression"] = function (n)
    kids = _non_trivia(n.children)
    r = Node("quote-:")
    for c in kids
        push!(r.children, translate(c))
    end
    return r
end

# Blocks / control flow

RULES["block"] = function (n)
    # tree-sitter's block is JuliaSyntax's block; flatten children directly.
    r = Node("block")
    for c in _non_trivia(n.children)
        push!(r.children, translate(c))
    end
    return r
end

RULES["compound_statement"] = function (n)
    # `begin ... end`
    r = Node("block")
    block_child = _child_by_kind(n, "block")
    if block_child !== nothing
        for c in _wrap_docstrings(_non_trivia(block_child.children))
            push!(r.children, c)
        end
    end
    return r
end

RULES["quote_statement"] = function (n)
    r = Node("quote")
    block_child = _child_by_kind(n, "block")
    inner = Node("block")
    if block_child !== nothing
        for c in _wrap_docstrings(_non_trivia(block_child.children))
            push!(inner.children, c)
        end
    end
    push!(r.children, inner)
    return r
end

"""
JuliaSyntax nests alternatives recursively: each `elseif`/`else` is the
*last child* of the preceding `if`/`elseif` node, not a sibling. Build the
chain by walking the alternatives list in order and attaching each to the
previous node.
"""
function _if_attach_alternatives!(parent::Node, alts::Vector{Node})
    isempty(alts) && return
    cur = parent
    for a in alts
        push!(cur.children, a)
        cur = a
    end
end

function _elseif_pair(n::Node)
    # Returns (condition, body_block) nodes for an elseif_clause.
    r = Node("elseif")
    kids = _non_trivia(n.children)
    i = 1
    push!(r.children, translate(kids[i])); i += 1
    body = Node("block")
    while i <= length(kids)
        if kids[i].kind == "block"
            for c in _non_trivia(kids[i].children)
                push!(body.children, translate(c))
            end
        end
        i += 1
    end
    push!(r.children, body)
    return r
end

function _else_body(n::Node)
    r = Node("block")
    block_child = _child_by_kind(n, "block")
    if block_child !== nothing
        for c in _non_trivia(block_child.children)
            push!(r.children, translate(c))
        end
    end
    return r
end

RULES["if_statement"] = function (n)
    r = Node("if")
    # Grammar: if_statement: 'if', condition: _expression, optional(_terminator),
    #   optional(block), alternative*(elseif_clause), optional(else_clause), 'end'
    kids = _non_trivia(n.children)
    i = 1
    # Condition
    push!(r.children, translate(kids[i])); i += 1
    # Body block (may be absent)
    body = Node("block")
    while i <= length(kids) && kids[i].kind != "elseif_clause" && kids[i].kind != "else_clause"
        if kids[i].kind == "block"
            for c in _non_trivia(kids[i].children)
                push!(body.children, translate(c))
            end
        end
        i += 1
    end
    push!(r.children, body)
    # Alternatives: nested, not sibling.
    alts = Node[]
    while i <= length(kids)
        k = kids[i]
        if k.kind == "elseif_clause"
            push!(alts, _elseif_pair(k))
        elseif k.kind == "else_clause"
            push!(alts, _else_body(k))
        end
        i += 1
    end
    _if_attach_alternatives!(r, alts)
    return r
end

RULES["elseif_clause"] = function (n)
    # Reachable only when an `elseif_clause` appears outside an `if_statement`
    # (shouldn't happen, but fall back to the flat form).
    return _elseif_pair(n)
end

RULES["else_clause"] = function (n)
    r = Node("block")
    block_child = _child_by_kind(n, "block")
    if block_child !== nothing
        for c in _non_trivia(block_child.children)
            push!(r.children, translate(c))
        end
    end
    return r
end

RULES["for_statement"] = function (n)
    kids = _non_trivia(n.children)
    r = Node("for")
    iter = Node("iteration")
    body = Node("block")
    for c in kids
        if c.kind == "for_binding"
            push!(iter.children, translate(c))
        elseif c.kind == "block"
            for b in _non_trivia(c.children)
                push!(body.children, translate(b))
            end
        end
    end
    push!(r.children, iter)
    push!(r.children, body)
    return r
end

RULES["while_statement"] = function (n)
    kids = _non_trivia(n.children)
    r = Node("while")
    body = Node("block")
    body_pushed = false
    for c in kids
        if c.kind == "block"
            for b in _non_trivia(c.children)
                push!(body.children, translate(b))
            end
        else
            push!(r.children, translate(c))
        end
    end
    push!(r.children, body)
    return r
end

RULES["try_statement"] = function (n)
    kids = _non_trivia(n.children)
    r = Node("try")
    # Try body always comes first in JuliaSyntax output, even when empty.
    body_block = Node("block")
    for c in kids
        if c.kind == "block"
            for b in _non_trivia(c.children)
                push!(body_block.children, translate(b))
            end
            break   # only the first block is the try body
        end
    end
    push!(r.children, body_block)
    for c in kids
        if c.kind == "catch_clause" || c.kind == "finally_clause"
            push!(r.children, translate(c))
        end
    end
    return r
end

RULES["catch_clause"] = function (n)
    kids = _non_trivia(n.children)
    r = Node("catch")
    # JuliaSyntax: (catch VAR (block ...)). VAR is the exception variable,
    # or `□` (the U+25A1 WHITE SQUARE placeholder) when the catch has no
    # binding; tree-sitter omits the slot entirely.
    var = _child_by_kind(n, "identifier", "interpolation_expression")
    if var !== nothing
        push!(r.children, translate(var))
    else
        push!(r.children, literal("\u25a1"))
    end
    body = Node("block")
    block_child = _child_by_kind(n, "block")
    if block_child !== nothing
        for b in _non_trivia(block_child.children)
            push!(body.children, translate(b))
        end
    end
    push!(r.children, body)
    return r
end

RULES["finally_clause"] = function (n)
    r = Node("finally")
    block_child = _child_by_kind(n, "block")
    body = Node("block")
    if block_child !== nothing
        for c in _non_trivia(block_child.children)
            push!(body.children, translate(c))
        end
    end
    push!(r.children, body)
    return r
end

RULES["let_statement"] = function (n)
    kids = _non_trivia(n.children)
    r = Node("let")
    bindings = Node("block")
    body = Node("block")
    saw_block = false
    for c in kids
        if c.kind == "block"
            saw_block = true
            for b in _non_trivia(c.children)
                push!(body.children, translate(b))
            end
        else
            push!(bindings.children, translate(c))
        end
    end
    push!(r.children, bindings)
    push!(r.children, body)
    return r
end

RULES["do_clause"] = function (n)
    kids = _non_trivia(n.children)
    r = Node("do")
    # Parameters — JuliaSyntax wraps them in (tuple ...).
    params = Node("tuple")
    body = Node("block")
    for c in kids
        if c.kind == "block"
            for b in _non_trivia(c.children)
                push!(body.children, translate(b))
            end
        else
            push!(params.children, translate(c))
        end
    end
    push!(r.children, params)
    push!(r.children, body)
    return r
end

# Definitions

RULES["module_definition"] = function (n)
    kids = _non_trivia(n.children)
    is_bare = any(c -> c.kind == "baremodule_keyword", kids)
    r = Node(is_bare ? "module-bare" : "module")
    body = Node("block")
    for c in kids
        c.kind == "baremodule_keyword" && continue
        if c.kind == "block"
            for b in _wrap_docstrings(_non_trivia(c.children))
                push!(body.children, b)
            end
        else
            push!(r.children, translate(c))
        end
    end
    push!(r.children, body)
    return r
end

RULES["struct_definition"] = function (n)
    kids = _non_trivia(n.children)
    is_mutable = any(c -> c.kind == "mutable_keyword", kids)
    r = Node(is_mutable ? "struct-mut" : "struct")
    for c in kids
        c.kind == "mutable_keyword" && continue
        if c.kind == "block"
            body = Node("block")
            for b in _wrap_docstrings(_non_trivia(c.children))
                push!(body.children, b)
            end
            push!(r.children, body)
        else
            push!(r.children, translate(c))
        end
    end
    has_body = !isempty(r.children) && r.children[end].kind == "block"
    has_body || push!(r.children, Node("block"))
    return r
end

RULES["abstract_definition"] = function (n)
    kids = _non_trivia(n.children)
    r = Node("abstract")
    for c in kids
        c.kind == "type_head" || continue
        push!(r.children, translate(c))
    end
    return r
end

RULES["primitive_definition"] = function (n)
    kids = _non_trivia(n.children)
    r = Node("primitive")
    for c in kids
        push!(r.children, translate(c))
    end
    return r
end

RULES["typegroup_definition"] = function (n)
    # `typegroup A begin … end` — rare. Emit a best-effort wrapper.
    kids = _non_trivia(n.children)
    r = Node("typegroup")
    for c in kids
        push!(r.children, translate(c))
    end
    return r
end

RULES["type_head"] = function (n)
    kids = _non_trivia(n.children)
    # type_head holds `Foo`, `Foo{T}`, or `Foo{T} <: Bar`. tree-sitter keeps
    # these as nested binary/where expressions. Emit the sole child.
    if length(kids) == 1
        return translate(kids[1])
    end
    # Fall back: emit as a pseudo-node.
    r = Node("type_head")
    for c in kids
        push!(r.children, translate(c))
    end
    return r
end

RULES["function_definition"] = function (n)
    kids = _non_trivia(n.children)
    r = Node("function")
    has_block = false
    sig = nothing
    for c in kids
        if c.kind == "block"
            has_block = true
            body = Node("block")
            for b in _non_trivia(c.children)
                push!(body.children, translate(b))
            end
            push!(r.children, body)
        elseif c.kind == "signature"
            sig = translate(c)
            push!(r.children, sig)
        end
    end
    # JuliaSyntax distinguishes three forms:
    #   `function foo end`   → `(function foo)`             — no body
    #   `function foo() end` → `(function (call foo) (block))` — empty body
    #   `function foo() x end` → `(function (call foo) (block x))`
    # Tree-sitter drops an empty body block in the second case, so detect
    # that case by checking whether the signature starts with a `call` head.
    if !has_block && sig !== nothing && (sig.kind == "call" || sig.kind == "call-,"
            || sig.kind == "where" || sig.kind == "::-i" || sig.kind == "::"
            || sig.kind == "tuple-p" || sig.kind == "tuple-p-,")
        push!(r.children, Node("block"))
    end
    return r
end

"""Undo the `call-pre` / `dotcall-pre` rewrite when a unary-prefix operator
appears as the function *name* being defined (e.g. `macro !(expr) … end`
or `Base.:-(x::T) = …`). In that context JuliaSyntax emits a plain `call`
even though the same sexp in expression position would be a `call-pre`."""
function _undo_prefix_in_sig(n::Node)::Node
    if n.kind == "call-pre" || n.kind == "dotcall-pre"
        r = Node(n.kind == "dotcall-pre" ? "dotcall" : "call")
        for c in n.children
            push!(r.children, c)
        end
        return r
    end
    if n.kind in ("where", "::-i", "::")
        if !isempty(n.children)
            new_first = _undo_prefix_in_sig(n.children[1])
            if new_first !== n.children[1]
                r = Node(n.kind)
                push!(r.children, new_first)
                for c in n.children[2:end]
                    push!(r.children, c)
                end
                return r
            end
        end
    end
    return n
end

RULES["signature"] = function (n)
    # Inline the single signature child into its parent function_definition.
    kids = _non_trivia(n.children)
    if length(kids) == 1
        return _undo_prefix_in_sig(translate(kids[1]))
    end
    # Shouldn't happen; emit call-like wrapper.
    r = Node("call")
    for c in kids
        push!(r.children, translate(c))
    end
    return r
end

RULES["macro_definition"] = function (n)
    kids = _non_trivia(n.children)
    r = Node("macro")
    for c in kids
        if c.kind == "block"
            body = Node("block")
            for b in _non_trivia(c.children)
                push!(body.children, translate(b))
            end
            push!(r.children, body)
        else
            push!(r.children, translate(c))
        end
    end
    length(r.children) >= 2 || push!(r.children, Node("block"))
    return r
end

# Imports / exports

"Count `(relative_dot)` named children emitted by tree-sitter-julia for an
`import_path` node. Used to emit `(importpath . . X)` JuliaSyntax form."
function _dot_count(n::Node)
    count(c -> c.kind == "relative_dot", n.children)
end

"Render an `import_path` / `identifier` node as an `importpath` whose
children are the leading `.` dots (if any) followed by the path components."
function _to_importpath(c::Node)::Node
    r = Node("importpath")
    if c.kind == "import_path"
        for _ in 1:_dot_count(c)
            push!(r.children, literal("."))
        end
        for k in _non_trivia(c.children)
            push!(r.children, translate(k))
        end
    elseif c.kind == "import_from_current_module"
        # Grammar variant: bare leading dots with identifier inside. Count
        # the markers and append the child identifier.
        for _ in 1:_dot_count(c)
            push!(r.children, literal("."))
        end
        for k in _non_trivia(c.children)
            push!(r.children, translate(k))
        end
    else
        push!(r.children, translate(c))
    end
    return r
end

"Dispatch for a top-level clause child inside `import`/`using`/`selected_import`.
Pass-through `import_alias` (`as`) and already-built importpaths, otherwise
wrap the child in an importpath."
function _wrap_importable(c::Node)::Node
    if c.kind == "import_alias"
        return translate(c)
    elseif c.kind == "selected_import"
        return translate(c)
    else
        return _to_importpath(c)
    end
end

RULES["import_statement"] = function (n)
    r = Node("import")
    for c in _non_trivia(n.children)
        push!(r.children, _wrap_importable(c))
    end
    return r
end

RULES["using_statement"] = function (n)
    r = Node("using")
    for c in _non_trivia(n.children)
        push!(r.children, _wrap_importable(c))
    end
    return r
end

RULES["import_path"] = function (n)
    # Fallback for an import_path appearing outside selected_import/import_statement
    # (shouldn't normally happen). Emit as an importpath with dots + children.
    return _to_importpath(n)
end

RULES["import_from_current_module"] = function (n)
    return _to_importpath(n)
end

RULES["import_alias"] = function (n)
    kids = _non_trivia(n.children)
    r = Node("as")
    # First child is the path being aliased (wrap in importpath if not already).
    if !isempty(kids)
        push!(r.children, _to_importpath(kids[1]))
        for c in kids[2:end]
            push!(r.children, translate(c))
        end
    end
    return r
end

RULES["selected_import"] = function (n)
    kids = _non_trivia(n.children)
    r = Node(":")
    # First child is the base path. Remaining children are selected names.
    push!(r.children, _to_importpath(kids[1]))
    for c in kids[2:end]
        if c.kind == "import_alias"
            push!(r.children, translate(c))
        else
            push!(r.children, _to_importpath(c))
        end
    end
    return r
end

RULES["export_statement"] = function (n)
    r = Node("export")
    for c in _non_trivia(n.children)
        push!(r.children, translate(c))
    end
    return r
end

RULES["public_statement"] = function (n)
    r = Node("public")
    for c in _non_trivia(n.children)
        push!(r.children, translate(c))
    end
    return r
end

# Trivial statement wrappers
RULES["const_statement"] = function (n)
    r = Node("const")
    for c in _non_trivia(n.children)
        push!(r.children, translate(c))
    end
    return r
end
RULES["global_statement"] = function (n)
    r = Node("global")
    for c in _non_trivia(n.children)
        if c.kind == "open_tuple"
            # `global a, b` → (global a b), not (global (tuple a b)).
            # JuliaSyntax flattens the comma-separated list at this boundary;
            # tree-sitter wraps it in open_tuple. Splice the children through.
            for gc in _non_trivia(c.children)
                push!(r.children, translate(gc))
            end
        else
            push!(r.children, translate(c))
        end
    end
    return r
end
RULES["local_statement"] = function (n)
    r = Node("local")
    for c in _non_trivia(n.children)
        if c.kind == "open_tuple"
            # See global_statement: JuliaSyntax flattens `local a, b` → (local a b).
            for gc in _non_trivia(c.children)
                push!(r.children, translate(gc))
            end
        else
            push!(r.children, translate(c))
        end
    end
    return r
end
RULES["return_statement"] = function (n)
    r = Node("return")
    for c in _non_trivia(n.children)
        push!(r.children, translate(c))
    end
    return r
end
RULES["break_statement"] = function (_)
    return Node("break")
end
RULES["continue_statement"] = function (_)
    return Node("continue")
end

# Juxtaposition
RULES["juxtaposition_expression"] = function (n)
    r = Node("juxtapose")
    for c in _non_trivia(n.children)
        push!(r.children, translate(c))
    end
    return r
end

end # module Translator
