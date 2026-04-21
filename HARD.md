# Known hard grammar gaps

Issues from `tests/corpus/localized_gaps.toml` that resisted a quick
grammar fix during the methodical iteration. Each entry notes the
probe, the root cause as far as we got, and what we'd try on a dedicated
pass. Deferred to avoid burning the "at most two fixes per iteration"
budget on things that need restructuring.

## Single-character rejects (`$`, `'`, `.`, `·`)

Explicitly out of scope per user direction — these tokens are lexically
ambiguous standalone. Any "fix" would shadow their real grammatical
roles (interpolation, adjoint, field access, dot-operator).

## Unary `&x`

**Attempted 2026-04-20** in two ways:
1. Adding `&` to `OPERATORS.unary`.
2. Dedicated `_unary_amp_operator = addDot('&')` token following the
   `_unary_plus_operator` precedent, wired into both `unary_expression`
   and the binary-times rule's `choice(...)`.

Both caused `tree-sitter generate` to spiral (RAM climbing to 4+ GB,
LR state explosion). `&` is in `OPERATORS.times` (binary) and needs a
different contextual-emission strategy (probably via the external
scanner) because of how often binary `&` appears in real code.

**Next time**: probably needs an external-scanner token that only
emits unary-`&` at statement start / after `(` or `,`.

## Macro in `do`-body without leading `;`

Example: `f(xs) do x @inline; x end`. Currently splits the `@inline`
from `x` in the wrong direction (macro_argument_list eagerly swallows
`;x` as a second arg).

`do_clause` has four `prec.dynamic` branches that distinguish
params-only, single-body, multi-body via terminator. Adjusting them to
allow "params, block-body, end" without a required terminator conflicts
with the existing single-line form `do y body end`. Needs a more
careful restructure of do_clause plus possibly a conflict entry to
keep both readings alive.

## Lvalue-shaped literal compound assignment

Examples: `1 ≔ 2`, `1 ≕ 2`, `1 ⩴ 2`, `1 := 2`.

JuliaSyntax parses these as generic binary operations (`(:= 1 2)`) — a
syntactic parse; Julia rejects them at lowering. Our grammar treats
assignment operators specifically and requires an lvalue on the left.
Relaxing to "any expression on both sides" for these operators would
touch `compound_assignment_expression` and probably knock the short
function-def vs. generic-assign disambiguation over. Sizeable
refactor.

## Emoji interpolation `$🏡`

U+1F3E1 is a supplementary-plane codepoint outside `soSymbols` BMP
ranges. Adding SMP emoji would need either extending the external
scanner's `is_smp_so_identifier` table to cover the emoji blocks we
care about, or a broader grammar-level hex escape. Low-priority
until real code needs it.

## Numeric `primitive type` name

Examples:
  `primitive type 0 SPJa12023 end`
  `primitive type -4294967280 SPJc12023 end`

The JuliaSyntax test corpus exercises weird edge cases. Literal
integer as the "name" position is deliberately atypical Julia and
probably not worth mirroring.

## Adjoint edge: `' ''' == "'"[1]`

Mixed `'` (character literal quote), triple-quoted string, adjoint.
The external scanner logic for `'` is already delicate (adjoint vs
char literal vs triple-char). Skipping until someone cares.

## Scoped macro symbol `:@A.foo`

Accepted the narrower `:@m` form in commit `491f0cb`; the scoped
`_scoped_identifier` branch exploded parser.c past GitHub's 100 MB
limit. Use `:(@A.foo)` as a parse-equivalent workaround.

## Ternary with newline before `:`

Example: `a ? b\n: c`, `iseven(l) ? x\n: y`.

Attempted 2026-04-21 with `optional($._terminator)` inserted between the
then-branch and `_ternary_colon`. Generated cleanly, but the parse
flipped to `range_expression` — the external scanner only emits
`TERNARY_COLON` while the ternary state is live, and consuming a
terminator token takes the parser out of that state, so the next `:`
surfaces as a spaced range colon. Fixing this needs scanner-side
state tracking (a "ternary_depth" counter that persists across
terminators), not a grammar-only change. Reverted.

## Very-long multi-line edge cases (~20 snippets)

Large families under `localized_gaps.toml` that are likely the same
root cause in different wrapping (`@nospecialize(x) -> ...` arrow at
macro-arg position, typed-indexed compound assignment
`x[1]::Int += 1`, etc.). Candidates for a dedicated "macro-arg arrow"
and "typed lvalue" passes, not one-shot fixes.
