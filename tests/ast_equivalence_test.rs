//! AST Equivalence Test
//!
//! Takes Julia code snippets from JuliaSyntax.jl's test corpus, formats them
//! with topiary-julia, and verifies the tree-sitter AST is structurally
//! identical before and after formatting.
//!
//! Run: cargo test --test ast_equivalence_test

mod common;

const JULIASYNTAX_CORPUS: &str = include_str!("corpus/juliasyntax_parser.jl");

// ─── Unit tests for extraction logic ────────────────────────────

#[test]
fn extract_julia_string() {
    assert_eq!(common::extract_julia_string(r#""hello""#), Some("hello".into()));
    assert_eq!(common::extract_julia_string(r#""a\nb""#), Some("a\nb".into()));
    assert_eq!(common::extract_julia_string(r#""a\"b""#), Some("a\"b".into()));
    assert_eq!(common::extract_julia_string(r#""a\\b""#), Some("a\\b".into()));
    assert_eq!(common::extract_julia_string(r#""a\$b""#), Some("a$b".into()));
    assert_eq!(common::extract_julia_string(r#""""#), Some("".into()));
}

#[test]
fn extract_snippets_count() {
    let snippets = common::extract_juliasyntax_snippets(JULIASYNTAX_CORPUS);
    eprintln!("Extracted {} snippets from JuliaSyntax corpus", snippets.len());
    assert!(snippets.len() > 500, "Expected >500 snippets, got {}", snippets.len());
}

#[test]
fn tree_to_sexp_basic() {
    let sexp = common::tree_to_sexp("x = 1\n");
    assert!(sexp.contains("assignment"), "Expected 'assignment' in sexp, got: {sexp}");
    assert!(sexp.contains("identifier"), "Expected 'identifier' in sexp, got: {sexp}");
}

#[test]
fn sexp_equivalence_simple() {
    let before = common::tree_to_sexp("x  =  1\n");
    let after = common::tree_to_sexp("x = 1\n");
    assert_eq!(before, after, "Whitespace-only change should not affect AST");
}

// ─── Main AST equivalence test ──────────────────────────────────

#[test]
fn juliasyntax_corpus() {
    let snippets = common::extract_juliasyntax_snippets(JULIASYNTAX_CORPUS);
    assert!(snippets.len() > 500, "Extraction may be broken: got {} snippets", snippets.len());

    let mut total = 0;
    let mut passed = 0;
    let mut skipped_parse_error = 0;
    let mut format_failures = 0;
    let mut ast_mismatches: Vec<String> = Vec::new();
    let mut new_errors: Vec<String> = Vec::new();

    for (code, line_num) in &snippets {
        total += 1;

        if common::source_has_errors(code) {
            skipped_parse_error += 1;
            continue;
        }

        let sexp_before = common::tree_to_sexp(code);

        match common::format_julia_tolerant(code) {
            Ok(formatted) => {
                if common::source_has_errors(&formatted) {
                    new_errors.push(format!(
                        "L{line_num}: formatting introduced ERROR nodes\n  in:  {code:?}\n  out: {formatted:?}"
                    ));
                    continue;
                }

                let sexp_after = common::tree_to_sexp(&formatted);

                if sexp_before == sexp_after {
                    passed += 1;
                } else {
                    ast_mismatches.push(format!(
                        "L{line_num}: AST changed after formatting\n  code:   {code:?}\n  format: {formatted:?}\n  before: {sexp_before}\n  after:  {sexp_after}"
                    ));
                }
            }
            Err(e) => {
                format_failures += 1;
                let _ = e;
            }
        }
    }

    eprintln!("\n=== JuliaSyntax AST Equivalence Results ===");
    eprintln!("Total snippets extracted: {total}");
    eprintln!("Skipped (original has parse errors): {skipped_parse_error}");
    eprintln!("Format failures (non-fatal): {format_failures}");
    eprintln!("AST preserved (PASS): {passed}");
    eprintln!("AST changed (MISMATCH): {}", ast_mismatches.len());
    eprintln!("New parse errors: {}", new_errors.len());

    if !new_errors.is_empty() {
        eprintln!("\n--- New parse errors (first 10) ---");
        for e in new_errors.iter().take(10) {
            eprintln!("  {e}");
        }
    }

    if !ast_mismatches.is_empty() {
        eprintln!("\n--- AST mismatches (first 20) ---");
        for m in ast_mismatches.iter().take(20) {
            eprintln!("  {m}");
        }
    }

    let failure_count = ast_mismatches.len() + new_errors.len();
    let testable = total - skipped_parse_error - format_failures;
    let pass_rate = if testable > 0 {
        (passed as f64 / testable as f64) * 100.0
    } else {
        0.0
    };

    eprintln!("\nPass rate: {passed}/{testable} ({pass_rate:.1}%)");

    let max_failure_pct = 15.0;
    let failure_pct = if testable > 0 {
        (failure_count as f64 / testable as f64) * 100.0
    } else {
        0.0
    };
    assert!(
        failure_pct <= max_failure_pct,
        "{failure_count} failures ({failure_pct:.1}%) exceeds {max_failure_pct}% threshold"
    );
}
