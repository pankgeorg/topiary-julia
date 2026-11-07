#!/usr/bin/env bash
# jlparse_corpus_run.sh <binary> <list> <out.jsonl> — resumable: files already in out.jsonl are skipped.
set -u
B=$1; LIST=$2; OUT=$3
touch "$OUT"
TODO=$(mktemp)
python3 - "$LIST" "$OUT" > "$TODO" <<'PY'
import json, sys
done = set()
for l in open(sys.argv[2]):
    try: done.add(json.loads(l)['path'])
    except Exception: pass
for p in open(sys.argv[1]).read().split('\n'):
    if p and p not in done: print(p)
PY
echo "todo: $(wc -l < "$TODO") files"
split -l 2000 -d "$TODO" "$TODO.chunk."
for c in "$TODO".chunk.*; do
  timeout 7200 nice -n 19 "$B" jl-corpus --jobs 4 --timeout 60 < "$c" >> "$OUT" 2>> "$OUT.stderr"
  echo "$(date +%T) chunk $(basename $c) done; $(wc -l < "$OUT") results"
done
rm -f "$TODO" "$TODO".chunk.*
