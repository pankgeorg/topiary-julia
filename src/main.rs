use std::fs;
use std::io::{self, BufWriter, Read, Write};
use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Parser, Subcommand};
use topiary_core::{formatter, Language, Operation, TopiaryQuery};
use topiary_julia::sexp;
use topiary_tree_sitter_facade::Language as Grammar;

mod parse;

const QUERY: &str = include_str!("../julia.scm");

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
}

#[derive(Subcommand)]
enum Command {
    /// Print the tree-sitter-julia CST as an S-expression (reads stdin).
    ///
    /// Exit codes:
    ///   0 — parse succeeded with no ERROR/MISSING nodes
    ///   2 — parse produced ERROR/MISSING nodes; sexp is still written to stdout
    Parse,
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
    if let Err(e) = formatter(
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
        None => run_format(&cli),
    }
}
