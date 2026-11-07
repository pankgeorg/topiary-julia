//! Julia's own parser — `Base.JuliaSyntax` of Julia 1.13, compiled to WebAssembly GC by
//! WasmCodegen.jl (`jlparse/parser.wasm`, built from `jlparse/parser.jl`) — run in-process
//! on wasmtime.
//!
//! Only numbers cross the boundary: the source goes in four bytes per call, and the parser's
//! raw output comes back node by node — `ParseStream.output`, the tokens and the interior
//! ranges of the green tree in postorder, with kinds, flags and spans — plus the
//! diagnostics. [`GreenTree`] rebuilds the tree as JuliaSyntax's `build_tree` does.
//!
//! On top of it: [`SemTree`], an Expr-like normal form of the green tree, and
//! [`first_difference`], used to verify that formatting did not change what the code means.

use std::collections::HashMap;
use std::fmt;
use std::sync::OnceLock;

use wasmtime::{Config, Engine, Instance, Module, Store, TypedFunc};

/// The module, optimized (`wasm-opt -O3`).
pub const PARSER_WASM: &[u8] = include_bytes!("../jlparse/parser.wasm");

/// The wasmtime configuration the module needs: GC, typed function references and
/// exception handling (`try_table`/exnref).
pub fn wasmtime_config() -> Config {
    let mut c = Config::new();
    c.wasm_gc(true);
    c.wasm_function_references(true);
    c.wasm_exceptions(true);
    c
}

/// Where the compiled module is cached: `$TOPIARY_JULIA_CACHE`, else
/// `$XDG_CACHE_HOME/topiary-julia`, else `~/.cache/topiary-julia`. `TOPIARY_JULIA_CACHE=off`
/// disables the cache.
fn cache_dir() -> Option<std::path::PathBuf> {
    use std::path::PathBuf;
    match std::env::var_os("TOPIARY_JULIA_CACHE") {
        Some(v) if v == "off" => return None,
        Some(v) if !v.is_empty() => return Some(PathBuf::from(v)),
        _ => {}
    }
    if let Some(x) = std::env::var_os("XDG_CACHE_HOME").filter(|v| !v.is_empty()) {
        return Some(PathBuf::from(x).join("topiary-julia"));
    }
    std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".cache").join("topiary-julia"))
}

fn fnv1a(bytes: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf29ce484222325;
    for &b in bytes {
        h ^= b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    h
}

/// Compiling parser.wasm with Cranelift takes ~1–2 s; the compiled code is cached on disk,
/// keyed by the module's hash and wasmtime's compatibility hash (version, configuration,
/// target), so later runs load it in milliseconds.
fn engine_and_module() -> Result<&'static (Engine, Module), String> {
    static EM: OnceLock<Result<(Engine, Module), String>> = OnceLock::new();
    EM.get_or_init(|| {
        use std::hash::{Hash, Hasher};
        let engine = Engine::new(&wasmtime_config()).map_err(|e| format!("wasmtime: {e}"))?;
        let mut h = std::collections::hash_map::DefaultHasher::new();
        engine.precompile_compatibility_hash().hash(&mut h);
        let key = format!("parser-{:016x}-{:016x}.cwasm", fnv1a(PARSER_WASM), h.finish());
        let path = cache_dir().map(|d| d.join(key));
        if let Some(p) = &path {
            if p.exists() {
                // SAFETY: the file is wasmtime's serialization of our own module, written by
                // this program below (keyed by module hash + compatibility hash); wasmtime
                // checks the header, version and configuration before using it.
                if let Ok(m) = unsafe { Module::deserialize_file(&engine, p) } {
                    return Ok((engine, m));
                }
            }
        }
        let module = Module::new(&engine, PARSER_WASM).map_err(|e| format!("parser.wasm: {e}"))?;
        if let Some(p) = &path {
            if let Ok(bytes) = module.serialize() {
                let _ = std::fs::create_dir_all(p.parent().unwrap());
                // write then rename, so a concurrent reader never sees a partial file
                let tmp = p.with_extension(format!("tmp{}", std::process::id()));
                if std::fs::write(&tmp, bytes).is_ok() {
                    let _ = std::fs::rename(&tmp, p);
                }
            }
        }
        Ok((engine, module))
    })
    .as_ref()
    .map_err(|e| e.clone())
}

