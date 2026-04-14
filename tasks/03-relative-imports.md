# Task 3: Fix relative import dots — preserve `.`, `..`, `...` prefixes

## Problem

Julia relative imports use dots to indicate parent modules:
- `import .A` → import from current module
- `import ..A` → import from parent module
- `import ...A` → import from grandparent
- `import ....A` → etc.

Our formatter strips the dots entirely: `import ..A` → `import A`.

## Failing cases

```
"import .A"    → "import A"    ← dots stripped
"import ..A"   → "import A"    ← dots stripped
"import ...A"  → "import A"    ← dots stripped
"import ....A" → "import A"    ← dots stripped
"import .â‹†"   → "import â‹†"  ← Unicode identifier, dots still stripped
```

## Root cause

The `"."` tokens inside `import_path` are anonymous tokens. Topiary strips all whitespace and anonymous tokens that don't have explicit formatting rules. Since `"."` is not addressable as a token in this grammar version (we tried `(import_path "." @append_antispace)` and got a query parse error), the dots are silently removed.

## Tree structure

```
import ..A  →  (import_statement
                 (import_path
                   (identifier "A")))
```

The dots are anonymous `"."` children of `import_path`, but tree-sitter-julia v0.23.1 doesn't expose them as addressable tokens in queries.

## What to fix

This is a hard problem because the dots are not addressable. Options:

### Option A: Mark import_path as @leaf
```scheme
(import_path) @leaf
```
This preserves everything inside import_path as-is, including dots. But it also prevents any formatting of the identifier or nested structure.

### Option B: Mark import_path as @leaf only when it contains dots
Not possible — we can't conditionally check for anonymous token presence.

### Option C: Use @keep_whitespace on import_path
Topiary has `@keep_whitespace` which preserves trailing whitespace on leaf nodes. This might help but is designed for different cases.

### Option D: Upgrade to tree-sitter-julia v0.25.0
The v0.25.0 grammar might expose `"."` as an addressable token. This would require changing the git dependency in Cargo.toml.

### Recommended: Option A
Mark `import_path` as `@leaf` to preserve its content entirely. The trade-off is we can't format inside import paths, but import paths are short and don't need formatting.

Check if `selected_import` and `import_alias` are affected too — we might need:
```scheme
(import_path) @leaf
```

## How to test

```rust
format_test!(import_relative_single, "import .A\n", "import .A");
format_test!(import_relative_double, "import ..A\n", "import ..A");
format_test!(import_relative_triple, "import ...A\n", "import ...A");
format_test!(import_relative_quad, "import ....A\n", "import ....A");
format_test!(import_dotted_path, "import Foo.Bar\n", "import Foo.Bar");
```

Run: `cargo test --test format_test` and `cargo test --test ast_equivalence_test`

## Key constraints

- Dots must be preserved exactly (count matters)
- No spaces should be inserted between dots or between dots and identifier
- Regular dotted paths (`Foo.Bar`) should also be preserved
- `selected_import` (e.g., `import Base: show, print`) should still get comma spacing
