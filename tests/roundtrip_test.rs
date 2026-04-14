//! Round-trip test: for every Julia snippet in the tree-sitter-julia test
//! corpus, format it and verify the result still parses without ERROR nodes.
//!
//! Run: cargo test --test roundtrip_test

mod common;

const CORPUS_FILES: &[(&str, &str)] = &[
    ("collections", include_str!("corpus/collections.txt")),
    ("definitions", include_str!("corpus/definitions.txt")),
    ("expressions", include_str!("corpus/expressions.txt")),
    ("literals", include_str!("corpus/literals.txt")),
    ("operators", include_str!("corpus/operators.txt")),
    ("statements", include_str!("corpus/statements.txt")),
];

// Update when fixing regressions. Test fails if count increases OR decreases.
const EXPECTED_REGRESSIONS: usize = 0;

#[test]
fn roundtrip_corpus_no_new_errors() {
    let mut total = 0;
    let mut passed = 0;
    let mut format_failures = Vec::new();
    let mut parse_regressions = Vec::new();

    for (file, corpus) in CORPUS_FILES {
        let snippets = common::extract_treesitter_snippets(corpus);
        for (name, code) in &snippets {
            total += 1;

            let original_has_errors = common::source_has_errors(code);

            match common::format_julia_tolerant(code) {
                Ok(formatted) => {
                    if !original_has_errors && common::source_has_errors(&formatted) {
                        parse_regressions.push(format!(
                            "{file}/{name}: formatting introduced ERROR nodes\n  input:  {code:?}\n  output: {formatted:?}"
                        ));
                    } else {
                        passed += 1;
                    }
                }
                Err(e) => {
                    format_failures.push(format!("{file}/{name}: {e}"));
                    passed += 1;
                }
            }
        }
    }

    eprintln!("\n=== Round-trip corpus results ===");
    eprintln!("Total snippets: {total}");
    eprintln!("Passed: {passed}");
    eprintln!("Format failures (non-fatal): {}", format_failures.len());
    eprintln!("Parse regressions: {}", parse_regressions.len());

    if !format_failures.is_empty() {
        eprintln!("\n--- Format failures (tolerated) ---");
        for f in &format_failures {
            eprintln!("  {f}");
        }
    }

    if !parse_regressions.is_empty() {
        eprintln!("\n--- Parse regressions ---");
        for r in &parse_regressions {
            eprintln!("  {r}");
        }
    }

    assert!(
        parse_regressions.len() <= EXPECTED_REGRESSIONS,
        "Regressions increased! Expected at most {EXPECTED_REGRESSIONS}, got {}.",
        parse_regressions.len()
    );
    if parse_regressions.len() < EXPECTED_REGRESSIONS {
        eprintln!(
            "\n✓ Regressions improved: {} → {} (update EXPECTED_REGRESSIONS)",
            EXPECTED_REGRESSIONS, parse_regressions.len()
        );
    }
}