/// What JuliaSyntax parses the source as.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Rule {
    /// A whole file (`parseall`).
    All = 1,
    /// One statement.
    Statement = 2,
    /// One atom.
    Atom = 3,
}

/// A JuliaSyntax diagnostic. Byte positions are 1-based and inclusive, as in JuliaSyntax.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Diagnostic {
    pub first_byte: usize,
    pub last_byte: usize,
    pub level: DiagLevel,
    pub message: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DiagLevel {
    Error,
    Warning,
    Note,
}

/// The classes of a node, as `out_class` reports them.
pub mod class {
    pub const INTERIOR: u8 = 1;
    pub const TRIVIA: u8 = 2;
    pub const ERROR: u8 = 4;
    pub const KEYWORD: u8 = 8;
    pub const OPERATOR: u8 = 16;
    pub const LITERAL: u8 = 32;
    pub const IDENTIFIER: u8 = 64;
    pub const WHITESPACE: u8 = 128;
}

/// One node of the parser's raw output (`RawGreenNode`), placed in the source.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RawNode {
    pub kind: u16,
    pub flags: u16,
    /// For a token, its kind before parsing; for an interior node, the number of nodes below it.
    pub nodespan: u32,
    pub class: u8,
    /// Byte range in the source (0-based, end exclusive).
    pub start: usize,
    pub end: usize,
}

impl RawNode {
    pub fn is_interior(&self) -> bool {
        self.class & class::INTERIOR != 0
    }
    pub fn is_trivia(&self) -> bool {
        self.class & class::TRIVIA != 0
    }
    pub fn is_error(&self) -> bool {
        self.class & class::ERROR != 0
    }
    pub fn is_whitespace(&self) -> bool {
        self.class & class::WHITESPACE != 0
    }
}

/// The green tree of one parse: the raw output in postorder, children lists, and the
/// diagnostics.
#[derive(Clone, Debug)]
pub struct GreenTree {
    pub nodes: Vec<RawNode>,
    /// `children[i]`: the children of node `i` (indices into `nodes`), in source order.
    pub children: Vec<Vec<usize>>,
    /// The top-level nodes (normally one: the `toplevel` node of a file).
    pub roots: Vec<usize>,
    pub diagnostics: Vec<Diagnostic>,
    kind_names: HashMap<u16, String>,
}

impl GreenTree {
    pub fn kind_name(&self, kind: u16) -> &str {
        self.kind_names.get(&kind).map(|s| s.as_str()).unwrap_or("?")
    }
    pub fn name(&self, i: usize) -> &str {
        self.kind_name(self.nodes[i].kind)
    }
    pub fn has_errors(&self) -> bool {
        self.diagnostics.iter().any(|d| d.level == DiagLevel::Error)
    }
    /// The smallest node (a non-trivia interior node or a non-whitespace token) whose byte
    /// range contains `start..end`, with its ancestors (innermost first).
    pub fn covering_path(&self, start: usize, end: usize) -> Vec<usize> {
        let mut path = vec![];
        let mut level: &[usize] = &self.roots;
        'down: loop {
            for &c in level {
                let n = &self.nodes[c];
                if n.start <= start && end <= n.end && !(n.start == n.end && start != end) {
                    path.push(c);
                    level = &self.children[c];
                    continue 'down;
                }
            }
            break;
        }
        path.reverse();
        path
    }
    /// The parent of every node.
    pub fn parents(&self) -> Vec<Option<usize>> {
        let mut p = vec![None; self.nodes.len()];
        for (i, ch) in self.children.iter().enumerate() {
            for &c in ch {
                p[c] = Some(i);
            }
        }
        p
    }
}

