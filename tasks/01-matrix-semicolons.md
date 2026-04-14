# Task 1: Fix matrix/vcat semicolons — preserve row separators

## Problem

Semicolons inside `[...]` are semantically significant in Julia. They separate matrix rows:
- `[x ; y ; z]` → 3×1 matrix (3 rows, 1 column)
- `[x y ; z w]` → 2×2 matrix
- `[x y z]` → 1-element vector if no spaces, or 1×3 hcat

Currently, formatting strips the `;` and newlines between rows, collapsing multi-row matrices into single rows.

## Failing cases (from AST equivalence test)

```
"[x ; y ; z]"      → formatted: "[x y z ]"     ← should be "[x; y; z]"
"[x y ; z w]"       → formatted: "[x y z w ]"   ← should be "[x y; z w]"
"[x y ; z w ; a b]" → formatted: "[x y z w a b ]" ← rows merged
"[x \n ]"           → formatted: "[x ]"          ← newline-as-row-sep lost
"T[x ; y]"          → formatted: "T[x y ]"       ← typed vcat lost
"T[a b; c d]"       → formatted: "T[a b c d ]"   ← typed matrix lost
"T[a ; b ;; c ; d]" → formatted: "T[a b c d ]"   ← ncat lost
"@S[a; b]"          → formatted: "@S[a b ]"      ← macro matrix lost
```

## Root cause

1. The `";"` token inside `matrix_expression` is anonymous and being stripped by Topiary
2. There's no rule to preserve newlines between `matrix_row` nodes
3. The `matrix_row (_) @append_space` rule adds trailing spaces inside brackets

## Tree structure (tree-sitter-julia v0.23.1)

```
[x y; z w]  →  (matrix_expression
                  (matrix_row (identifier) (identifier))     ; x y
                  (matrix_row (identifier) (identifier)))    ; z w

[x; y; z]   →  (matrix_expression
                  (matrix_row (identifier))   ; x
                  (matrix_row (identifier))   ; y
                  (matrix_row (identifier)))  ; z
```

The `";"` and `"\n"` tokens between rows are anonymous (not named nodes).
Inside a `matrix_row`, spaces between elements are significant (they separate hcat elements).

## What to fix in julia.scm

1. **Semicolons between matrix rows**: Add `(matrix_expression ";" @append_space @prepend_space)` — but first verify `";"` is a valid token. If it's not addressable, use `(matrix_expression (matrix_row) @append_hardline)` to put each row on its own line, and add `";" @append_delimiter` somehow.

2. **Newlines between matrix rows**: Even without explicit `;`, newlines separate rows. Use `(matrix_expression (matrix_row) @append_hardline)` or `(matrix_row) @prepend_hardline` with sibling anchoring.

3. **Remove trailing space**: The `(matrix_row (_) @append_space)` rule adds a trailing space before `]`. This should only add space BETWEEN elements, not after the last one.

4. **Typed collections**: `T[x ; y]` parses as `(index_expression (identifier "T") (matrix_expression ...))` — same matrix_expression rules apply.

5. **Macro brackets**: `@S[a; b]` has `(macrocall_expression ... (matrix_expression ...))` — same fix applies.

## How to test

Add these to `tests/format_test.rs`:
```rust
format_test!(matrix_row_sep, "[x; y; z]\n", "[x; y; z]");
format_test!(matrix_2d, "[x y; z w]\n", "[x y; z w]");
format_test!(matrix_typed, "T[x; y]\n", "T[x; y]");
```

Run: `cargo test --test format_test` and `cargo test --test ast_equivalence_test`

## Key constraints

- Spaces WITHIN a matrix_row are semantic (separate hcat elements) — MUST preserve
- Semicolons/newlines BETWEEN rows are semantic — MUST preserve
- Don't add spaces/newlines that change the interpretation
