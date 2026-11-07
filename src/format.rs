//! Formatting with Julia's own parser as the referee.
//!
//! 1. **Safety net.** Every output is parsed by JuliaSyntax (see [`crate::jlparse`]) and
//!    compared with the input in an Expr-like normal form; an output that means something
//!    else is never returned.
//! 2. **Grammar gaps.** Where tree-sitter-julia can't parse code that JuliaSyntax parses
//!    cleanly, or where formatting would change the meaning, the smallest JuliaSyntax node
//!    around the problem is *protected*: replaced by a placeholder identifier for Topiary,
//!    and put back verbatim afterwards. If the placeholdered source still doesn't parse
//!    with tree-sitter, or the result still doesn't verify, the protected node grows to its
//!    parent, up to the whole file (which is then left as it is).
//! 3. **Exact syntax errors.** Input that JuliaSyntax rejects is reported with JuliaSyntax's
//!    diagnostics.

use topiary_core::{formatter, Language, Operation};
use topiary_tree_sitter_facade::Node;

use crate::jlparse::{self, Diagnostic, GreenTree, JlParser, Rule, Verdict};
use crate::sexp;

/// How a formatting went.
#[derive(Debug)]
pub enum Outcome {
    /// Formatted, and JuliaSyntax agrees the output means the same as the input.
    /// `protected` lists the regions of the input left verbatim (empty: none).
    Formatted { output: String, protected: Vec<Protected> },
    /// The input is not valid Julia, according to JuliaSyntax.
    SyntaxErrors(Vec<Diagnostic>),
    /// No verified output could be produced (should not happen: the whole file can always
    /// be left as it is); the reason.
    Refused(String),
}

/// A region of the input left verbatim, and why.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Protected {
    pub start: usize,
    pub end: usize,
    /// The JuliaSyntax kind of the protected node.
    pub kind: String,
    pub reason: Reason,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Reason {
    /// tree-sitter-julia can't parse it (ERROR/MISSING), JuliaSyntax can.
    GrammarGap,
    /// Formatting it changed its meaning (or its comments).
    NotPreserved,
}

/// Format `input` with Topiary (no verification): `Err` on Topiary errors.
pub fn topiary_format(input: &str, language: &Language, skip_idempotence: bool) -> Result<String, String> {
    let mut out = Vec::new();
    formatter(
        &mut input.as_bytes(),
        &mut out,
        language,
        Operation::Format { skip_idempotence, tolerate_parsing_errors: false },
    )
    .map_err(|e| format!("{e}"))?;
    String::from_utf8(out).map_err(|e| format!("{e}"))
}

/// Byte ranges of the ERROR and MISSING nodes of tree-sitter's parse of `src` (outermost
/// only); empty if it parses cleanly.
pub fn ts_error_ranges(src: &str) -> Vec<(usize, usize)> {
    fn walk(n: &Node, out: &mut Vec<(usize, usize)>) {
        if n.kind() == "ERROR" || n.is_error() || n.is_missing() {
            out.push((n.start_byte() as usize, n.end_byte() as usize));
            return;
        }
        for i in 0..n.child_count() {
            if let Some(c) = n.child(i) {
                walk(&c, out);
            }
        }
    }
    let mut v = vec![];
    match sexp::parse_julia(src) {
        Some(t) => walk(&t.root_node(), &mut v),
        None => v.push((0, src.len())),
    }
    v
}

/// The range of node `i` without leading/trailing whitespace and comments.
fn core_range(t: &GreenTree, i: usize) -> (usize, usize) {
    let mut lo = None;
    let mut hi = None;
    fn tokens(t: &GreenTree, i: usize, f: &mut dyn FnMut(usize)) {
        if t.nodes[i].is_interior() {
            for &c in &t.children[i] {
                tokens(t, c, f);
            }
        } else {
            f(i);
        }
    }
    tokens(t, i, &mut |k| {
        let n = &t.nodes[k];
        if !n.is_whitespace() && n.end > n.start {
            lo.get_or_insert(n.start);
            hi = Some(n.end);
        }
    });
    match (lo, hi) {
        (Some(a), Some(b)) => (a, b),
        _ => (t.nodes[i].start, t.nodes[i].end),
    }
}

/// A protected node: the JuliaSyntax node index and its core range.
#[derive(Clone, Copy, Debug)]
struct Region {
    node: usize,
    start: usize,
    end: usize,
    reason: Reason,
}

struct Ctx<'a> {
    src: &'a str,
    tree: &'a GreenTree,
    parents: Vec<Option<usize>>,
    placeholder_stem: String,
}