struct Funcs {
    src_resize: TypedFunc<i32, i32>,
    src_set4: TypedFunc<(i32, i32), i32>,
    parse_src: TypedFunc<i32, i32>,
    out_kind: TypedFunc<i32, i32>,
    out_span: TypedFunc<i32, i32>,
    out_nodespan: TypedFunc<i32, i32>,
    out_flags: TypedFunc<i32, i32>,
    out_class: TypedFunc<i32, i32>,
    ndiag: TypedFunc<(), i32>,
    diag_first: TypedFunc<i32, i32>,
    diag_last: TypedFunc<i32, i32>,
    diag_level: TypedFunc<i32, i32>,
    diag_msg_len: TypedFunc<i32, i32>,
    diag_msg_byte: TypedFunc<(i32, i32), i32>,
    kind_name_len: TypedFunc<i32, i32>,
    kind_name_byte: TypedFunc<(i32, i32), i32>,
}

/// An instance of the parser. Reusable: each [`JlParser::parse`] starts afresh.
pub struct JlParser {
    store: Store<()>,
    f: Funcs,
    kind_names: HashMap<u16, String>,
}

pub type Error = String;

fn trap(e: wasmtime::Error) -> Error {
    format!("JuliaSyntax (Wasm) trapped: {e}")
}

impl JlParser {
    /// Instantiate the parser (the module is compiled or loaded once per process).
    pub fn new() -> Result<JlParser, Error> {
        let (engine, module) = engine_and_module()?;
        let mut store = Store::new(engine, ());
        let inst = Instance::new(&mut store, module, &[]).map_err(|e| format!("instantiate: {e}"))?;
        macro_rules! f {
            ($n:literal) => {
                inst.get_typed_func(&mut store, $n)
                    .map_err(|e| format!("parser.wasm export {}: {e}", $n))?
            };
        }
        let f = Funcs {
            src_resize: f!("src_resize"),
            src_set4: f!("src_set4"),
            parse_src: f!("parse_src"),
            out_kind: f!("out_kind"),
            out_span: f!("out_span"),
            out_nodespan: f!("out_nodespan"),
            out_flags: f!("out_flags"),
            out_class: f!("out_class"),
            ndiag: f!("ndiag"),
            diag_first: f!("diag_first"),
            diag_last: f!("diag_last"),
            diag_level: f!("diag_level"),
            diag_msg_len: f!("diag_msg_len"),
            diag_msg_byte: f!("diag_msg_byte"),
            kind_name_len: f!("kind_name_len"),
            kind_name_byte: f!("kind_name_byte"),
        };
        Ok(JlParser { store, f, kind_names: HashMap::new() })
    }

    /// The raw output of parsing `src`: per node `[kind, span, nodespan, class]` as the
    /// module reports them (what `check.mjs` compares), and the diagnostics.
    pub fn parse_raw(&mut self, src: &[u8], rule: Rule) -> Result<(Vec<[i32; 5]>, Vec<Diagnostic>), Error> {
        let s = &mut self.store;
        let f = &self.f;
        f.src_resize.call(&mut *s, src.len() as i32).map_err(trap)?;
        for (k, ch) in src.chunks(4).enumerate() {
            let mut w = [0u8; 4];
            w[..ch.len()].copy_from_slice(ch);
            f.src_set4.call(&mut *s, ((4 * k + 1) as i32, i32::from_le_bytes(w))).map_err(trap)?;
        }
        let n = f.parse_src.call(&mut *s, rule as i32).map_err(trap)?;
        let mut out = Vec::with_capacity(n.max(0) as usize);
        for k in 1..=n {
            out.push([
                f.out_kind.call(&mut *s, k).map_err(trap)?,
                f.out_span.call(&mut *s, k).map_err(trap)?,
                f.out_nodespan.call(&mut *s, k).map_err(trap)?,
                f.out_class.call(&mut *s, k).map_err(trap)?,
                f.out_flags.call(&mut *s, k).map_err(trap)?,
            ]);
        }
        let nd = f.ndiag.call(&mut *s, ()).map_err(trap)?;
        let mut diags = Vec::with_capacity(nd.max(0) as usize);
        for k in 1..=nd {
            let len = f.diag_msg_len.call(&mut *s, k).map_err(trap)?;
            let mut msg = Vec::with_capacity(len.max(0) as usize);
            for j in 1..=len {
                msg.push(f.diag_msg_byte.call(&mut *s, (k, j)).map_err(trap)? as u8);
            }
            diags.push(Diagnostic {
                first_byte: f.diag_first.call(&mut *s, k).map_err(trap)? as usize,
                last_byte: f.diag_last.call(&mut *s, k).map_err(trap)? as usize,
                level: match f.diag_level.call(&mut *s, k).map_err(trap)? {
                    1 => DiagLevel::Error,
                    2 => DiagLevel::Warning,
                    _ => DiagLevel::Note,
                },
                message: String::from_utf8_lossy(&msg).into_owned(),
            });
        }
        Ok((out, diags))
    }

