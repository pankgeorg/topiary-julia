//! AST equivalence tests.
//!
//! Each JuliaSyntax.jl corpus snippet produces one independent `#[test]`
//! function via `build.rs`. Listed expectations in
//! `tests/corpus/expectations.toml` flip a test into an "expected failure"
//! mode that asserts the known issue still reproduces; remove the entry
//! when the underlying issue is fixed.
//!
//! Run everything:            cargo test --test ast_equivalence_test
//! Target one snippet:        cargo test --test ast_equivalence_test ast_line_0142
//! Target a line range:       cargo test --test ast_equivalence_test ast_line_01
//! Target expected failures:  cargo test --test ast_equivalence_test grammar_gap

mod common;

include!(concat!(env!("OUT_DIR"), "/ast_equivalence_generated.rs"));
