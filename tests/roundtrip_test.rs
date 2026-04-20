//! Round-trip tests against the tree-sitter-julia corpus.
//!
//! Each corpus snippet produces one independent `#[test]` via `build.rs`.
//! Listed entries in `tests/corpus/expectations.toml` flip a test into
//! "expected regression" mode.
//!
//! Run everything:     cargo test --test roundtrip_test
//! Target one file:    cargo test --test roundtrip_test rt_expressions
//! Target one case:    cargo test --test roundtrip_test rt_expressions_some_name

mod common;

include!(concat!(env!("OUT_DIR"), "/roundtrip_generated.rs"));
