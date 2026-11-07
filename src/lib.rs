//! Library surface used by the `topiary-julia` binary and the integration
//! tests. Keeps parser setup + error-detection helpers in one place so the
//! CLI and the test suite agree on what counts as a parse error.

pub mod sexp;

/// Julia's own parser (JuliaSyntax in Wasm, on wasmtime).
#[cfg(feature = "jlparse")]
pub mod jlparse;

/// Formatting verified by JuliaSyntax, with grammar gaps protected.
#[cfg(feature = "jlparse")]
pub mod format;
