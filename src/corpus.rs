//! `topiary-julia jl-corpus`: verified formatting over many files, one JSON line per file.
//!
//! Per file: the outcome of verified formatting (formatted / syntax_error / refused /
//! panic / timeout / read_error), the protected regions (kind, reason, line, text), and —
//! when regions were protected — what plain Topiary does with the file (fails, or succeeds
//! with an output JuliaSyntax says means the same or something else).

use std::collections::VecDeque;
use std::io::{self, BufRead, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use topiary_core::{Language, TopiaryQuery};
use topiary_julia::format::{format_verified, topiary_format, Outcome, Reason};
use topiary_julia::jlparse::{self, JlParser, Verdict};

fn esc(s: &str) -> String {
    let mut o = String::with_capacity(s.len() + 2);
    o.push('"');
    for c in s.chars() {
        match c {
            '"' => o.push_str("\\\""),
            '\\' => o.push_str("\\\\"),
            '\n' => o.push_str("\\n"),
            '\r' => o.push_str("\\r"),
            '\t' => o.push_str("\\t"),
            c if (c as u32) < 0x20 => o.push_str(&format!("\\u{:04x}", c as u32)),
            c => o.push(c),
        }
    }
    o.push('"');
    o
}

fn language() -> Language {
    let grammar: topiary_tree_sitter_facade::Language = tree_sitter_julia::LANGUAGE.into();
    let query = TopiaryQuery::new(&grammar, crate::QUERY).expect("query");
    Language { name: "julia".into(), query, grammar, indent: Some("    ".into()) }
}

fn check(path: &str, lang: &Language, jl: &mut JlParser) -> String {
    let t0 = Instant::now();
    let src = match std::fs::read(path).map(String::from_utf8) {
        Ok(Ok(s)) => s,
        Ok(Err(_)) => return format!("\"outcome\":\"not_utf8\""),
        Err(e) => return format!("\"outcome\":\"read_error\",\"error\":{}", esc(&e.to_string())),
    };
    let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| format_verified(&src, lang, jl, true)));
    let ms = t0.elapsed().as_secs_f64() * 1e3;
    let mut o = format!("\"bytes\":{},\"ms\":{:.1},", src.len(), ms);
    match r {
        Err(_) => o.push_str("\"outcome\":\"panic\""),
        Ok(Err(e)) => o.push_str(&format!("\"outcome\":\"wasm_error\",\"error\":{}", esc(&e))),
        Ok(Ok(Outcome::SyntaxErrors(d))) => {
            let first = jlparse::format_diagnostics("f", &src, &d[..1.min(d.len())]);
            o.push_str(&format!("\"outcome\":\"syntax_error\",\"error\":{}", esc(first.trim_end())));
        }
        Ok(Ok(Outcome::Refused(why))) => o.push_str(&format!("\"outcome\":\"refused\",\"error\":{}", esc(&why))),
        Ok(Ok(Outcome::Formatted { output, protected })) => {
            o.push_str(&format!("\"outcome\":\"formatted\",\"changed\":{},\"regions\":[", output != src));
            for (k, p) in protected.iter().enumerate() {
                let (l, c) = jlparse::line_col(&src, p.start);
                let text: String = src[p.start..p.end].chars().take(160).collect();
                let reason = match p.reason {
                    Reason::GrammarGap => "gap",
                    Reason::NotPreserved => "meaning",
                };
                if k > 0 {
                    o.push(',');
                }
                o.push_str(&format!(
                    "{{\"kind\":{},\"reason\":\"{reason}\",\"line\":{l},\"col\":{c},\"len\":{},\"text\":{}}}",
                    esc(&p.kind),
                    p.end - p.start,
                    esc(&text)
                ));
            }
            o.push(']');
            if !protected.is_empty() {
                // what plain Topiary would have done
                let plain = match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| topiary_format(&src, lang, true))) {
                    Err(_) => "panic".to_string(),
                    Ok(Err(e)) => format!("fails: {}", e.lines().find(|l| !l.trim().is_empty()).unwrap_or("").trim()),
                    Ok(Ok(out)) => match jl.verify(&src, &out) {
                        Ok(Verdict::Equivalent) => "equivalent".into(),
                        Ok(Verdict::Changed(d)) => format!("changes meaning: {}", d.chars().take(200).collect::<String>()),
                        Ok(Verdict::CommentsChanged(d)) => format!("changes comments: {d}"),
                        Ok(Verdict::OutputHasErrors(_)) => "output does not parse".into(),
                        Ok(Verdict::InputHasErrors(_)) => "input has errors".into(),
                        Err(e) => format!("wasm error: {e}"),
                    },
                };
                o.push_str(&format!(",\"plain\":{}", esc(&plain)));
            }
            o.push_str(&format!(",\"ms_total\":{:.1}", t0.elapsed().as_secs_f64() * 1e3));
        }
    }
    o
}