    /// The name of kind `k`, as JuliaSyntax prints it (`call`, `Identifier`, `+`, …).
    pub fn kind_name(&mut self, k: u16) -> Result<String, Error> {
        if let Some(s) = self.kind_names.get(&k) {
            return Ok(s.clone());
        }
        let s = &mut self.store;
        let len = self.f.kind_name_len.call(&mut *s, k as i32).map_err(trap)?;
        let mut b = Vec::with_capacity(len.max(0) as usize);
        for j in 1..=len {
            b.push(self.f.kind_name_byte.call(&mut *s, (k as i32, j)).map_err(trap)? as u8);
        }
        let name = String::from_utf8_lossy(&b).into_owned();
        self.kind_names.insert(k, name.clone());
        Ok(name)
    }

    /// Parse `src` and build the green tree.
    pub fn parse(&mut self, src: &str, rule: Rule) -> Result<GreenTree, Error> {
        let (out, diagnostics) = self.parse_raw(src.as_bytes(), rule)?;
        let mut nodes = Vec::with_capacity(out.len());
        let mut children: Vec<Vec<usize>> = Vec::with_capacity(out.len());
        let mut stack: Vec<usize> = vec![];
        let mut pos = 0usize;
        for (i, o) in out.iter().enumerate() {
            let kind = o[0] as u16;
            if !self.kind_names.contains_key(&kind) {
                self.kind_name(kind)?;
            }
            let class = o[3] as u8;
            let mut node = RawNode {
                kind,
                flags: o[4] as u16,
                nodespan: o[2] as u32,
                class,
                start: pos,
                end: pos,
            };
            let mut ch = vec![];
            if class & class::INTERIOR != 0 {
                // the nodes below an interior node are the last `nodespan` ones; its
                // children are those still on the stack
                let first = i - o[2] as usize;
                while let Some(&top) = stack.last() {
                    if top >= first {
                        ch.push(stack.pop().unwrap());
                    } else {
                        break;
                    }
                }
                ch.reverse();
                if let Some(&c0) = ch.first() {
                    node.start = nodes_start(&nodes, c0);
                }
                node.end = pos;
                if ch.is_empty() {
                    node.end = pos + o[1] as usize;
                    pos = node.end;
                }
            } else {
                pos += o[1] as usize;
                node.end = pos;
            }
            nodes.push(node);
            children.push(ch);
            stack.push(i);
        }
        // the output starts with a sentinel token of no width, outside the tree
        let roots: Vec<usize> = stack
            .into_iter()
            .filter(|&i| !(nodes[i].start == nodes[i].end && !nodes[i].is_interior()))
            .collect();
        Ok(GreenTree { nodes, children, roots, diagnostics, kind_names: self.kind_names.clone() })
    }
}

fn nodes_start(nodes: &[RawNode], i: usize) -> usize {
    nodes[i].start
}

// ─── Semantic normal form ───────────────────────────────────────────

/// The normal form in which input and output are compared: the green tree without trivia
/// (whitespace, comments, punctuation and keywords implied by the node kind — except
/// error tokens, which are kept) and without TOMBSTONE tokens (the common indentation of a
/// triple-quoted string, which `build_tree` skips too). Leaves keep their exact source
/// text; nodes keep their kind and all flags but TRIVIA and NON_TERMINAL. The only
/// layout freedom beyond whitespace: `toplevel` inside `toplevel` is spliced and its
/// TOPLEVEL_SEMICOLONS flag ignored (`a; b` ≡ `a⏎b`). Stricter than `Meta.parseall` +
/// `strip_lines` (scripts/_ast_check.jl): infix vs prefix calls, macrocall parentheses,
/// trailing commas and parentheses must all be kept. `span` (where the node is in its
/// source) is not compared.
#[derive(Clone)]
pub struct Sem<'a> {
    pub kind: u16,
    pub name: &'a str,
    /// A leaf's source text (`None` for interior nodes).
    pub text: Option<&'a str>,
    pub flags: u16,
    pub children: Vec<Sem<'a>>,
    pub span: (usize, usize),
}

