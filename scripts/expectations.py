#!/usr/bin/env python3
"""classify-full.log (JSON CLASSIFY lines) -> tests/corpus/jlparse_expectations.toml"""
import json, re, sys
rows = []
for line in open(sys.argv[1]):
    if line.startswith('CLASSIFY'):
        rows.append(json.loads(line.rstrip('\n').split('\t', 3)[3]))
rows.sort(key=lambda r: r['id'])
out = ['''# Expected classifications of the JuliaSyntax-verified suites (tests/jlparse_test.rs).
#
# Every JuliaSyntax-corpus snippet (`jl_line_NNNN`, line in juliasyntax_parser.jl) and every
# known grammar gap (`jl_gap_line_NNNN` from expectations.toml, `jl_gap_ts_NNNN` from
# localized_gaps.toml) is formatted with JuliaSyntax verification. Unlisted ids must be
# clean: plain Topiary's output means the same as the input, according to JuliaSyntax.
#
#   status = "protected" — plain Topiary can't format it (grammar gap) or changes its
#                          meaning; verified formatting leaves `note`'s node(s) verbatim
#                          (kind:reason) and formats the rest.
#   status = "js_error"  — JuliaSyntax rejects the snippet parsed as a file (the corpus has
#                          production-specific and intentional-error snippets); verified
#                          formatting reports JuliaSyntax's diagnostics.
#
# Regenerate: JLPARSE_CLASSIFY=1 cargo test --test jlparse_test jl_ -- --nocapture | grep ^CLASSIFY > c.log
#             python3 scripts/expectations.py c.log > tests/corpus/jlparse_expectations.toml
''']
for r in rows:
    if r['status'] == '': continue
    e = f'[[snippet]]\nid = "{r["id"]}"\nstatus = "{r["status"]}"\n'
    m = re.match(r'Protected\("(.*)"\)$', r['class'])
    if m: e += f'note = {json.dumps(m.group(1))}\n'
    out.append(e)
print('\n'.join(out))
