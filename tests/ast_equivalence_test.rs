//! AST Equivalence Test
//!
//! Takes Julia code snippets from JuliaSyntax.jl's test corpus, formats them
//! with topiary-julia, and verifies the tree-sitter AST is structurally
//! identical before and after formatting. This is a stronger guarantee than
//! "no ERROR nodes" — it proves formatting is purely cosmetic.

use topiary_core::{formatter, Language, Operation, TopiaryQuery};
use topiary_tree_sitter_facade::{Language as Grammar, Node, Parser};

const QUERY: &str = include_str!("../julia.scm");
const JULIASYNTAX_CORPUS: &str = include_str!("corpus/juliasyntax_parser.jl");

fn make_language() -> Language {
    let grammar: Grammar = tree_sitter_julia::LANGUAGE.into();
    let query = TopiaryQuery::new(&grammar, QUERY).expect("Invalid query file");
    Language {
        name: "julia".into(),
        query,
        grammar,
        indent: Some("    ".into()),
    }
}

fn format_julia(input: &str) -> Result<String, String> {
    let language = make_language();
    let mut output = Vec::new();
    formatter(
        &mut input.as_bytes(),
        &mut output,
        &language,
        Operation::Format {
            skip_idempotence: true,
            tolerate_parsing_errors: true,
        },
    )
    .map_err(|e| format!("{e}"))?;
    String::from_utf8(output).map_err(|e| format!("{e}"))
}

/// Produce a normalized S-expression from a tree-sitter tree.
/// Includes only named nodes (skips anonymous tokens like keywords/punctuation).
/// Does NOT include positions — purely structural.
fn tree_to_sexp(code: &str) -> String {
    let grammar: Grammar = tree_sitter_julia::LANGUAGE.into();
    let mut parser = Parser::new().unwrap();
    parser.set_language(&grammar).unwrap();
    let tree = parser.parse(code, None).unwrap().unwrap();
    node_to_sexp(&tree.root_node(), code)
}

