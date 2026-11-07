#!/usr/bin/env python3
# usage: python3 scripts/jlparse_corpus_lists.py <topiary-julia dir> <out dir>  (writes A.txt, B.txt)
"""Build the corpus file lists (read-only walk), deduplicated by content (sha256).
A = the smoke-test corpus in full (corpus/Manifest.toml packages: src/ + ext/, plus Julia's
    share/julia/{base,test}; Julia 1.11.9 stands in for the original 1.11.6).
B = A + Julia 1.13.2 share/julia/{base,stdlib,test} + every .jl under ~/.julia/packages and
    ~/dyad-fleet/*/depot/packages."""
import hashlib, os, sys, tomllib, glob, json
H = os.path.expanduser('~')
repo, out = sys.argv[1], sys.argv[2]
seen = {}            # sha -> first path
tags = {}            # path -> set of tags
def add(path, tag):
    try:
        if os.path.islink(path) or not os.path.isfile(path): return
        if os.path.getsize(path) > 4_000_000: return
        h = hashlib.sha256(open(path, 'rb').read()).hexdigest()
    except OSError:
        return
    p = seen.setdefault(h, path)
    tags.setdefault(p, set()).add(tag)
def walk(root, tag, subdirs=None):
    roots = [os.path.join(root, s) for s in subdirs] if subdirs else [root]
    for r in roots:
        for d, dirs, files in os.walk(r):
            dirs[:] = [x for x in dirs if not x.startswith('.')]
            for f in files:
                if f.endswith('.jl'): add(os.path.join(d, f), tag)
# A
m = tomllib.load(open(os.path.join(repo, 'corpus/Manifest.toml'), 'rb'))
pk = f'{H}/.julia/packages'
pkg_roots = [pk] + sorted(glob.glob(f'{H}/dyad-fleet/*/depot/packages'))
def has_jl(d):
    for _, _, fs in os.walk(os.path.join(d, 'src')):
        if any(f.endswith('.jl') for f in fs): return True
    return False
npk = 0; missing = []
for name, ents in m['deps'].items():
    if 'git-tree-sha1' not in ents[0]: continue
    cands = []
    for root in pkg_roots:   # any version, from the shared depot or an agent's depot
        d = os.path.join(root, name)
        if os.path.isdir(d):
            cands += [os.path.join(d, s) for s in os.listdir(d) if has_jl(os.path.join(d, s))]
    if not cands:
        missing.append(name); continue
    npk += 1
    walk(max(cands, key=os.path.getmtime), 'A', ['src', 'ext'])
open(os.path.join(out, 'A-missing-packages.txt'), 'w').write('\n'.join(sorted(missing)) + '\n')
j111 = f'{H}/.julia/juliaup/julia-1.11.9+0.aarch64.linux.gnu/share/julia'
walk(j111, 'A', ['base', 'test'])
# B
j113 = f'{H}/solverlink/julia/julia-1.13.2/share/julia'
walk(j113, 'B', ['base', 'stdlib', 'test'])
walk(pk, 'B')
for dp in sorted(glob.glob(f'{H}/dyad-fleet/*/depot/packages')):
    walk(dp, 'B')
A = sorted(p for p, t in tags.items() if 'A' in t)
B = sorted(tags)
open(os.path.join(out, 'A.txt'), 'w').write('\n'.join(A) + '\n')
open(os.path.join(out, 'B.txt'), 'w').write('\n'.join(B) + '\n')
print(f'A: {len(A)} unique files ({npk} manifest packages found + Julia 1.11.9 base/test); '
      f'B: {len(B)} unique files, {sum(os.path.getsize(p) for p in B)/1e6:.0f} MB')
