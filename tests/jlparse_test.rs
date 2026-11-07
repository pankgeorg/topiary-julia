//! Julia's own parser (JuliaSyntax compiled to Wasm, run by wasmtime) inside topiary-julia.
//!
//!   cargo test --test jlparse_test                     # everything
//!   cargo test --test jlparse_test jl_line_0197        # one JuliaSyntax-corpus snippet
//!   cargo test --test jlparse_test jl_gap              # the known grammar gaps
//!   JLPARSE_CLASSIFY=1 cargo test --test jlparse_test -- --nocapture | grep ^CLASSIFY
//!                                                      # print classifications instead
//!
//! Each `jl_*` test formats a snippet with JuliaSyntax verification and checks the
//! classification: clean (plain Topiary's output means the same, per JuliaSyntax), `protected`
//! (some region had to be left verbatim: a grammar gap, or plain Topiary would change the
//! meaning) or `js_error` (JuliaSyntax itself rejects the snippet as a file). Non-clean
//! classifications are listed in `tests/corpus/jlparse_expectations.toml`.

#![cfg(feature = "jlparse")]

mod common;

use topiary_julia::jlparse::{self, JlParser, Rule, Verdict};

include!(concat!(env!("OUT_DIR"), "/jlparse_equivalence_generated.rs"));
include!(concat!(env!("OUT_DIR"), "/jlparse_gaps_generated.rs"));

/// The module's raw output matches native JuliaSyntax node for node (kinds, spans,
/// node spans, classes), diagnostics and kind names: the same corpus and comparison as
/// WasmCodegen.jl's examples/juliasyntax/check.mjs (reference.json from its reference.jl,
/// Julia 1.13.2: 18 snippets incl. syntax errors + 3 files of Base, 300 KB).
#[test]
fn matches_native_reference() {
    let raw = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/tests/corpus/jlparse_reference.json")).unwrap();
    let cases: serde_json::Value = serde_json::from_str(&raw).unwrap();
    let mut p = JlParser::new().unwrap();
    let mut nodes = 0;
    for c in cases.as_array().unwrap() {
        let name = c["name"].as_str().unwrap();
        let src = c["src"].as_str().unwrap();
        let (out, diags) = p.parse_raw(src.as_bytes(), Rule::All).unwrap();
        let want: Vec<Vec<i64>> = c["out"].as_array().unwrap().iter()
            .map(|r| r.as_array().unwrap().iter().map(|x| x.as_i64().unwrap()).collect()).collect();
        assert_eq!(out.len(), want.len(), "{name}: node count");
        for (k, (g, w)) in out.iter().zip(&want).enumerate() {
            let g4: Vec<i64> = g[..4].iter().map(|&x| x as i64).collect();
            assert_eq!(&g4, w, "{name}: node {}", k + 1);
        }
        nodes += out.len();
        let wd = c["diags"].as_array().unwrap();
        assert_eq!(diags.len(), wd.len(), "{name}: diagnostics");
        for (d, w) in diags.iter().zip(wd) {
            let w = w.as_array().unwrap();
            assert_eq!(d.first_byte as i64, w[0].as_i64().unwrap(), "{name}");
            assert_eq!(d.last_byte as i64, w[1].as_i64().unwrap(), "{name}");
            let lvl = match d.level { jlparse::DiagLevel::Error => 1, jlparse::DiagLevel::Warning => 2, _ => 3 };
            assert_eq!(lvl, w[2].as_i64().unwrap(), "{name}");
            assert_eq!(d.message, w[3].as_str().unwrap(), "{name}");
        }
        for (k, n) in c["names"].as_object().unwrap() {
            assert_eq!(p.kind_name(k.parse().unwrap()).unwrap(), n.as_str().unwrap(), "{name}: kind {k}");
        }
        // and the tree builder accounts for every byte
        let t = p.parse(src, Rule::All).unwrap();
        let end = t.roots.iter().map(|&r| t.nodes[r].end).max().unwrap_or(0);
        assert_eq!(end, src.len(), "{name}: tree covers the source");
    }
    assert_eq!(nodes, 76494);
}

fn verdict(a: &str, b: &str) -> Verdict {
    common::with_jl(|jl| jl.verify(a, b).unwrap())
}

fn equivalent(a: &str, b: &str) -> bool {
    matches!(verdict(a, b), Verdict::Equivalent)
}