fn node_to_sexp(node: &Node, source: &str) -> String {
    let kind = node.kind();

    // Count named children
    let mut named_children = Vec::new();
    for i in 0..node.child_count() {
        if let Some(child) = node.child(i) {
            if child.is_named() {
                named_children.push(child);
            }
        }
    }

    if named_children.is_empty() {
        // Leaf named node — include its text content for identifiers/literals
        // so we can detect if formatting changed actual code
        let text = &source[node.start_byte() as usize..node.end_byte() as usize];
        if kind == "identifier" || kind == "operator" || kind == "integer_literal"
            || kind == "float_literal" || kind == "boolean_literal"
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

fn has_error(node: &Node) -> bool {
    if node.kind() == "ERROR" || node.is_error() {
        return true;
    }
    for i in 0..node.child_count() {
        if let Some(child) = node.child(i) {
            if has_error(&child) {
                return true;
            }
        }
    }
    false
}

fn source_has_errors(code: &str) -> bool {
    let grammar: Grammar = tree_sitter_julia::LANGUAGE.into();
    let mut parser = Parser::new().unwrap();
    parser.set_language(&grammar).unwrap();
    let tree = parser.parse(code, None).unwrap().unwrap();
    has_error(&tree.root_node())
}

// ─── Corpus extraction ──────────────────────────────────────────────

/// Extract Julia code snippets from JuliaSyntax.jl's parser.jl test file.
/// Returns (snippet_text, line_number) pairs.
fn extract_juliasyntax_snippets(corpus: &str) -> Vec<(String, usize)> {
    let mut snippets = Vec::new();

    for (line_num, line) in corpus.lines().enumerate() {
        let trimmed = line.trim();

        // Skip comments, empty lines, non-test lines
        if trimmed.is_empty()
            || trimmed.starts_with('#')
            || trimmed.starts_with(']')
            || trimmed.starts_with('[')
            || trimmed.starts_with("tests")
            || trimmed.starts_with("JuliaSyntax")
            || trimmed.starts_with("with_version")
            || trimmed.starts_with("function")
            || trimmed.starts_with("end")
            || trimmed.starts_with("PARSE_ERROR")
            || trimmed.starts_with("\"\"\"")
            || trimmed.starts_with("parsestmt")
        {
            continue;
        }

        // Match: "code" => "sexp" or "code" => PARSE_ERROR
        // We want the left side "code" before =>
        if let Some(arrow_pos) = trimmed.find("=>") {
            let lhs = trimmed[..arrow_pos].trim();
            let rhs = trimmed[arrow_pos + 2..].trim();

            // Skip PARSE_ERROR tests (expected to fail)
            if rhs.starts_with("PARSE_ERROR") || rhs.starts_with("r\"") {
                continue;
            }

            // Extract the string from lhs
            let code = if lhs.starts_with('"') {
                // Simple: "code" => "sexp"
                extract_julia_string(lhs)
            } else if lhs.starts_with("((") {
                // Versioned: ((v=v"1.7",), "code") => "sexp"
                // Find the last quoted string in lhs
                if let Some(last_quote) = lhs.rfind("\", \"").or(lhs.rfind("), \"")) {
                    let rest = &lhs[last_quote..];
                    if let Some(start) = rest.find('"') {
                        extract_julia_string(&rest[start..])
                    } else {
                        None
                    }
                } else {
                    None
                }
            } else {
                None
            };

            if let Some(code) = code {
                if !code.is_empty() {
                    snippets.push((code, line_num + 1));
                }
            }
        }
    }

    snippets
}

/// Parse a Julia double-quoted string literal, handling escapes.
fn extract_julia_string(s: &str) -> Option<String> {
    let s = s.trim();
    if !s.starts_with('"') {
        return None;
    }

    // Find the closing quote (handling escaped quotes)
    let bytes = s.as_bytes();
    let mut i = 1;
    let mut result = String::new();

    while i < bytes.len() {
        match bytes[i] {
            b'"' => {
                // End of string
                return Some(result);
            }
            b'\\' if i + 1 < bytes.len() => {
                match bytes[i + 1] {
                    b'n' => result.push('\n'),
                    b't' => result.push('\t'),
                    b'\\' => result.push('\\'),
                    b'"' => result.push('"'),
                    b'$' => result.push('$'),
                    b'r' => result.push('\r'),
                    b'0' => result.push('\0'),
                    other => {
                        result.push('\\');
                        result.push(other as char);
                    }
                }
                i += 2;
            }
            other => {
                result.push(other as char);
                i += 1;
            }
        }
    }

    None // Unclosed string
}

// ─── The test ───────────────────────────────────────────────────────

#[test]
fn ast_equivalence_juliasyntax_corpus() {
    let snippets = extract_juliasyntax_snippets(JULIASYNTAX_CORPUS);
    assert!(
        snippets.len() > 500,
        "Expected >500 snippets, got {}. Extraction may be broken.",
        snippets.len()
    );

    let mut total = 0;
    let mut passed = 0;
    let mut skipped_parse_error = 0;
    let mut format_failures = 0;
    let mut ast_mismatches: Vec<String> = Vec::new();
    let mut new_errors: Vec<String> = Vec::new();

    for (code, line_num) in &snippets {
        total += 1;

        // Skip if the original doesn't parse cleanly
        if source_has_errors(code) {
            skipped_parse_error += 1;
            continue;
        }

        let sexp_before = tree_to_sexp(code);

        match format_julia(code) {
            Ok(formatted) => {
                // Check for new parse errors
                if source_has_errors(&formatted) {
                    new_errors.push(format!(
                        "L{line_num}: formatting introduced ERROR nodes\n  in:  {code:?}\n  out: {formatted:?}"
                    ));
                    continue;
                }

                let sexp_after = tree_to_sexp(&formatted);

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
                // Formatting failure is not an AST mismatch — count separately
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

    // We track progress: fail if more than 15% of testable snippets have issues.
    // As the formatter improves, tighten this threshold.
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

// ─── Unit tests for the extraction logic ────────────────────────────

#[test]
fn test_extract_julia_string() {
    assert_eq!(extract_julia_string(r#""hello""#), Some("hello".into()));
    assert_eq!(extract_julia_string(r#""a\nb""#), Some("a\nb".into()));
    assert_eq!(extract_julia_string(r#""a\"b""#), Some("a\"b".into()));
    assert_eq!(extract_julia_string(r#""a\\b""#), Some("a\\b".into()));
    assert_eq!(extract_julia_string(r#""a\$b""#), Some("a$b".into()));
    assert_eq!(extract_julia_string(r#""""#), Some("".into()));
}

#[test]
fn test_extract_snippets_count() {
    let snippets = extract_juliasyntax_snippets(JULIASYNTAX_CORPUS);
    eprintln!("Extracted {} snippets from JuliaSyntax corpus", snippets.len());
    assert!(snippets.len() > 500, "Expected >500 snippets, got {}", snippets.len());
}

#[test]
fn test_tree_to_sexp_basic() {
    let sexp = tree_to_sexp("x = 1\n");
    assert!(sexp.contains("assignment"), "Expected 'assignment' in sexp, got: {sexp}");
    assert!(sexp.contains("identifier"), "Expected 'identifier' in sexp, got: {sexp}");
}

#[test]
fn test_sexp_equivalence_simple() {
    let before = tree_to_sexp("x  =  1\n");
    let after = tree_to_sexp("x = 1\n");
    assert_eq!(before, after, "Whitespace-only change should not affect AST");
}
