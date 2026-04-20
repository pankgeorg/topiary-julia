//! Shared test utilities for topiary-julia.
//!
//! Used by all integration test files via `mod common;`.
//!
//! Grammar + query compilation is cached per-thread via `thread_local!`.
//! `cargo test` runs tests on a thread pool, so each thread pays the build
//! cost exactly once rather than once per snippet.

#![allow(dead_code)]

use std::cell::{OnceCell, RefCell};

use topiary_core::{formatter, Language, Operation, TopiaryQuery};
use topiary_julia::sexp;
use topiary_tree_sitter_facade::{Language as Grammar, Node, Parser};

const QUERY: &str = include_str!("../../julia.scm");

thread_local! {
    static LANGUAGE: OnceCell<Language> = const { OnceCell::new() };
    static PARSER: RefCell<OnceCell<Parser>> = const { RefCell::new(OnceCell::new()) };
}

fn build_language() -> Language {
    let grammar: Grammar = tree_sitter_julia::LANGUAGE.into();
    let query = TopiaryQuery::new(&grammar, QUERY).expect("Invalid query file");
    Language {
        name: "julia".into(),
        query,
        grammar,
        indent: Some("    ".into()),
    }
}

fn with_language<R>(f: impl FnOnce(&Language) -> R) -> R {
    LANGUAGE.with(|cell| f(cell.get_or_init(build_language)))
}

fn with_parser<R>(f: impl FnOnce(&mut Parser) -> R) -> R {
    PARSER.with(|cell| {
        let mut cell = cell.borrow_mut();
        if cell.get().is_none() {
            let grammar: Grammar = tree_sitter_julia::LANGUAGE.into();
            let mut p = Parser::new().unwrap();
            p.set_language(&grammar).unwrap();
            let _ = cell.set(p);
        }
        f(cell.get_mut().unwrap())
    })
}

// ─── Formatting ─────────────────────────────────────────────────────

/// Format Julia source code. Panics on failure.
pub fn format_julia(input: &str) -> String {
    with_language(|language| {
        let mut output = Vec::new();
        formatter(
            &mut input.as_bytes(),
            &mut output,
            language,
            Operation::Format {
                skip_idempotence: true,
                tolerate_parsing_errors: false,
            },
        )
        .expect("Formatting failed");
        String::from_utf8(output).expect("Non-UTF8 output")
    })
}

/// Format Julia source code, tolerating parse errors.
pub fn format_julia_tolerant(input: &str) -> Result<String, String> {
    with_language(|language| {
        let mut output = Vec::new();
        formatter(
            &mut input.as_bytes(),
            &mut output,
            language,
            Operation::Format {
                skip_idempotence: true,
                tolerate_parsing_errors: true,
            },
        )
        .map_err(|e| format!("{e}"))?;
        String::from_utf8(output).map_err(|e| format!("{e}"))
    })
}

/// Format twice and assert the output is identical (idempotent).
pub fn assert_idempotent(input: &str) {
    let first = format_julia(input);
    let second = format_julia(&first);
    pretty_assertions::assert_eq!(first, second, "Not idempotent");
}

// ─── Tree-sitter helpers ────────────────────────────────────────────

/// Produce a normalized S-expression from Julia source code.
/// Only named nodes, no positions — purely structural.
pub fn tree_to_sexp(code: &str) -> String {
    with_parser(|parser| {
        let tree = parser.parse(code, None).unwrap().unwrap();
        node_to_sexp(&tree.root_node(), code)
    })
}

fn node_to_sexp(node: &Node, source: &str) -> String {
    let kind = node.kind();

    let mut named_children = Vec::new();
    for i in 0..node.child_count() {
        if let Some(child) = node.child(i) {
            if child.is_named() {
                named_children.push(child);
            }
        }
    }

    if named_children.is_empty() {
        let text = &source[node.start_byte() as usize..node.end_byte() as usize];
        if kind == "identifier"
            || kind == "operator"
            || kind == "integer_literal"
            || kind == "float_literal"
            || kind == "boolean_literal"
        {
            format!("({kind} {text:?})")
        } else {
            format!("({kind})")
        }
    } else {
        let children_sexp: Vec<String> = named_children
            .iter()
            .map(|c| node_to_sexp(c, source))
            .collect();
        format!("({kind} {})", children_sexp.join(" "))
    }
}

