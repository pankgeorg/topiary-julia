//! Shared test utilities for topiary-julia.
//!
//! Used by all integration test files via `mod common;`

#![allow(dead_code)]

use topiary_core::{formatter, Language, Operation, TopiaryQuery};
use topiary_tree_sitter_facade::{Language as Grammar, Node, Parser};

const QUERY: &str = include_str!("../../julia.scm");

/// Build the Language struct needed by topiary-core.
pub fn make_language() -> Language {
    let grammar: Grammar = tree_sitter_julia::LANGUAGE.into();
    let query = TopiaryQuery::new(&grammar, QUERY).expect("Invalid query file");
    Language {
        name: "julia".into(),
        query,
        grammar,
        indent: Some("    ".into()),
    }
}

/// Format Julia source code. Panics on failure.
pub fn format_julia(input: &str) -> String {
    let language = make_language();
    let mut output = Vec::new();
    formatter(
        &mut input.as_bytes(),
        &mut output,
        &language,
        Operation::Format {
            skip_idempotence: true,
            tolerate_parsing_errors: false,
        },
    )
    .expect("Formatting failed");
    String::from_utf8(output).expect("Non-UTF8 output")
}

/// Format Julia source code, tolerating parse errors. Returns Err on formatter crash.
pub fn format_julia_tolerant(input: &str) -> Result<String, String> {
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

/// Format twice and assert the output is identical (idempotent).
pub fn assert_idempotent(input: &str) {
    let first = format_julia(input);
    let second = format_julia(&first);
    pretty_assertions::assert_eq!(first, second, "Not idempotent");
}

// ─── Tree-sitter helpers ────────────────────────────────────────

/// Produce a normalized S-expression from Julia source code.
/// Includes only named nodes (skips anonymous tokens).
/// Does NOT include positions — purely structural.
pub fn tree_to_sexp(code: &str) -> String {
    let grammar: Grammar = tree_sitter_julia::LANGUAGE.into();
    let mut parser = Parser::new().unwrap();
    parser.set_language(&grammar).unwrap();
    let tree = parser.parse(code, None).unwrap().unwrap();
    node_to_sexp(&tree.root_node(), code)
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

/// Check if tree-sitter parse tree contains any ERROR nodes.
pub fn source_has_errors(code: &str) -> bool {
    let grammar: Grammar = tree_sitter_julia::LANGUAGE.into();
    let mut parser = Parser::new().unwrap();
    parser.set_language(&grammar).unwrap();
    let tree = parser.parse(code, None).unwrap();
    match tree {
        Some(t) => has_error(&t.root_node()),
        None => true,
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

// ─── Corpus extraction ──────────────────────────────────────────

/// Extract Julia code snippets from tree-sitter corpus .txt files.
/// Returns (test_name, julia_code) pairs.
pub fn extract_treesitter_snippets(corpus: &str) -> Vec<(String, String)> {
    let mut snippets = Vec::new();
    let sections: Vec<&str> = corpus.split("\n---\n").collect();

    for section in &sections {
        let lines: Vec<&str> = section.lines().collect();
        let mut header_end = None;
        for (i, line) in lines.iter().enumerate().rev() {
            if line.starts_with("====") {
                if i >= 2 && lines[i - 2].starts_with("====") {
                    header_end = Some(i);
                    break;
                }
            }
        }

        if let Some(end_idx) = header_end {
            let name = lines[end_idx - 1].to_string();
            let code = lines[end_idx + 1..].join("\n");
            if !code.trim().is_empty() {
                snippets.push((name, code));
            }
        }
    }

    snippets
}

/// Extract Julia code snippets from JuliaSyntax.jl's parser.jl.
/// Returns (code, line_number) pairs.
pub fn extract_juliasyntax_snippets(corpus: &str) -> Vec<(String, usize)> {
    let mut snippets = Vec::new();

    for (line_num, line) in corpus.lines().enumerate() {
        let trimmed = line.trim();

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

        if let Some(arrow_pos) = trimmed.find("=>") {
            let lhs = trimmed[..arrow_pos].trim();
            let rhs = trimmed[arrow_pos + 2..].trim();

            if rhs.starts_with("PARSE_ERROR") || rhs.starts_with("r\"") {
                continue;
            }

            let code = if lhs.starts_with('"') {
                extract_julia_string(lhs)
            } else if lhs.starts_with("((") {
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
pub fn extract_julia_string(s: &str) -> Option<String> {
    let s = s.trim();
    if !s.starts_with('"') {
        return None;
    }

    let mut chars = s[1..].chars();
    let mut result = String::new();

    while let Some(c) = chars.next() {
        match c {
            '"' => return Some(result),
            '\\' => {
                if let Some(esc) = chars.next() {
                    match esc {
                        'n' => result.push('\n'),
                        't' => result.push('\t'),
                        '\\' => result.push('\\'),
                        '"' => result.push('"'),
                        '$' => result.push('$'),
                        'r' => result.push('\r'),
                        '0' => result.push('\0'),
                        other => {
                            result.push('\\');
                            result.push(other);
                        }
                    }
                }
            }
            other => result.push(other),
        }
    }

    None
}

