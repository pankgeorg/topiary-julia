# Task 5: Fix formatting-introduced parse errors

## Problem

3 snippets from the JuliaSyntax corpus produce parse errors AFTER formatting but not before:

```
"f(x) = 1 = 2"                  → "f(x) = 1 = 2\n"       ← ERROR
"for x in xs, y in ys \n a \n end" → "for x in xs\n    ,y in ys\n    a\nend\n" ← ERROR
"try x end"                      → "try\n    x\nend\n"     ← ERROR
```

## Case 1: `f(x) = 1 = 2`

This is a chained assignment in a short function definition. The input parses cleanly (though it's semantically questionable Julia). The formatted output is identical to the input except for trailing newline, so the ERROR might be a tree-sitter-julia parser issue rather than a formatting issue. Verify by checking the sexp of both.

## Case 2: `for x in xs, y in ys`

This is the known multi-binding for loop issue. The formatted output moves the comma to the next line: `for x in xs\n    ,y in ys`. The leading comma on a new line is apparently not valid Julia (or at least tree-sitter-julia can't parse it). This is a variant of the multi-binding for issue from Task 1 context.

The fix: the comma must stay on the same line as the preceding binding. This requires fixing the for_statement hardline rules so that for_binding nodes don't get hardlines between them when separated by commas.

This was previously investigated — the `(_) @append_hardline` blanket rule fires on for_binding and pushes the comma down. Options:
- Remove the blanket and use specific body-expression patterns
- Or accept multi-binding for as a known limitation

## Case 3: `try x end`

Single-line try: `try x end`. The formatter converts it to multi-line:
```
try
    x
end
```

If this introduces a parse error, it might be because the formatter is generating something slightly different than expected. Verify the exact output and check if the tree-sitter parser accepts it. The multi-line form should be valid Julia.

## What to fix

### Case 1
Likely a non-issue — verify the sexp is the same. If the input already has an ERROR node at a different position, it should be caught by the `skipped_parse_error` filter. Check if the tree comparison is overly sensitive.

### Case 2
Fix the for_statement comma handling. The most robust approach:
- In the for_statement `"for" @append_indent_start` rule, the indent captures "for" and everything after it
- The `(_) @append_hardline` fires on every named child INCLUDING for_binding
- Need to NOT hardline between consecutive for_binding nodes

Since we can't filter by type in tree-sitter queries, the workaround:
- Remove `(for_statement (_) @append_hardline)`
- Add specific rules for body expressions (not for_binding)
- Or add `(for_statement (for_binding) @append_hardline)` which fires on ALL for_bindings, but then also add some mechanism to suppress the hardline when followed by a comma

### Case 3
Verify the formatted output parses cleanly by manual inspection. If `try\n    x\nend\n` parses cleanly in tree-sitter-julia, the issue may be in the test infrastructure.

## How to test

```rust
format_test!(try_single_line, "try x end\n", "try\n    x\nend");
format_test!(for_multi_binding_comma, "for x in xs, y in ys\na\nend\n", 
    "for x in xs, y in ys\n    a\nend");  // ideal, may need compromise
```

Run: `cargo test --test format_test` and `cargo test --test ast_equivalence_test`

## Key constraints

- Don't introduce parse errors — this is the most critical test
- Multi-binding for is the hardest sub-problem here
- Single-line try/catch/begin should format to multi-line without errors