impl PartialEq for Sem<'_> {
    fn eq(&self, o: &Self) -> bool {
        self.kind == o.kind && self.flags == o.flags && self.text == o.text && self.children == o.children
    }
}
impl Eq for Sem<'_> {}

impl fmt::Debug for Sem<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if let Some(t) = self.text {
            return write!(f, "{} {t:?}", self.name);
        }
        write!(f, "({}", self.name)?;
        if self.flags != 0 {
            write!(f, "-{:#x}", self.flags)?;
        }
        for c in &self.children {
            write!(f, " {c:?}")?;
        }
        write!(f, ")")
    }
}

/// The flag bits that are compared: all but TRIVIA (bit 0) and NON_TERMINAL (bit 7) — the
/// formatter must not turn `a + b` into `+(a, b)`, `@m(x)` into `@m x`, drop a trailing comma
/// or parentheses — except TOPLEVEL_SEMICOLONS on `toplevel` (`a; b` may become two lines).
fn semantic_flags(kind: &str, flags: u16) -> u16 {
    let f = flags & !(1 | (1 << 7));
    if kind == "toplevel" { f & !(1 << 8) } else { f }
}

/// The comments of a tree, in order, with trailing whitespace trimmed.
pub fn comments(tree: &GreenTree, src: &str) -> Vec<String> {
    tree.nodes
        .iter()
        .filter(|n| !n.is_interior() && tree.kind_name(n.kind) == "Comment")
        .map(|n| src[n.start..n.end].trim_end().to_string())
        .collect()
}

/// The semantic normal form of the tree's roots.
pub fn sem_tree<'a>(tree: &'a GreenTree, src: &'a str) -> Vec<Sem<'a>> {
    let mut out = vec![];
    for &r in &tree.roots {
        push_sem(tree, src, r, "", &mut out);
    }
    out
}

fn push_sem<'a>(tree: &'a GreenTree, src: &'a str, i: usize, parent: &str, out: &mut Vec<Sem<'a>>) {
    let n = &tree.nodes[i];
    let name = tree.kind_name(n.kind);
    if !n.is_interior() {
        // error tokens are kept even when flagged trivia; TOMBSTONEs (the common indentation
        // of a triple-quoted string) are skipped, as `build_tree` does
        if (!n.is_error() && (n.is_trivia() || n.is_whitespace())) || name == "TOMBSTONE" {
            return;
        }
        // An operator token and an identifier with the same text are the same symbol
        // (JuliaSyntax lexes `<:` as `Identifier` or as `<:` depending on context, e.g.
        // `a +\n\n<:` vs `a + <:`); compare such leaves by text alone.
        let kind = if n.class & (class::OPERATOR | class::IDENTIFIER) != 0 { u16::MAX } else { n.kind };
        out.push(Sem {
            kind,
            name,
            text: Some(&src[n.start..n.end]),
            flags: semantic_flags(name, n.flags),
            children: vec![],
            span: (n.start, n.end),
        });
        return;
    }
    let splice = name == "toplevel" && parent == "toplevel";
    if splice {
        for &c in &tree.children[i] {
            push_sem(tree, src, c, parent, out);
        }
        return;
    }
    let mut children = vec![];
    for &c in &tree.children[i] {
        push_sem(tree, src, c, name, &mut children);
    }
    out.push(Sem { kind: n.kind, name, text: None, flags: semantic_flags(name, n.flags), children, span: (n.start, n.end) });
}

/// The first difference between two semantic trees: a description, and the span (in the
/// source of `a`) of the innermost node of `a` that differs.
fn diff<'x>(a: &'x [Sem], b: &'x [Sem], path: &str, parent_span: (usize, usize)) -> Option<(String, (usize, usize))> {
    for k in 0..a.len().max(b.len()) {
        let p = format!("{path}[{}]", k + 1);
        match (a.get(k), b.get(k)) {
            (Some(x), None) => return Some((format!("{p}: missing after formatting (was {x:?})"), x.span)),
            (None, Some(y)) => return Some((format!("{p}: added by formatting ({y:?})"), parent_span)),
            (Some(x), Some(y)) if x != y => {
                if x.kind == y.kind && x.flags == y.flags && x.text.is_none() && y.text.is_none() {
                    return diff(&x.children, &y.children, &format!("{p}.{}", x.name), x.span);
                }
                return Some((format!("{p}: {x:?} became {y:?}"), x.span));
            }
            _ => {}
        }
    }
    None
}