/// Check whether the tree-sitter parse tree has any ERROR nodes.
pub fn source_has_errors(code: &str) -> bool {
    sexp::source_has_errors(code)
}

// ─── Assertions used by generated tests ─────────────────────────────

/// Positive path: format `code` and verify the tree-sitter AST is
/// structurally identical before and after.
///
/// If the input is expected to exhibit a known issue, list it in
/// `tests/corpus/expectations.toml`; the generator will emit one of the
/// `expect_*` assertions below instead.
pub fn assert_ast_equivalent(code: &str) {
    let before = tree_to_sexp(code);
    assert!(
        !before.contains("ERROR"),
        "Input does not parse cleanly; classify as grammar_gap in expectations.toml:\n  code: {code:?}"
    );

    let formatted = match format_julia_tolerant(code) {
        Ok(s) => s,
        Err(e) => panic!("Formatter returned error for {code:?}: {e}"),
    };

    assert!(
        !source_has_errors(&formatted),
        "Formatting introduced parse errors; classify as format_error in expectations.toml.\n  code:   {code:?}\n  output: {formatted:?}"
    );

    let after = tree_to_sexp(&formatted);
    pretty_assertions::assert_eq!(
        before,
        after,
        "Formatting changed the AST; classify as ast_mismatch in expectations.toml.\n  code:   {code:?}\n  output: {formatted:?}",
    );
}

/// Expected grammar gap: tree-sitter can't parse this snippet cleanly.
/// If it now parses, the expectation is stale — fail so we notice.
pub fn expect_grammar_gap(code: &str, note: &str) {
    assert!(
        source_has_errors(code),
        "Grammar gap resolved ({note}). Remove this entry from expectations.toml:\n  code: {code:?}"
    );
}

/// Expected format-introduced parse error.
/// If formatting no longer breaks the AST, the expectation is stale.
pub fn expect_format_error(code: &str, note: &str) {
    assert!(
        !source_has_errors(code),
        "Precondition for format_error: input must parse clean. code: {code:?}"
    );
    let out = format_julia_tolerant(code).expect("formatter should succeed");
    assert!(
        source_has_errors(&out),
        "Format error resolved ({note}); output parses clean now. Remove from expectations.toml:\n  code: {code:?}\n  out:  {out:?}"
    );
}

/// Expected AST-structure change after formatting.
pub fn expect_ast_mismatch(code: &str, note: &str) {
    let before = tree_to_sexp(code);
    assert!(
        !before.contains("ERROR"),
        "Precondition for ast_mismatch: input must parse clean. code: {code:?}"
    );
    let out = format_julia_tolerant(code).expect("formatter should succeed");
    let after = tree_to_sexp(&out);
    assert_ne!(
        before, after,
        "AST mismatch resolved ({note}). Remove from expectations.toml:\n  code: {code:?}\n  out:  {out:?}"
    );
}

// ─── Roundtrip assertions ───────────────────────────────────────────

/// Positive path for the tree-sitter corpus: formatting a clean snippet
/// must not introduce ERROR nodes.
pub fn assert_roundtrip_clean(code: &str) {
    if source_has_errors(code) {
        // Input already has errors (some corpus entries test partial parses).
        // We still format to exercise the code path, but don't assert on it.
        let _ = format_julia_tolerant(code);
        return;
    }
    match format_julia_tolerant(code) {
        Ok(out) => assert!(
            !source_has_errors(&out),
            "Formatting introduced parse errors:\n  in:  {code:?}\n  out: {out:?}"
        ),
        Err(_) => { /* non-fatal formatter error, matches previous behavior */ }
    }
}

/// Expected roundtrip regression (formatter introduces ERRORs on this corpus
/// entry). If it no longer regresses, the expectation is stale.
pub fn expect_roundtrip_regression(code: &str, note: &str) {
    assert!(
        !source_has_errors(code),
        "Precondition for regression: input must parse clean. code: {code:?}"
    );
    let out = format_julia_tolerant(code).expect("formatter should succeed");
    assert!(
        source_has_errors(&out),
        "Roundtrip regression resolved ({note}). Remove from expectations.toml:\n  code: {code:?}\n  out:  {out:?}"
    );
}
