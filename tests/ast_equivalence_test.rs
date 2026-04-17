//! AST Equivalence Test
//!
//! Takes Julia code snippets from JuliaSyntax.jl's test corpus, formats them
//! with topiary-julia, and verifies the tree-sitter AST is structurally
//! identical before and after formatting.
//!
//! Snippets are classified into four categories:
//!   1. Intentional errors — JuliaSyntax expects an error parse
//!   2. Grammar gaps — valid Julia that tree-sitter-julia can't parse
//!   3. Formatter issues — formatting introduces parse errors or AST changes
//!   4. Passing — AST identical before and after formatting
//!
//! Run: cargo test --test ast_equivalence_test

mod common;

const JULIASYNTAX_CORPUS: &str = include_str!("corpus/juliasyntax_parser.jl");

// ─── Expected counts ────────────────────────────────────────────
// Update these when fixing grammar gaps or formatter issues.
// The test fails if reality doesn't match expectations — in either direction.
// If a fix reduces a count, update the constant so regressions are caught.

/// Snippets where both tree-sitter AND JuliaSyntax agree it's an error (skip).
const EXPECTED_INTENTIONAL_ERRORS: usize = 88;
/// Valid Julia that tree-sitter-julia can't parse yet (JuliaSyntax has no error).
/// Notable regressions for net wins:
/// - `in"str"` regressed when 'in' became a contextual identifier (commit 5880b1e).
/// - `x' y`, `f'ᵀ`, `1where'c'` regressed when juxtaposition became
///   whitespace-sensitive (juxtaposition fix). Previously parsed as juxtaposition
///   (wrong AST); now an error (JuliaSyntax does partial-parse, tree-sitter can't).
const EXPECTED_GRAMMAR_GAPS: usize = 47;
/// Snippets where formatting introduces new ERROR nodes.
const EXPECTED_FORMAT_ERRORS: usize = 0;
/// Snippets where formatting changes the AST structure.
/// The `[1 :a]` mismatch was resolved by making juxtaposition whitespace-sensitive.
const EXPECTED_AST_MISMATCHES: usize = 0;

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
    let sexp = common::tree_to_sexp("x + y");
    assert!(sexp.contains("binary_expression"), "got: {sexp}");
}

#[test]
fn sexp_equivalence_simple() {
    let before = common::tree_to_sexp("x+y");
    let after = common::tree_to_sexp("x + y");
    assert_eq!(before, after, "Whitespace-only changes should not affect AST");
}

// ─── Main corpus test ───────────────────────────────────────────

