//! Shared parser setup and error-detection helpers.
//!
//! The S-expression emitters themselves live in `src/parse.rs` (CLI, with
//! marker injection for the corpus translator) and `tests/common/mod.rs`
//! (tests, with a simpler Debug-quoted format). They intentionally differ
//! in leaf-text coverage and quoting, so they are NOT shared here.

use topiary_tree_sitter_facade::{Language as Grammar, Node, Parser, Tree};

/// Parse Julia source with the bundled tree-sitter-julia grammar.
/// Returns `None` only when tree-sitter itself fails to produce a tree
/// (distinct from ERROR nodes inside a tree).
pub fn parse_julia(code: &str) -> Option<Tree> {
    let grammar: Grammar = tree_sitter_julia::LANGUAGE.into();
    let mut parser = Parser::new().unwrap();
    parser.set_language(&grammar).unwrap();
    parser.parse(code, None).unwrap()
}

/// Whether a parsed tree contains any ERROR or MISSING node.
pub fn tree_has_errors(tree: &Tree) -> bool {
    has_error(&tree.root_node())
}

/// Parse and report whether the result contains any ERROR or MISSING node.
/// Treats "no tree" as "has errors".
pub fn source_has_errors(code: &str) -> bool {
    match parse_julia(code) {
        Some(t) => tree_has_errors(&t),
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
