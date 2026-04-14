# Task 2: Fix macro call forms — preserve paren/bracket attachment

## Problem

In Julia, macro call forms are space-sensitive. The presence or absence of space between the macro name and its argument delimiter changes the parse tree:

- `@x(a, b)` → calls macro `x` with args `a, b` (parsed as `argument_list`)
- `@x (a, b)` → calls macro `x` with one arg: the tuple `(a, b)` (parsed as `macro_argument_list`)
- `@x[a, b]` → calls macro `x` with a vector `[a, b]`
- `@x [a, b]` → calls macro `x` with one arg: the vector `[a, b]`
- `@x a b` → calls macro `x` with space-separated args `a`, `b` (parsed as `macro_argument_list`)

Our formatter MUST NOT insert or remove spaces between `@macro_name` and `(`, `[`, `{`.

## Failing cases

```
"@foo a b"     → "@foo ab"     ← args merge (macro_argument_list children need space)
"@doc x y\nz"  → "@doc xy\nz"  ← same issue
"@A.foo a b"   → "@A.foo ab"   ← qualified macro, same issue
"A.@foo a b"   → "A.@foo ab"   ← dotted macro, same issue
"@+x y"        → "@+x y"       ← may or may not work
```

## Root cause

The current rule adds space after `macro_identifier` when followed by `macro_argument_list`:
```scheme
(macrocall_expression
  (macro_identifier) @append_space
  .
  (macro_argument_list)
)
```

And `macro_argument_list` children get space via:
```scheme
(macro_argument_list (_) @append_space)
```

But the `@append_space` on every child of `macro_argument_list` adds a trailing space after the LAST child too. We need spaces BETWEEN children, not after each one.

## Tree structure

```
@foo a b    → (macrocall_expression
                (macro_identifier (identifier))
                (macro_argument_list (identifier) (identifier)))

@x(a, b)   → (macrocall_expression
                (macro_identifier (identifier))
                (argument_list (identifier) (identifier)))

@doc "str" expr → (macrocall_expression
                     (macro_identifier (identifier))
                     (macro_argument_list (string_literal) (identifier)))
```

## What to fix in julia.scm

1. **Fix macro_argument_list spacing**: Replace `(macro_argument_list (_) @append_space)` with sibling-aware spacing that doesn't add trailing space. Options:
   - `(macro_argument_list (_) . (_) @prepend_space)` — space before each child after the first
   - Or keep `(_) @append_space` but use `@prepend_antispace` on the closing context

2. **Verify no-space forms preserved**: Ensure `@x(a,b)`, `@x[a,b]`, `@x{a,b}` do NOT get spaces inserted before parens/brackets/braces. The current rule only fires when followed by `macro_argument_list`, which is correct.

3. **Qualified macros**: `A.@foo a b` and `@A.foo a b` — the dotted forms need the same treatment.

## How to test

```rust
format_test!(macro_space_args, "@foo a b\n", "@foo a b");
format_test!(macro_paren_call, "@x(a, b)\n", "@x(a, b)");
format_test!(macro_doc, "@doc \"help\" f\n", "@doc \"help\" f");
format_test!(macro_qualified, "A.@foo a b\n", "A.@foo a b");
```

Run: `cargo test --test format_test` and `cargo test --test ast_equivalence_test`

## Key constraints

- NEVER insert space between `@name` and `(`, `[`, `{`, or `"`
- Space-separated args need spaces BETWEEN them (not trailing)
- The macro call form (paren vs bracket vs space) must be preserved exactly
