use std::fs;
use std::io::{self, BufWriter, Read, Write};
use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Parser, Subcommand};
use topiary_core::{formatter, Language, Operation, TopiaryQuery};
use topiary_julia::sexp;
use topiary_tree_sitter_facade::Language as Grammar;

mod parse;
#[cfg(feature = "jlparse")]
mod corpus;

pub(crate) const QUERY: &str = include_str!("../julia.scm");

#[derive(Parser)]
#[command(name = "topiary-julia", about = "Format Julia source code")]
struct Cli {
    #[command(subcommand)]
    command: Option<Command>,

    // ─── Legacy top-level flags (format command is the default) ────────
    /// Input file (reads from stdin if omitted). Used when no subcommand is given.
    input: Option<PathBuf>,

    /// Output file (writes to stdout if omitted)
    #[arg(short, long)]
    output: Option<PathBuf>,

    /// Skip idempotence check
    #[arg(long)]
    skip_idempotence: bool,

    /// Tolerate parsing errors (format around them)
    #[arg(long)]
    tolerate_parsing_errors: bool,

    /// Check mode: exit 1 if input is not already formatted
    #[arg(short, long)]
    check: bool,

    /// Don't verify the output with Julia's own parser (JuliaSyntax in Wasm): plain Topiary,
    /// as before. Without it, an output that parses to a different tree than the input is
    /// never written, code tree-sitter-julia can't parse is left verbatim, and syntax errors
    /// are reported with JuliaSyntax's diagnostics.
    #[arg(long)]
    no_verify: bool,

    /// Don't print notes about regions left verbatim.
    #[arg(short, long)]
    quiet: bool,
}

#[derive(Subcommand)]
enum Command {
    /// Print the tree-sitter-julia CST as an S-expression (reads stdin).
    ///
    /// Exit codes:
    ///   0 — parse succeeded with no ERROR/MISSING nodes
    ///   2 — parse produced ERROR/MISSING nodes; sexp is still written to stdout
    Parse,

    /// Print JuliaSyntax's tree (Julia's own parser, in Wasm) and diagnostics (reads stdin).
    ///
    /// Exit codes: 0 — no errors; 2 — JuliaSyntax reported errors.
    #[cfg(feature = "jlparse")]
    JlParse {
        /// Print the normal form used to compare input and output (no trivia, no positions)
        #[arg(long)]
        sem: bool,
    },

    /// Check that AFTER means the same as BEFORE, according to JuliaSyntax (exit 0) or not (1).
    #[cfg(feature = "jlparse")]
    Verify { before: PathBuf, after: PathBuf },

    /// Corpus run: format each file listed on stdin (one path per line) with verification,
    /// in parallel, writing one JSON line per file to stdout (nothing is written to the files).
    #[cfg(feature = "jlparse")]
    #[command(hide = true)]
    JlCorpus {
        /// Worker threads
        #[arg(long, default_value_t = 4)]
        jobs: usize,
        /// Seconds after which a file is reported as a timeout (its worker is abandoned)
        #[arg(long, default_value_t = 60)]
        timeout: u64,
    },
}

fn make_language() -> Result<Language, Box<dyn std::error::Error>> {
    let grammar: Grammar = tree_sitter_julia::LANGUAGE.into();
    let query = match TopiaryQuery::new(&grammar, QUERY) {
        Ok(q) => q,
        Err(e) => {
            eprintln!("Query error: {e:?}");
            return Err(e.into());
        }
    };
    Ok(Language {
        name: "julia".into(),
        query,
        grammar,
        indent: Some("    ".into()),
    })
}

fn read_stdin() -> io::Result<String> {
    let mut buf = String::new();
    io::stdin().read_to_string(&mut buf)?;
    Ok(buf)
}

fn run_parse() -> ExitCode {
    let input = match read_stdin() {
        Ok(s) => s,
        Err(e) => {
            eprintln!("Failed to read stdin: {e}");
            return ExitCode::FAILURE;
        }
    };
    let Some(tree) = sexp::parse_julia(&input) else {
        eprintln!("Failed to parse input");
        return ExitCode::from(2);
    };
    let sexp_text = parse::tree_to_sexp(&tree, &input);
    let has_errors = sexp::tree_has_errors(&tree);

    let stdout = io::stdout();
    let mut handle = BufWriter::new(stdout.lock());
    let _ = writeln!(handle, "{sexp_text}");

    if has_errors {
        ExitCode::from(2)
    } else {
        ExitCode::SUCCESS
    }
}