/// Where two semantic trees first differ, as a path and the two subtrees; `None` if equal.
pub fn first_difference(a: &[Sem], b: &[Sem]) -> Option<String> {
    diff(a, b, "", (0, 0)).map(|d| d.0)
}

/// The span, in the first tree's source, of the innermost node where the trees differ.
pub fn first_difference_span(a: &[Sem], b: &[Sem]) -> Option<(usize, usize)> {
    let whole = (a.first().map(|s| s.span.0).unwrap_or(0), a.last().map(|s| s.span.1).unwrap_or(0));
    diff(a, b, "", whole).map(|d| d.1)
}

/// The outcome of checking a formatting of `before` into `after`.
#[derive(Debug)]
pub enum Verdict {
    /// Same meaning (and the same comments).
    Equivalent,
    /// The input doesn't parse cleanly with JuliaSyntax: nothing to compare against.
    InputHasErrors(Vec<Diagnostic>),
    /// The output doesn't parse cleanly (the input does).
    OutputHasErrors(Vec<Diagnostic>),
    /// Different trees: where.
    Changed(String),
    /// Same trees, but comments were dropped, added or changed.
    CommentsChanged(String),
}

impl JlParser {
    /// Check that `after` (the formatter's output) means the same as `before`.
    pub fn verify(&mut self, before: &str, after: &str) -> Result<Verdict, Error> {
        let a = self.parse(before, Rule::All)?;
        if a.has_errors() {
            return Ok(Verdict::InputHasErrors(a.diagnostics));
        }
        let b = self.parse(after, Rule::All)?;
        if b.has_errors() {
            return Ok(Verdict::OutputHasErrors(b.diagnostics));
        }
        if let Some(d) = first_difference(&sem_tree(&a, before), &sem_tree(&b, after)) {
            return Ok(Verdict::Changed(d));
        }
        let (ca, cb) = (comments(&a, before), comments(&b, after));
        if ca != cb {
            let k = ca.iter().zip(&cb).take_while(|(x, y)| x == y).count();
            return Ok(Verdict::CommentsChanged(format!(
                "comment {}: {:?} became {:?}",
                k + 1,
                ca.get(k).map(|s| s.as_str()).unwrap_or("(none)"),
                cb.get(k).map(|s| s.as_str()).unwrap_or("(none)")
            )));
        }
        Ok(Verdict::Equivalent)
    }
}

/// 1-based (line, column) of a 0-based byte offset; the column counts characters.
pub fn line_col(src: &str, byte: usize) -> (usize, usize) {
    let byte = byte.min(src.len());
    let before = &src[..floor_char_boundary(src, byte)];
    let line = before.matches('\n').count() + 1;
    let col = before.rsplit('\n').next().map(|l| l.chars().count()).unwrap_or(0) + 1;
    (line, col)
}

fn floor_char_boundary(s: &str, mut i: usize) -> usize {
    while i > 0 && !s.is_char_boundary(i) {
        i -= 1;
    }
    i
}

/// Diagnostics as `name:line:col: error: message` lines.
pub fn format_diagnostics(name: &str, src: &str, diags: &[Diagnostic]) -> String {
    let mut s = String::new();
    for d in diags {
        let (l, c) = line_col(src, d.first_byte.saturating_sub(1));
        let lvl = match d.level {
            DiagLevel::Error => "error",
            DiagLevel::Warning => "warning",
            DiagLevel::Note => "note",
        };
        let excerpt: String = src
            .get(d.first_byte.saturating_sub(1)..d.last_byte.min(src.len()))
            .unwrap_or("")
            .chars()
            .take(40)
            .collect();
        s.push_str(&format!("{name}:{l}:{c}: {lvl}: {} (at {excerpt:?})\n", d.message));
    }
    s
}
