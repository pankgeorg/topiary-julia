//! Localized tree-sitter-julia parse-failure tests.
//!
//! Generated from `tests/corpus/localized_gaps.toml` by `build.rs`. The
//! TOML itself is produced by `corpus/minimize_gaps.jl`, which takes
//! Julia files from `corpus/fixtures/` (and optionally the real-world
//! package corpus) and bisects each tree-sitter-julia parse failure
//! down to the minimal sub-expression that still triggers the error.
//!
//! Each test asserts the minimal snippet STILL fails to parse. If the
//! grammar improves, the test flips red with `resolved` — delete the
//! entry from `localized_gaps.toml` and regenerate.
//!
//! Run everything:     cargo test --test localized_gaps_test
//! Target one case:    cargo test --test localized_gaps_test ts_gap_0003

mod common;

include!(concat!(env!("OUT_DIR"), "/localized_gaps_generated.rs"));
