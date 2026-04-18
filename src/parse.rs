//! tree-sitter-julia CST helpers used by the `parse` subcommand.
//!
//! Kept intentionally close to the test helpers in `tests/common/mod.rs`
//! so both paths produce identical S-expressions.

use topiary_tree_sitter_facade::{Language as Grammar, Node, Parser};

/// Produce a normalized S-expression from Julia source code.
/// Includes only named nodes (skips anonymous tokens). Leaf text is emitted
/// for identifier/operator/integer_literal/float_literal/boolean_literal
/// nodes so structural comparison has enough signal.
pub fn tree_to_sexp(code: &str) -> String {
    let grammar: Grammar = tree_sitter_julia::LANGUAGE.into();
    let mut parser = Parser::new().unwrap();
    parser.set_language(&grammar).unwrap();
    let tree = parser.parse(code, None).unwrap().unwrap();
    node_to_sexp(&tree.root_node(), code)
}

fn quote_preserving_utf8(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\x{:02x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
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
        // Leaf kinds whose source text is semantically meaningful for
        // structural comparison. Emit a quoted form that preserves UTF-8
        // bytes as-is (escaping only `\`, `"`, and control characters) so
        // identifiers like `w̄` survive the round trip.
        if kind == "identifier"
            || kind == "var_identifier"
            || kind == "operator"
            || kind == "integer_literal"
            || kind == "float_literal"
            || kind == "boolean_literal"
            || kind == "character_literal"
            || kind == "content"
            || kind == "escape_sequence"
        {
            format!("({kind} {})", quote_preserving_utf8(text))
        } else {
            format!("({kind})")
        }
    } else {
        // Translate each named child. For `string_literal` /
        // `prefixed_string_literal` children we also check whether the gap
        // before the next sibling contains a blank line — JuliaSyntax only
        // attaches a docstring to the *immediately* following expression;
        // a blank separator breaks the binding.
        let mut children_sexp: Vec<String> = Vec::with_capacity(named_children.len());
        for (idx, child) in named_children.iter().enumerate() {
            let mut sexp = node_to_sexp(child, source);
            let child_kind = child.kind();
            if child_kind == "string_literal" || child_kind == "prefixed_string_literal" {
                // Find the next non-comment sibling and inspect the gap.
                // A doc-string's binding to the next expression breaks on
                // either a blank line OR an intervening comment.
                let mut next_idx = idx + 1;
                let mut saw_comment = false;
                while let Some(cand) = named_children.get(next_idx) {
                    let k = cand.kind();
                    if k == "line_comment" || k == "block_comment" {
                        saw_comment = true;
                        next_idx += 1;
                    } else {
                        break;
                    }
                }
                if let Some(next) = named_children.get(next_idx) {
                    let gap = &source[child.end_byte() as usize..next.start_byte() as usize];
                    let blank_line = gap.matches('\n').count() >= 2;
                    if blank_line || saw_comment {
                        if sexp.ends_with(')') {
                            let insert_at = sexp.len() - 1;
                            sexp.insert_str(insert_at, " (blank_after)");
                        }
                    }
                }
            }
            children_sexp.push(sexp);
        }
        // `mutable struct` and `baremodule` are now distinguishable at the
        // CST level via named children (`mutable_keyword`, `baremodule_keyword`)
        // emitted by tree-sitter-julia directly — no marker injection needed.
        // Signed literal fold: `-1`, `+1.5`, `-2.0` (unary op + numeric
        // literal with NO intervening whitespace) become a single literal
        // in JuliaSyntax. Emit a marker so the translator can fold.
        if kind == "unary_expression" && named_children.len() == 2 {
            let op = &named_children[0];
            let lit = &named_children[1];
            let op_kind = op.kind();
            let lit_kind = lit.kind();
            if op_kind == "operator"
                && (lit_kind == "integer_literal" || lit_kind == "float_literal")
            {
                let op_text = &source[op.start_byte() as usize..op.end_byte() as usize];
                if op_text == "-" || op_text == "+" {
                    let gap_start = op.end_byte() as usize;
                    let gap_end = lit.start_byte() as usize;
                    if gap_end == gap_start {
                        children_sexp.push("(fold_sign)".to_string());
                    }
                }
            }
        }
        // Relative-import dot count is now encoded as named `(relative_dot)`
        // children emitted by tree-sitter-julia — no source counting needed.
        // Triple-quoting is now surfaced by the grammar via named children
        // (`triple_quote`, `triple_backtick`). The translator detects the
        // quoting style from the CST directly — no source inspection needed.
        //
        // Command literals still get a `(raw_content)` marker: JuliaSyntax
        // emits the full interpolated text as one string, so we expose the
        // raw inner bytes for the translator to copy verbatim.
        if kind == "command_literal" || kind == "prefixed_command_literal" {
            let text = &source[node.start_byte() as usize..node.end_byte() as usize];
            let opener = if kind == "command_literal" {
                text
            } else {
                text.trim_start_matches(|c: char| c.is_alphanumeric() || c == '_')
            };
            let is_triple = opener.starts_with("```");
            let delim_len = if is_triple { 3 } else { 1 };
            let (inner_start, inner_end) = {
                let prefix_len = text.len() - opener.len();
                let start = prefix_len + delim_len;
                let end = text.len().saturating_sub(delim_len);
                (start, end.max(start))
            };
            let inner = &text[inner_start..inner_end];
            children_sexp.push(format!("(raw_content {})", quote_preserving_utf8(inner)));
        }
        // Trailing comma and `;` inside tuple/argument/vector/curly lists are
        // now named CST children (`trailing_comma`, `parameters_separator`)
        // emitted by tree-sitter-julia directly — no source-inspection needed.
        //
        // Matrix `[a b;]` still needs a marker: the `;` here is a row
        // separator, not a kwarg boundary, and tree-sitter-julia keeps it as
        // an anonymous token.
        if kind == "matrix_expression" {
            let mut has_semi = false;
            for i in 0..node.child_count() {
                if let Some(child) = node.child(i) {
                    let ctext = &source[child.start_byte() as usize..child.end_byte() as usize];
                    if !child.is_named() && ctext == ";" {
                        has_semi = true;
                        break;
                    }
                }
            }
            if has_semi {
                children_sexp.push("(matrix_semicolon)".to_string());
            }
        }
        format!("({kind} {})", children_sexp.join(" "))
    }
}

/// Report whether the parse tree contains any `ERROR` or `MISSING` node.
pub fn source_has_errors(code: &str) -> bool {
    let grammar: Grammar = tree_sitter_julia::LANGUAGE.into();
    let mut parser = Parser::new().unwrap();
    parser.set_language(&grammar).unwrap();
    match parser.parse(code, None).unwrap() {
        Some(tree) => has_error(&tree.root_node()),
        None => true,
    }
}

fn has_error(node: &Node) -> bool {
    if node.kind() == "ERROR" || node.is_error() || node.is_missing() {
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