#[test]
fn verify_accepts_layout_changes() {
    assert!(equivalent("function f(x,y) x+y end", "function f(x, y)\n    x + y\nend\n"));
    assert!(equivalent("a=1;b=2", "a = 1\nb = 2\n"));
    assert!(equivalent("begin a; b end", "begin\n    a\n    b\nend\n"));
    assert!(equivalent("f(a,\n  b)", "f(a, b)"));
    assert!(equivalent("x = [1, 2,\n 3]", "x = [1, 2, 3]"));
    assert!(equivalent("# c\nf(x)  # d\n", "# c\nf(x) # d\n"));
    assert!(equivalent("s = \"\"\"\n    a\n      b\n    \"\"\"", "s = \"\"\"\n  a\n    b\n  \"\"\""));
}

#[test]
fn verify_rejects_meaning_changes() {
    assert!(!equivalent("a + b", "a - b"));
    assert!(!equivalent("[a -b]", "[a - b]"));
    assert!(!equivalent("[a, b]", "[a b]"));
    assert!(!equivalent("[1 :a]", "[1:a]"));
    assert!(!equivalent("a + b", "+(a, b)"));
    assert!(!equivalent("(a,) -> c", "(a) -> c"));
    assert!(!equivalent("f(a; b)", "f(a, b)"));
    assert!(!equivalent("x = \"a b\"", "x = \"a  b\""));
    assert!(!equivalent("s = \"\"\"\n    a\n      b\n    \"\"\"", "s = \"\"\"\n    a\n    b\n    \"\"\""));
    assert!(!equivalent("[a;; b]", "[a; b]"));
    assert!(!equivalent("mutable struct A end", "struct A end"));
    assert!(!equivalent("@m(a, b)", "@m a b"));
    // a docstring attaches only when directly followed by the definition
    assert!(!equivalent("\"doc\"\nfoo(x) = 1", "\"doc\"\n\nfoo(x) = 1"));
    // the output must parse
    assert!(matches!(verdict("f(x)", "f(x"), Verdict::OutputHasErrors(_)));
    // comments must survive, in order
    assert!(matches!(verdict("f(x) # c\n", "f(x)\n"), Verdict::CommentsChanged(_)));
    assert!(matches!(verdict("# a\n# b\nx", "# b\n# a\nx"), Verdict::CommentsChanged(_)));
}

#[test]
fn syntax_errors_come_from_juliasyntax() {
    common::with_jl(|jl| {
        let t = jl.parse("function f(x\n  y = = 1\nend\n", Rule::All).unwrap();
        assert!(t.has_errors());
        let msg = jlparse::format_diagnostics("f.jl", "function f(x\n  y = = 1\nend\n", &t.diagnostics);
        assert!(msg.starts_with("f.jl:"), "{msg}");
        assert!(msg.contains("error"), "{msg}");
    });
}

#[test]
fn grammar_gap_left_verbatim_rest_formatted() {
    use topiary_julia::format::Outcome;
    let code = "function g(x,y)\n  f(&x)\n  x+y\nend\n";
    common::with_jl(|jl| {
        common::with_language_pub(|lang| {
            match topiary_julia::format::format_verified(code, lang, jl, true).unwrap() {
                Outcome::Formatted { output, protected } => {
                    assert_eq!(output, "function g(x, y)\n    f(&x)\n    x + y\nend\n");
                    assert_eq!(protected.len(), 1);
                    assert_eq!(&code[protected[0].start..protected[0].end], "&x");
                }
                o => panic!("{o:?}"),
            }
        })
    });
}

#[test]
fn many_gaps_in_one_file() {
    use topiary_julia::format::Outcome;
    // 12 protected regions: placeholders 0..11 must not be confused (`_1_` vs `_10_`)
    let code: String = (0..12).map(|k| format!("g{k}(&a{k},b)\n")).collect();
    let want: String = (0..12).map(|k| format!("g{k}(&a{k}, b)\n")).collect();
    common::with_jl(|jl| {
        common::with_language_pub(|lang| match topiary_julia::format::format_verified(&code, lang, jl, true).unwrap() {
            Outcome::Formatted { output, protected } => {
                assert_eq!(output, want);
                assert_eq!(protected.len(), 12);
            }
            o => panic!("{o:?}"),
        })
    });
}

#[test]
fn line_starting_with_semicolon() {
    use topiary_julia::format::Outcome;
    // tree-sitter fails on the separator before `;@m`; only that statement is protected
    let code = "a && f(\"x\")\n        ;@m \"y\"\nwhile true\n    n = 1      ;@m \"z\"\nend\n";
    common::with_jl(|jl| {
        common::with_language_pub(|lang| match topiary_julia::format::format_verified(code, lang, jl, true).unwrap() {
            Outcome::Formatted { output, protected } => {
                assert_eq!(output, "a && f(\"x\")\n;@m \"y\"\nwhile true\n    n = 1\n    @m \"z\"\nend\n");
                assert_eq!(protected.len(), 1);
            }
            o => panic!("{o:?}"),
        })
    });
}