#[cfg(feature = "jlparse")]
fn run_jlparse(sem: bool) -> ExitCode {
    use topiary_julia::jlparse::{self, JlParser, Rule};
    let input = match read_stdin() {
        Ok(s) => s,
        Err(e) => {
            eprintln!("Failed to read stdin: {e}");
            return ExitCode::FAILURE;
        }
    };
    let tree = match JlParser::new().and_then(|mut p| p.parse(&input, Rule::All)) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };
    let stdout = io::stdout();
    let mut h = BufWriter::new(stdout.lock());
    if sem {
        for s in jlparse::sem_tree(&tree, &input) {
            let _ = writeln!(h, "{s:?}");
        }
    } else {
        fn pr(h: &mut impl Write, t: &jlparse::GreenTree, src: &str, i: usize, d: usize) {
            let n = &t.nodes[i];
            if n.is_interior() {
                let _ = writeln!(h, "{:w$}[{}] {}:{} flags={:#x}", "", t.name(i), n.start, n.end, n.flags, w = 2 * d);
                for &c in &t.children[i] {
                    pr(h, t, src, c, d + 1);
                }
            } else if !n.is_whitespace() || t.name(i) == "Comment" {
                let triv = if n.is_trivia() { " ~" } else { "" };
                let _ = writeln!(h, "{:w$}{} {:?}{triv}", "", t.name(i), &src[n.start..n.end], w = 2 * d);
            }
        }
        for &r in &tree.roots {
            pr(&mut h, &tree, &input, r, 0);
        }
    }
    let _ = write!(h, "{}", jlparse::format_diagnostics("stdin", &input, &tree.diagnostics));
    if tree.has_errors() { ExitCode::from(2) } else { ExitCode::SUCCESS }
}

#[cfg(feature = "jlparse")]
fn run_verify(before: &PathBuf, after: &PathBuf) -> ExitCode {
    use topiary_julia::jlparse::{self, JlParser, Verdict};
    let (a, b) = match (fs::read_to_string(before), fs::read_to_string(after)) {
        (Ok(a), Ok(b)) => (a, b),
        _ => {
            eprintln!("Failed to read the files");
            return ExitCode::FAILURE;
        }
    };
    match JlParser::new().and_then(|mut p| p.verify(&a, &b)) {
        Ok(Verdict::Equivalent) => ExitCode::SUCCESS,
        Ok(Verdict::InputHasErrors(d)) => {
            eprint!("{}", jlparse::format_diagnostics(&before.display().to_string(), &a, &d));
            ExitCode::from(2)
        }
        Ok(Verdict::OutputHasErrors(d)) => {
            eprint!("{}", jlparse::format_diagnostics(&after.display().to_string(), &b, &d));
            ExitCode::FAILURE
        }
        Ok(Verdict::Changed(d)) | Ok(Verdict::CommentsChanged(d)) => {
            eprintln!("not equivalent: {d}");
            ExitCode::FAILURE
        }
        Err(e) => {
            eprintln!("{e}");
            ExitCode::FAILURE
        }
    }
}

