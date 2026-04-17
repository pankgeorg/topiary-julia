//! Runic Comparison Test
//!
//! Compares topiary-julia's formatting output against Runic.jl's output
//! for a corpus of test snippets. This helps identify formatting rule
//! differences and track compatibility.
//!
//! Run: cargo test --test runic_comparison_test -- --nocapture

mod common;

const RUNIC_CORPUS: &str = include_str!("corpus/runic_comparison.txt");

/// Parse the comparison corpus into (category, input, runic_output) triples.
fn parse_corpus(corpus: &str) -> Vec<(&str, &str, &str)> {
    let mut results = Vec::new();
    let sections: Vec<&str> = corpus.split("=====\n").collect();

    for section in &sections {
        let section = section.trim();
        if section.is_empty() {
            continue;
        }

        // Parse category
        let Some(rest) = section.strip_prefix("category: ") else {
            continue;
        };
        let Some(newline_pos) = rest.find('\n') else {
            continue;
        };
        let category = &rest[..newline_pos];
        let rest = &rest[newline_pos + 1..];

        // Parse input
        let Some(rest) = rest.strip_prefix("---input---\n") else {
            continue;
        };
        let Some(runic_marker) = rest.find("---runic---\n") else {
            continue;
        };
        let input = rest[..runic_marker].trim_end_matches('\n');
        let runic_output = rest[runic_marker + "---runic---\n".len()..].trim_end_matches('\n');

        results.push((category, input, runic_output));
    }
    results
}

#[test]
fn runic_comparison() {
    let pairs = parse_corpus(RUNIC_CORPUS);
    assert!(
        pairs.len() > 200,
        "Parsing may be broken: got {} pairs",
        pairs.len()
    );

    let mut total = 0;
    let mut matches = 0;
    let mut mismatches: Vec<(&str, &str, &str, String)> = Vec::new(); // (cat, input, runic, ours)
    let mut errors: Vec<(&str, &str, String)> = Vec::new(); // (cat, input, error)

    // Category-level stats
    let mut cat_total: std::collections::BTreeMap<&str, usize> = std::collections::BTreeMap::new();
    let mut cat_match: std::collections::BTreeMap<&str, usize> = std::collections::BTreeMap::new();

    for (category, input, runic_output) in &pairs {
        total += 1;
        *cat_total.entry(category).or_insert(0) += 1;

        match common::format_julia_tolerant(input) {
            Ok(our_output) => {
                // Trim trailing newline for comparison — Topiary always adds one
                let ours = our_output.trim_end_matches('\n');
                let runic = runic_output.trim_end_matches('\n');

                if ours == runic {
                    matches += 1;
                    *cat_match.entry(category).or_insert(0) += 1;
                } else {
                    mismatches.push((category, input, runic_output, our_output));
                }
            }
            Err(e) => {
                errors.push((category, input, e));
            }
        }
    }

    // ── Report ──────────────────────────────────────────────────
    eprintln!("\n=== Runic Comparison Results ===");
    eprintln!("Total pairs:   {total}");
    eprintln!("Matches:       {matches} ({:.1}%)", matches as f64 / total as f64 * 100.0);
    eprintln!("Mismatches:    {}", mismatches.len());
    eprintln!("Errors:        {}", errors.len());

    eprintln!("\n--- Category breakdown ---");
    for (cat, &t) in &cat_total {
        let m = cat_match.get(cat).copied().unwrap_or(0);
        let pct = if t > 0 {
            m as f64 / t as f64 * 100.0
        } else {
            0.0
        };
        let status = if m == t { "  OK" } else { "DIFF" };
        eprintln!("  {status} {cat:25} {m:3}/{t:3} ({pct:.0}%)");
    }

    if !errors.is_empty() {
        eprintln!("\n--- Formatter errors ---");
        for (cat, input, err) in &errors {
            eprintln!("  [{cat}] {input:?} => ERROR: {err}");
        }
    }

    // Group mismatches by category for readability
    if !mismatches.is_empty() {
        eprintln!("\n--- Mismatches (grouped by category) ---");
        let mut current_cat = "";
        for (cat, input, runic, ours) in &mismatches {
            if *cat != current_cat {
                eprintln!("\n  [{cat}]");
                current_cat = cat;
            }
            // Show compact diff
            let input_repr = if input.contains('\n') {
                format!("{}...", &input[..input.find('\n').unwrap_or(40).min(40)])
            } else {
                format!("{input:?}")
            };
            let runic_trimmed = runic.trim_end_matches('\n');
            let ours_trimmed = ours.trim_end_matches('\n');
            if !runic_trimmed.contains('\n') && !ours_trimmed.contains('\n') {
                eprintln!("    {input_repr}");
                eprintln!("      runic: {runic_trimmed:?}");
                eprintln!("      ours:  {ours_trimmed:?}");
            } else {
                eprintln!("    {input_repr}");
                eprintln!("      runic:");
                for line in runic_trimmed.lines() {
                    eprintln!("        | {line}");
                }
                eprintln!("      ours:");
                for line in ours_trimmed.lines() {
                    eprintln!("        | {line}");
                }
            }
        }
    }

    // Don't assert — this is informational. But do warn if match rate drops.
    eprintln!(
        "\n=== Match rate: {matches}/{total} ({:.1}%) ===\n",
        matches as f64 / total as f64 * 100.0
    );
}