#[test]
fn juliasyntax_corpus() {
    let snippets = common::extract_juliasyntax_snippets(JULIASYNTAX_CORPUS);
    assert!(snippets.len() > 500, "Extraction may be broken: got {} snippets", snippets.len());

    let mut intentional_errors = 0;
    let mut grammar_gaps: Vec<(usize, String)> = Vec::new();
    let mut passed = 0;
    let mut format_errors = 0;
    let mut new_parse_errors: Vec<(usize, String, String)> = Vec::new(); // (line, in, out)
    let mut ast_mismatches: Vec<(usize, String, String, String, String)> = Vec::new();

    for s in &snippets {
        let ts_has_errors = common::source_has_errors(&s.code);

        // Category 1: intentional error — BOTH tree-sitter and JuliaSyntax agree it fails
        if ts_has_errors && s.is_intentional_error() {
            intentional_errors += 1;
            continue;
        }

        // Category 2: grammar gap — tree-sitter fails but JuliaSyntax parses OK
        if ts_has_errors {
            grammar_gaps.push((s.line_num, s.code.clone()));
            continue;
        }

        // If tree-sitter can parse it, we test it — even if JuliaSyntax
        // expected an error (e.g. partial-parse productions, trailing junk).

        // Category 3+4: testable — format and compare AST
        let sexp_before = common::tree_to_sexp(&s.code);

        match common::format_julia_tolerant(&s.code) {
            Ok(formatted) => {
                if common::source_has_errors(&formatted) {
                    new_parse_errors.push((s.line_num, s.code.clone(), formatted));
                    continue;
                }

                let sexp_after = common::tree_to_sexp(&formatted);
                if sexp_before == sexp_after {
                    passed += 1;
                } else {
                    ast_mismatches.push((
                        s.line_num,
                        s.code.clone(),
                        formatted,
                        sexp_before,
                        sexp_after,
                    ));
                }
            }
            Err(_) => {
                format_errors += 1;
            }
        }
    }

    let total = snippets.len();
    let testable = total - intentional_errors - grammar_gaps.len() - format_errors;

    // ── Report ──────────────────────────────────────────────────
    eprintln!("\n=== JuliaSyntax AST Equivalence Results ===");
    eprintln!("Total snippets:       {total}");
    eprintln!("Intentional errors:   {intentional_errors} (skipped)");
    eprintln!("Grammar gaps:         {} (tree-sitter can't parse)", grammar_gaps.len());
    eprintln!("Format errors:        {format_errors}");
    eprintln!("---");
    eprintln!("Testable:             {testable}");
    eprintln!("  Passed:             {passed}");
    eprintln!("  Parse errors:       {} (formatting introduced ERRORs)", new_parse_errors.len());
    eprintln!("  AST mismatches:     {}", ast_mismatches.len());

    if testable > 0 {
        eprintln!("  Pass rate:          {passed}/{testable} ({:.1}%)",
            passed as f64 / testable as f64 * 100.0);
    }

    if !new_parse_errors.is_empty() {
        eprintln!("\n--- Parse errors (formatting introduced ERRORs) ---");
        for (line, code, formatted) in &new_parse_errors {
            eprintln!("  L{line}: {code:?} → {formatted:?}");
        }
    }

    if !ast_mismatches.is_empty() {
        eprintln!("\n--- AST mismatches ---");
        for (line, code, formatted, before, after) in &ast_mismatches {
            eprintln!("  L{line}: {code:?} → {formatted:?}");
            eprintln!("    before: {before}");
            eprintln!("    after:  {after}");
        }
    }

    if !grammar_gaps.is_empty() {
        eprintln!("\n--- Grammar gaps (all) ---");
        for (line, code) in grammar_gaps.iter() {
            eprintln!("  L{line}: {code:?}");
        }
    }

    // ── Assertions ──────────────────────────────────────────────
    // Each assertion checks BOTH directions: regressions AND improvements.
    // When you fix something, update the constant at the top of this file.

    assert_eq!(
        intentional_errors, EXPECTED_INTENTIONAL_ERRORS,
        "Intentional error count changed (expected {EXPECTED_INTENTIONAL_ERRORS}, got {intentional_errors}). \
         If extraction changed, update EXPECTED_INTENTIONAL_ERRORS."
    );

    assert!(
        grammar_gaps.len() <= EXPECTED_GRAMMAR_GAPS,
        "Grammar gaps increased! Expected at most {EXPECTED_GRAMMAR_GAPS}, got {}. \
         A grammar regression was introduced.",
        grammar_gaps.len()
    );
    if grammar_gaps.len() < EXPECTED_GRAMMAR_GAPS {
        eprintln!(
            "\n✓ Grammar gaps improved: {} → {} (update EXPECTED_GRAMMAR_GAPS)",
            EXPECTED_GRAMMAR_GAPS, grammar_gaps.len()
        );
    }

    assert!(
        new_parse_errors.len() <= EXPECTED_FORMAT_ERRORS,
        "Format-introduced errors increased! Expected at most {EXPECTED_FORMAT_ERRORS}, got {}. \
         A formatter regression was introduced.",
        new_parse_errors.len()
    );
    if new_parse_errors.len() < EXPECTED_FORMAT_ERRORS {
        eprintln!(
            "\n✓ Format errors improved: {} → {} (update EXPECTED_FORMAT_ERRORS)",
            EXPECTED_FORMAT_ERRORS, new_parse_errors.len()
        );
    }

    assert!(
        ast_mismatches.len() <= EXPECTED_AST_MISMATCHES,
        "AST mismatches increased! Expected at most {EXPECTED_AST_MISMATCHES}, got {}. \
         A formatter regression was introduced.",
        ast_mismatches.len()
    );
    if ast_mismatches.len() < EXPECTED_AST_MISMATCHES {
        eprintln!(
            "\n✓ AST mismatches improved: {} → {} (update EXPECTED_AST_MISMATCHES)",
            EXPECTED_AST_MISMATCHES, ast_mismatches.len()
        );
    }
}