/// Format with JuliaSyntax as the referee: `Some(output)`, or `None` after reporting why not.
#[cfg(feature = "jlparse")]
fn format_checked(cli: &Cli, input: &str, language: &Language) -> Option<Vec<u8>> {
    use topiary_julia::format::{format_verified, Outcome, Reason};
    use topiary_julia::jlparse::{self, JlParser};
    let name = cli.input.as_ref().map(|p| p.display().to_string()).unwrap_or_else(|| "stdin".into());
    let mut jl = match JlParser::new() {
        Ok(p) => p,
        Err(e) => {
            eprintln!("Julia's parser (Wasm) failed to start: {e}\n(use --no-verify to format without it)");
            return None;
        }
    };
    match format_verified(input, language, &mut jl, cli.skip_idempotence) {
        Ok(Outcome::Formatted { output, protected }) => {
            if !cli.quiet {
                for p in &protected {
                    let (l, c) = jlparse::line_col(input, p.start);
                    let why = match p.reason {
                        Reason::GrammarGap => "tree-sitter-julia can't parse it",
                        Reason::NotPreserved => "formatting it would change its meaning",
                    };
                    eprintln!("note: {name}:{l}:{c}: left `{}` verbatim ({why})", p.kind);
                }
            }
            Some(output.into_bytes())
        }
        Ok(Outcome::SyntaxErrors(d)) => {
            eprint!("{}", jlparse::format_diagnostics(&name, input, &d));
            if cli.tolerate_parsing_errors {
                // as before: let Topiary format around the errors (unverifiable)
                let mut out = Vec::new();
                let op = Operation::Format { skip_idempotence: cli.skip_idempotence, tolerate_parsing_errors: true };
                return match formatter(&mut input.as_bytes(), &mut out, language, op) {
                    Ok(()) => Some(out),
                    Err(e) => {
                        eprintln!("Formatting failed: {e}");
                        None
                    }
                };
            }
            None
        }
        Ok(Outcome::Refused(why)) => {
            eprintln!("Formatting refused: {why}");
            None
        }
        Err(e) => {
            eprintln!("Julia's parser (Wasm) failed: {e}");
            None
        }
    }
}

fn run_format(cli: &Cli) -> ExitCode {
    let language = match make_language() {
        Ok(l) => l,
        Err(e) => {
            eprintln!("Failed to initialize language: {e}");
            return ExitCode::FAILURE;
        }
    };

    let operation = Operation::Format {
        skip_idempotence: cli.skip_idempotence,
        tolerate_parsing_errors: cli.tolerate_parsing_errors,
    };

    let input_content = match &cli.input {
        Some(path) => match fs::read_to_string(path) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("Failed to read {}: {e}", path.display());
                return ExitCode::FAILURE;
            }
        },
        None => match read_stdin() {
            Ok(s) => s,
            Err(e) => {
                eprintln!("Failed to read stdin: {e}");
                return ExitCode::FAILURE;
            }
        },
    };

    let mut output_buf = Vec::new();
    #[cfg(feature = "jlparse")]
    let verified = !cli.no_verify;
    #[cfg(not(feature = "jlparse"))]
    let verified = false;
    if verified {
        #[cfg(feature = "jlparse")]
        match format_checked(cli, &input_content, &language) {
            Some(out) => output_buf = out,
            None => return ExitCode::FAILURE,
        }
    } else if let Err(e) = formatter(
        &mut input_content.as_bytes(),
        &mut output_buf,
        &language,
        operation,
    ) {
        eprintln!("Formatting failed: {e}");
        return ExitCode::FAILURE;
    }

    if cli.check {
        if output_buf != input_content.as_bytes() {
            eprintln!("File is not formatted");
            return ExitCode::FAILURE;
        }
        return ExitCode::SUCCESS;
    }

    match &cli.output {
        Some(path) => {
            if let Err(e) = fs::write(path, &output_buf) {
                eprintln!("Failed to write {}: {e}", path.display());
                return ExitCode::FAILURE;
            }
        }
        None => {
            let stdout = io::stdout();
            let mut handle = BufWriter::new(stdout.lock());
            if let Err(e) = handle.write_all(&output_buf) {
                eprintln!("Failed to write stdout: {e}");
                return ExitCode::FAILURE;
            }
        }
    }

    ExitCode::SUCCESS
}

fn main() -> ExitCode {
    env_logger::init();
    let cli = Cli::parse();

    match cli.command {
        Some(Command::Parse) => run_parse(),
        #[cfg(feature = "jlparse")]
        Some(Command::JlParse { sem }) => run_jlparse(sem),
        #[cfg(feature = "jlparse")]
        Some(Command::Verify { ref before, ref after }) => run_verify(before, after),
        #[cfg(feature = "jlparse")]
        Some(Command::JlCorpus { jobs, timeout }) => corpus::run(jobs, timeout),
        None => run_format(&cli),
    }
}