impl Ctx<'_> {
    fn is_container(&self, i: usize) -> bool {
        matches!(self.tree.name(i), "toplevel" | "block")
    }

    /// Candidate nodes to protect for a problem at `start..end` of the input, best first.
    fn candidates(&self, start: usize, end: usize) -> Vec<usize> {
        let path = self.tree.covering_path(start, end);
        let Some(&inner) = path.first() else { return vec![] };
        // a non-whitespace token or an expression covers it: take that (trivia tokens, e.g.
        // a keyword or a bracket: their parent)
        let mut i = inner;
        while self.tree.nodes[i].is_whitespace() || (!self.tree.nodes[i].is_interior() && self.tree.nodes[i].is_trivia()) {
            match self.parents[i] {
                Some(p) => i = p,
                None => break,
            }
        }
        if !self.is_container(i) {
            return vec![i];
        }
        // between the statements of a block: the statements it touches, then the one after
        // it (tree-sitter tends to fail on the separator before the unexpected statement),
        // then the one before, then the whole block
        let kids = self.kids(i);
        let mut v: Vec<usize> = kids
            .iter()
            .copied()
            .filter(|&c| {
                let (a, b) = core_range(self.tree, c);
                a < end.max(start + 1) && start < b
            })
            .collect();
        if let Some(&after) = kids.iter().find(|&&c| core_range(self.tree, c).0 >= start) {
            v.push(after);
        }
        if let Some(&before) = kids.iter().rev().find(|&&c| core_range(self.tree, c).1 <= start) {
            v.push(before);
        }
        v.push(i);
        v
    }

    /// The node to protect next for a problem at `start..end`: the first candidate not yet
    /// protected; if all are, the parent of the protected region that covers the first.
    fn next_for(&self, regions: &[Region], start: usize, end: usize) -> Option<usize> {
        let cands = self.candidates(start, end);
        let covered = |n: usize| {
            let (a, b) = core_range(self.tree, n);
            regions.iter().find(|r| r.start <= a && b <= r.end).copied()
        };
        for &c in &cands {
            if covered(c).is_none() {
                return Some(c);
            }
        }
        let r = covered(*cands.first()?)?;
        self.grow(r.node)
    }

    /// The protectable children of node `i`: not whitespace/comments, not trivia tokens,
    /// not empty.
    fn kids(&self, i: usize) -> Vec<usize> {
        self.tree.children[i]
            .iter()
            .copied()
            .filter(|&c| {
                let n = &self.tree.nodes[c];
                let (a, b) = core_range(self.tree, c);
                !n.is_whitespace() && !(n.is_trivia() && !n.is_interior()) && a < b
            })
            .collect()
    }

    /// The JuliaSyntax nodes tree-sitter can't parse, found statement by statement: a
    /// top-level statement that tree-sitter rejects is searched for the innermost node whose
    /// replacement by a placeholder makes the statement parse (children that fail on their
    /// own are tried first); if there is none, the statement itself.
    fn localize(&self) -> Vec<usize> {
        let ph = self.placeholder(9);
        let clean = |t: &str| ts_error_ranges(t).is_empty();
        let mut found = vec![];
        let Some(&root) = self.tree.roots.first() else { return found };
        for stmt in self.kids(root) {
            let (sa, sb) = core_range(self.tree, stmt);
            if clean(&self.src[sa..sb]) {
                continue;
            }
            let mut node = stmt;
            'descend: loop {
                let mut kids = self.kids(node);
                // standalone failures first (stable)
                kids.sort_by_key(|&c| {
                    let (a, b) = core_range(self.tree, c);
                    clean(&self.src[a..b])
                });
                for c in kids {
                    let (a, b) = core_range(self.tree, c);
                    if (a, b) == core_range(self.tree, node) {
                        node = c;
                        continue 'descend;
                    }
                    let t = format!("{}{}{}", &self.src[sa..a], ph, &self.src[b..sb]);
                    if clean(&t) {
                        node = c;
                        continue 'descend;
                    }
                }
                break;
            }
            found.push(node);
        }
        found
    }

    /// The parent of a protected node whose core range is larger (`None` at the top).
    fn grow(&self, node: usize) -> Option<usize> {
        let r = core_range(self.tree, node);
        let mut i = node;
        while let Some(p) = self.parents[i] {
            if core_range(self.tree, p) != r {
                return Some(p);
            }
            i = p;
        }
        None
    }

    fn region(&self, node: usize, reason: Reason) -> Region {
        let (start, end) = core_range(self.tree, node);
        Region { node, start, end, reason }
    }

    /// The source with each region replaced by a placeholder, and where each placeholder
    /// is in it.
    fn placeholdered(&self, regions: &[Region]) -> (String, Vec<(usize, usize)>) {
        let mut s = String::with_capacity(self.src.len());
        let mut at = vec![];
        let mut pos = 0;
        for (k, r) in regions.iter().enumerate() {
            s.push_str(&self.src[pos..r.start]);
            let a = s.len();
            s.push_str(&format!("{}{k}_", self.placeholder_stem));
            at.push((a, s.len()));
            pos = r.end;
        }
        s.push_str(&self.src[pos..]);
        (s, at)
    }

    fn placeholder(&self, k: usize) -> String {
        format!("{}{k}_", self.placeholder_stem)
    }

    /// Map a range of the placeholdered source back to the input.
    fn to_input(&self, regions: &[Region], at: &[(usize, usize)], a: usize, b: usize) -> (usize, usize, Option<usize>) {
        // inside or touching a placeholder → that region
        for (k, &(pa, pb)) in at.iter().enumerate() {
            if a < pb && pa < b.max(a + 1) {
                return (regions[k].start, regions[k].end, Some(k));
            }
        }
        let map = |x: usize| -> usize {
            let mut delta: isize = 0;
            for (k, &(pa, pb)) in at.iter().enumerate() {
                if pb <= x {
                    delta += (regions[k].end - regions[k].start) as isize - (pb - pa) as isize;
                }
            }
            (x as isize + delta).max(0) as usize
        };
        (map(a), map(b), None)
    }
}

