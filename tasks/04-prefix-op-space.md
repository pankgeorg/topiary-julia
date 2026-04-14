# Task 4: Fix prefix operator spacing — preserve space between op and parens

## Problem

In Julia, space between a prefix operator and parentheses changes the parse:
- `+(a, b)` → function call: calls `+` with args `a`, `b`
- `+ (a, b)` → unary plus applied to tuple `(a, b)`

Similarly:
- `begin x end::T` → typed expression: the begin block has type annotation T
- `begin x end\n::T` → two separate expressions: begin block + standalone type annotation

Our formatter collapses spaces that are semantically significant.

## Failing cases

```
"+ (a,b)"          → "+(a, b)"           ← unary+tuple becomes function call
"begin x end::T"   → "begin\n    x\nend\n::T" ← typed block becomes two expressions
```

## Root cause

### Prefix op + tuple
The `(a, b)` after `+` is a `tuple_expression`. In the tree:
```
+ (a,b)  →  (unary_expression (operator "+") (tuple_expression ...))
```
After formatting, the space between `+` and `(` is removed, making it:
```
+(a, b)  →  (call_expression (operator "+") (argument_list ...))
```

### begin...end::T
The `::T` is parsed as part of a `typed_expression` wrapping the `compound_statement`:
```
begin x end::T  →  (typed_expression (compound_statement ...) (identifier "T"))
```
But our formatter puts a hardline after `end` (from the block rule), which breaks the typed_expression:
```
begin\n    x\nend\n::T  →  (compound_statement ...) (unary_typed_expression ...)
```

## What to fix in julia.scm

### Fix 1: Prefix operator + parenthesized expression
When a `unary_expression` has an operator followed by a `tuple_expression` or `parenthesized_expression`, preserve the space:

```scheme
;; Unary operator followed by parenthesized/tuple expression needs space
;; to prevent +(a,b) being parsed as a function call.
(unary_expression
  (operator) @append_space
  .
  (tuple_expression)
)
(unary_expression
  (operator) @append_space
  .
  (parenthesized_expression)
)
```

### Fix 2: Block type annotation
When a `typed_expression` contains a block (`compound_statement`), the `end` keyword must NOT get a hardline appended — the `::` must follow immediately:

```scheme
;; Don't hardline after "end" when block is inside typed_expression
(typed_expression
  (compound_statement) @do_nothing
)
```

Wait — `@do_nothing` cancels ALL captures from this query. That's too broad.

Alternative: in the compound_statement rule, don't append hardline to "end" when it's the child of a typed_expression. But tree-sitter queries can only look DOWN the tree, not UP at parents.

This may require: the block `end` rule should use `@append_empty_softline` instead of `@append_hardline`, or we need to mark certain "end" tokens differently.

This one is tricky. A pragmatic fix: mark `typed_expression` containing a `compound_statement` as `@leaf` to preserve the inner formatting. But that's too aggressive.

Simplest fix: just don't append hardline after "end" in compound_statement — the parent context's hardline will handle it. The compound_statement rule currently has `"end" @prepend_hardline @prepend_indent_end @append_hardline`. Remove the `@append_hardline`.

But this may break other cases where begin...end needs a trailing newline.

## How to test

```rust
format_test!(prefix_op_tuple, "+ (a, b)\n", "+ (a, b)");
format_test!(prefix_op_no_space, "+(a, b)\n", "+(a, b)");
format_test!(block_type_annotation, "begin x end::T\n", "begin\n    x\nend::T");
```

Run: `cargo test --test format_test` and `cargo test --test ast_equivalence_test`

## Key constraints

- Space between prefix op and parens is semantic — must preserve
- No-space between function name and parens must also be preserved
- Block end + type annotation must stay on the same line
- Other begin...end blocks should still get proper hardlines
