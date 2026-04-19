//! Library surface used by the `topiary-julia` binary and the integration
//! tests. Keeps parser setup + error-detection helpers in one place so the
//! CLI and the test suite agree on what counts as a parse error.

pub mod sexp;
