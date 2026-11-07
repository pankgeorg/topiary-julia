#!/usr/bin/env bash
# Format every Base/*.jl file with the release binary, verified vs --no-verify; one line each.
# usage: jlparse_realworld.sh <binary> <files...>
B=$1; shift
ERRF=${ERRF:-$(mktemp)}
for f in "$@"; do
  s=$(date +%s%N)
  timeout 120 "$B" --skip-idempotence "$f" > /dev/null 2> $ERRF; rc=$?
  e=$(( ($(date +%s%N) - s) / 1000000 ))
  s=$(date +%s%N)
  timeout 120 "$B" --skip-idempotence --no-verify "$f" > /dev/null 2>/dev/null; rc2=$?
  e2=$(( ($(date +%s%N) - s) / 1000000 ))
  notes=$(grep -c '^note:' $ERRF)
  gaps=$(grep -c "can't parse" $ERRF)
  first=$(grep -v '^note:' $ERRF | head -1 | cut -c1-120)
  printf '%s\t%d\t%d\t%d\t%d\t%d\t%d\t%s\n' "$(basename $f)" $(stat -c %s "$f") $rc $e $rc2 $e2 $notes "$gaps|$first"
done
