//! tree-sitter-julia CST → S-expression for the corpus translator.
//!
//! Injects a handful of markers `(fold_sign)`, `(raw_content …)`,
//! `(matrix_semicolon)`, `(blank_after)` that encode source-level details
//! the CST itself discards. The Julia translator in
//! `corpus/translator.jl` picks these up to match JuliaSyntax's AST shape.

use topiary_tree_sitter_facade::{Node, Tree};

/// Produce the marker-annotated S-expression for an already-parsed tree.
pub fn tree_to_sexp(tree: &Tree, source: &str) -> String {
    let mut out = String::with_capacity(source.len() * 2);
    node_to_sexp(&tree.root_node(), source, &mut out);
    out
}

fn quote_preserving_utf8(s: &str, out: &mut String) {
    out.reserve(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                use std::fmt::Write;
                let _ = write!(out, "\\x{:02x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

fn node_to_sexp(node: &Node, source: &str, out: &mut String) {
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
        out.push('(');
        out.push_str(&kind);
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
            out.push(' ');
            quote_preserving_utf8(text, out);
        }
        out.push(')');
        return;
    }

    out.push('(');
    out.push_str(&kind);

    for (idx, child) in named_children.iter().enumerate() {
        out.push(' ');
        let before = out.len();
        node_to_sexp(child, source, out);
        let child_kind = child.kind();
        if child_kind == "string_literal" || child_kind == "prefixed_string_literal" {
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
                if (blank_line || saw_comment) && out.ends_with(')') {
                    debug_assert!(out.len() > before);
                    let insert_at = out.len() - 1;
                    out.insert_str(insert_at, " (blank_after)");
                }
            }
        }
    }

    // Signed-literal fold: `-1`, `+1.5` (unary op + numeric literal with NO
    // intervening whitespace) become a single literal in JuliaSyntax.
    if kind == "unary_expression" && named_children.len() == 2 {
        let op = &named_children[0];
        let lit = &named_children[1];
        if op.kind() == "operator"
            && (lit.kind() == "integer_literal" || lit.kind() == "float_literal")
        {
            let op_text = &source[op.start_byte() as usize..op.end_byte() as usize];
            if (op_text == "-" || op_text == "+")
                && lit.start_byte() as usize == op.end_byte() as usize
            {
                out.push_str(" (fold_sign)");
            }
        }
    }

    // Command literals expose the raw interpolated text as a single string
    // to mirror JuliaSyntax's cmdstring-r shape.
    if kind == "command_literal" || kind == "prefixed_command_literal" {
        let text = &source[node.start_byte() as usize..node.end_byte() as usize];
        let opener = if kind == "command_literal" {
            text
        } else {
            text.trim_start_matches(|c: char| c.is_alphanumeric() || c == '_')
        };
        let is_triple = opener.starts_with("```");
        let delim_len = if is_triple { 3 } else { 1 };
        let prefix_len = text.len() - opener.len();
        let inner_start = prefix_len + delim_len;
        let inner_end = text.len().saturating_sub(delim_len).max(inner_start);
        let inner = &text[inner_start..inner_end];
        out.push_str(" (raw_content ");
        quote_preserving_utf8(inner, out);
        out.push(')');
    }

    // Matrix `[a b;]` row separator — still an anonymous `;` token.
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
            out.push_str(" (matrix_semicolon)");
        }
    }

    out.push(')');
}
