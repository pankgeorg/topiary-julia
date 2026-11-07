#!/usr/bin/env python3
"""Summarize jl-corpus JSONL: jlparse_corpus_summary.py results.jsonl [A.txt]"""
import json, sys, collections, re
rows = {}
for l in open(sys.argv[1]):
    try: r = json.loads(l)
    except Exception: continue
    rows[r['path']] = r          # last line wins (a timeout line, if any, comes first)
A = set(open(sys.argv[2]).read().split('\n')) if len(sys.argv) > 2 else None
def summary(sel, title):
    rs = [rows[p] for p in sel if p in rows]
    oc = collections.Counter(r['outcome'] for r in rs)
    nb = sum(r.get('bytes', 0) for r in rs)
    print(f"## {title}: {len(rs)} files, {nb/1e6:.1f} MB")
    for k, v in oc.most_common(): print(f"  {k}: {v}")
    f = [r for r in rs if r['outcome'] == 'formatted']
    withreg = [r for r in f if r['regions']]
    regs = [g for r in f for g in r['regions']]
    print(f"  formatted & verified: {len(f)}; with regions left verbatim: {len(withreg)}; regions: {len(regs)} "
          f"(gap {sum(g['reason']=='gap' for g in regs)}, meaning {sum(g['reason']=='meaning' for g in regs)})")
    whole = [r for r in withreg if any(g['len'] >= r['bytes'] - 2 or g['kind'] == 'toplevel' for g in r['regions'])]
    print(f"  files left entirely verbatim: {len(whole)}")
    plain = collections.Counter(re.sub(r':.*', '', r.get('plain', '')) for r in withreg)
    print("  plain Topiary on files with regions:", dict(plain))
    print("  regions by kind:reason:", collections.Counter(f"{g['kind']}:{g['reason']}" for g in regs).most_common(25))
    return rs
allrs = summary(list(rows), "B (everything)")
if A: summary([p for p in rows if p in A], "A (smoke corpus in full)")
f = [r for r in rows.values() if 'ms' in r]
print("\n## slowest files")
for r in sorted(f, key=lambda r: -r.get('ms_total', r['ms']))[:12]:
    print(f"  {r.get('ms_total', r['ms'])/1000:7.1f} s  {r.get('bytes',0)/1e3:7.0f} KB  {r['outcome']:10} {len(r.get('regions',[]))} regions  {r['path']}")
print("\n## refused / panic / timeout / wasm_error")
for r in rows.values():
    if r['outcome'] in ('refused', 'panic', 'timeout', 'wasm_error'):
        print(f"  {r['outcome']}: {r['path']} {r.get('error','')[:150]}")
