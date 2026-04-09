use std::fs;
use std::io::{self, BufWriter, Read, Write};
use std::path::PathBuf;
use std::process::ExitCode;

use clap::Parser;
use topiary_core::{formatter, Language, Operation, TopiaryQuery};
use topiary_tree_sitter_facade::Language as Grammar;

const QUERY: &str = include_str!("../julia.scm");

#[derive(Parser)]
#[command(name = "topiary-julia", about = "Format Julia source code")]
struct Cli {
    /// Input file (reads from stdin if omitted)
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

fn main() -> ExitCode {
    env_logger::init();
    let cli = Cli::parse();

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
        None => {
            let mut buf = String::new();
            if let Err(e) = io::stdin().read_to_string(&mut buf) {
                eprintln!("Failed to read stdin: {e}");
                return ExitCode::FAILURE;
            }
            buf
        }
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