/// Insert `r` into the sorted, disjoint `regions`, absorbing the regions it contains.
fn add_region(regions: &mut Vec<Region>, r: Region) {
    regions.retain(|q| !(r.start <= q.start && q.end <= r.end));
    if regions.iter().any(|q| q.start <= r.start && r.end <= q.end) {
        return;
    }
    // partial overlaps cannot happen between JuliaSyntax nodes' core ranges, except via
    // grow(); keep it simple: drop any overlapping region
    regions.retain(|q| q.end <= r.start || r.end <= q.start);
    let k = regions.iter().position(|q| q.start > r.start).unwrap_or(regions.len());
    regions.insert(k, r);
}

/// Format `input`, verifying the result with JuliaSyntax and protecting what tree-sitter or
/// the formatter get wrong.
pub fn format_verified(
    input: &str,
    language: &Language,
    jl: &mut JlParser,
    skip_idempotence: bool,
) -> Result<Outcome, jlparse::Error> {
    let tree = jl.parse(input, Rule::All)?;
    if tree.has_errors() {
        return Ok(Outcome::SyntaxErrors(tree.diagnostics));
    }
    let mut stem = String::from("__jlv");
    while input.contains(&stem) {
        stem.push('_');
    }
    let ctx = Ctx { src: input, parents: tree.parents(), tree: &tree, placeholder_stem: stem };
    let sem_in = jlparse::sem_tree(&tree, input);
    let comments_in = jlparse::comments(&tree, input);

    let mut regions: Vec<Region> = vec![];
    if !ts_error_ranges(input).is_empty() {
        for n in ctx.localize() {
            add_region(&mut regions, ctx.region(n, Reason::GrammarGap));
        }
    }
    let max_rounds = 200;
    for _round in 0..max_rounds {
        let (p, at) = ctx.placeholdered(&regions);

        log::debug!(
            "round {_round}: protecting {:?}",
            regions.iter().map(|r| (tree.name(r.node), &input[r.start..r.end])).collect::<Vec<_>>()
        );
        // (a) tree-sitter must parse the placeholdered source cleanly
        let errs = ts_error_ranges(&p);
        if let Some(&(a, b)) = errs.first() {
            let (ia, ib, hit) = ctx.to_input(&regions, &at, a, b);
            log::debug!("tree-sitter error at {a}..{b} of the placeholdered source: {:?}", &p[a..b]);
            let next = match hit {
                Some(k) => match ctx.grow(regions[k].node) {
                    Some(n) => n,
                    None => break,
                },
                None => match ctx.next_for(&regions, ia, ib) {
                    Some(n) => n,
                    None => break,
                },
            };
            add_region(&mut regions, ctx.region(next, Reason::GrammarGap));
            continue;
        }

        // (b) format, put the protected text back
        let formatted = match topiary_format(&p, language, skip_idempotence) {
            Ok(f) => f,
            Err(e) => {
                // Topiary failed on this text (e.g. idempotence): protect everything at the top
                if regions.len() == 1 && ctx.grow(regions[0].node).is_none() {
                    return Ok(Outcome::Refused(format!("Topiary: {e}")));
                }
                let all = tree.roots.first().copied().unwrap_or(0);
                regions.clear();
                add_region(&mut regions, ctx.region(all, Reason::NotPreserved));
                continue;
            }
        };
        let mut output = formatted.clone();
        let mut ok = true;
        for (k, r) in regions.iter().enumerate().rev() {
            let ph = ctx.placeholder(k);
            if output.matches(&ph).count() != 1 {
                ok = false;
                break;
            }
            output = output.replacen(&ph, &input[r.start..r.end], 1);
        }
        if !ok {
            // a placeholder was dropped or duplicated: grow every region
            let grown: Vec<Region> =
                regions.iter().filter_map(|r| ctx.grow(r.node).map(|n| ctx.region(n, r.reason))).collect();
            if grown.is_empty() {
                break;
            }
            regions.clear();
            for g in grown {
                add_region(&mut regions, g);
            }
            continue;
        }

        // (c) JuliaSyntax must agree
        let out_tree = jl.parse(&output, Rule::All)?;
        let problem: Option<(usize, usize)> = if out_tree.has_errors() {
            // map the first error back: protect around the same place in the input
            let d = &out_tree.diagnostics[0];
            Some(approx_input_range(input, &output, d.first_byte.saturating_sub(1), d.last_byte))
        } else {
            let sem_out = jlparse::sem_tree(&out_tree, &output);
            match jlparse::first_difference_span(&sem_in, &sem_out) {
                Some(span) => Some(span),
                None => {
                    let comments_out = jlparse::comments(&out_tree, &output);
                    if comments_out == comments_in {
                        let protected = regions
                            .iter()
                            .map(|r| Protected {
                                start: r.start,
                                end: r.end,
                                kind: tree.name(r.node).to_string(),
                                reason: r.reason,
                            })
                            .collect();
                        return Ok(Outcome::Formatted { output, protected });
                    }
                    // a comment was lost or moved: find the first differing one
                    let k = comments_in.iter().zip(&comments_out).take_while(|(x, y)| x == y).count();
                    let cs: Vec<&jlparse::RawNode> = tree
                        .nodes
                        .iter()
                        .filter(|n| !n.is_interior() && tree.kind_name(n.kind) == "Comment")
                        .collect();
                    let c = cs.get(k.min(cs.len().saturating_sub(1)));
                    c.map(|n| (n.start, n.end))
                }
            }
        };
        log::debug!("output does not verify, problem at {problem:?} in the input; output:\n{output}");
        let Some((a, b)) = problem else { break };
        let next = match ctx.next_for(&regions, a, b) {
            Some(n) => n,
            None => break,
        };
        add_region(&mut regions, ctx.region(next, Reason::NotPreserved));
    }
    // Fallback: leave the input as it is (it trivially means the same).
    let output = format!("{}\n", input.trim_end());
    if let Verdict::Equivalent = jl.verify(input, &output)? {
        let all = tree.roots.first().copied().unwrap_or(0);
        return Ok(Outcome::Formatted {
            output,
            protected: vec![Protected {
                start: 0,
                end: input.len(),
                kind: tree.name(all).to_string(),
                reason: Reason::NotPreserved,
            }],
        });
    }
    Ok(Outcome::Refused("no formatting of this file could be verified".into()))
}

/// The input range that corresponds to `a..b` of the output, approximately: the same
/// line, by counting non-whitespace characters.
fn approx_input_range(input: &str, output: &str, a: usize, b: usize) -> (usize, usize) {
    let nonws = |s: &str, upto: usize| s[..upto.min(s.len())].chars().filter(|c| !c.is_whitespace()).count();
    let find = |count: usize| -> usize {
        let mut k = 0;
        for (i, c) in input.char_indices() {
            if !c.is_whitespace() {
                if k == count {
                    return i;
                }
                k += 1;
            }
        }
        input.len()
    };
    let fa = find(nonws(output, floor(output, a)));
    let fb = find(nonws(output, floor(output, b))).max(fa);
    (fa, fb)
}

fn floor(s: &str, mut i: usize) -> usize {
    i = i.min(s.len());
    while i > 0 && !s.is_char_boundary(i) {
        i -= 1;
    }
    i
}