struct Slot {
    path: Option<String>,
    started: Instant,
    abandoned: Arc<AtomicBool>,
}

pub fn run(jobs: usize, timeout: u64) -> std::process::ExitCode {
    let queue: Arc<Mutex<VecDeque<String>>> = Arc::new(Mutex::new(
        io::stdin().lock().lines().map_while(Result::ok).filter(|l| !l.trim().is_empty()).collect(),
    ));
    let out = Arc::new(Mutex::new(io::stdout()));
    let slots: Arc<Mutex<Vec<Slot>>> = Arc::new(Mutex::new(vec![]));
    let spawn = |id: usize| {
        let (queue, out, slots) = (queue.clone(), out.clone(), slots.clone());
        let abandoned = Arc::new(AtomicBool::new(false));
        {
            let mut s = slots.lock().unwrap();
            let slot = Slot { path: None, started: Instant::now(), abandoned: abandoned.clone() };
            if id < s.len() {
                s[id] = slot;
            } else {
                s.push(slot);
            }
        }
        std::thread::Builder::new()
            .stack_size(64 << 20)
            .spawn(move || {
                let lang = language();
                let mut jl = JlParser::new().expect("JuliaSyntax (Wasm)");
                loop {
                    let Some(path) = queue.lock().unwrap().pop_front() else { break };
                    {
                        let mut s = slots.lock().unwrap();
                        s[id].path = Some(path.clone());
                        s[id].started = Instant::now();
                    }
                    let line = check(&path, &lang, &mut jl);
                    if abandoned.load(Ordering::SeqCst) {
                        return; // reported as a timeout already; a fresh worker took the slot
                    }
                    slots.lock().unwrap()[id].path = None;
                    let mut o = out.lock().unwrap();
                    let _ = writeln!(o, "{{\"path\":{},{line}}}", esc(&path));
                    let _ = o.flush();
                }
            })
            .expect("spawn")
    };
    let mut handles: Vec<Option<std::thread::JoinHandle<()>>> = (0..jobs).map(|i| Some(spawn(i))).collect();
    loop {
        std::thread::sleep(Duration::from_millis(500));
        let mut respawn = vec![];
        {
            let mut s = slots.lock().unwrap();
            for (id, slot) in s.iter_mut().enumerate() {
                if let Some(p) = &slot.path {
                    if slot.started.elapsed() > Duration::from_secs(timeout) {
                        slot.abandoned.store(true, Ordering::SeqCst);
                        let mut o = out.lock().unwrap();
                        let _ = writeln!(o, "{{\"path\":{},\"outcome\":\"timeout\",\"ms\":{}}}", esc(p), timeout * 1000);
                        let _ = o.flush();
                        slot.path = None;
                        respawn.push(id);
                    }
                }
            }
        }
        for id in respawn {
            handles[id] = Some(spawn(id)); // the stuck thread is left behind
        }
        let idle = queue.lock().unwrap().is_empty() && slots.lock().unwrap().iter().all(|s| s.path.is_none());
        if idle {
            break;
        }
    }
    for h in handles.iter_mut() {
        if let Some(h) = h.take() {
            if h.is_finished() {
                let _ = h.join();
            }
        }
    }
    std::process::exit(0);
}
