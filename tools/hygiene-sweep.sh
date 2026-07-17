#!/usr/bin/env bash
# tools/hygiene-sweep.sh — mechanical hygiene sweep: NO test-org or customer
# identifiers (connections, workbooks, customers, datasources, field/value
# literals, object ids) may appear in tracked files or in the staged diff.
#
#   bash tools/hygiene-sweep.sh          # exit 0 clean, exit 1 with named hits
#
# Run this before EVERY commit, alongside tools/check-shared.rb (both are wired
# into .githooks/run-governance-checks.sh). Patterns live in
# tools/hygiene-patterns.txt — one case-insensitive extended regex per line,
# '#' lines are comments. When a new test-specific identifier enters the
# vocabulary (a new field org, workbook, warehouse, or customer transcript),
# add its STABLE identifier there first, then write code/docs against the
# neutral replacement.
set -uo pipefail

root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "hygiene-sweep: not a git repo" >&2; exit 2; }
cd "$root" || exit 2

patfile="tools/hygiene-patterns.txt"
[ -f "$patfile" ] || { echo "hygiene-sweep: $patfile missing" >&2; exit 2; }

# Strip comments/blank lines into a temp pattern file.
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
grep -vE '^\s*(#|$)' "$patfile" > "$tmp"
# Private third-party guards (gitignored) — loaded when present.
[ -f "tools/hygiene-patterns.local.txt" ] && grep -vE '^\s*(#|$)' "tools/hygiene-patterns.local.txt" >> "$tmp"
if ! [ -s "$tmp" ]; then
  echo "hygiene-sweep: no active patterns in $patfile" >&2
  exit 2
fi

fail=0

# 1) Every tracked file (the pattern file and this script legitimately contain
#    the patterns themselves — exclude them). Binary files are skipped (-I).
hits="$(git ls-files -z \
  | grep -zv -e '^tools/hygiene-patterns.txt$' -e '^tools/hygiene-sweep.sh$' \
  | xargs -0 grep -nIiE -f "$tmp" -- 2>/dev/null)"
if [ -n "$hits" ]; then
  echo "HYGIENE SWEEP FAILED — test-org identifiers in tracked files:" >&2
  printf '%s\n' "$hits" | head -100 >&2
  n="$(printf '%s\n' "$hits" | wc -l | tr -d ' ')"
  [ "$n" -gt 100 ] && echo "  … and $((n - 100)) more hit(s)" >&2
  fail=1
fi

# 2) The staged diff (catches leaks in files not yet tracked at HEAD, and in
#    hunks about to be committed).
staged="$(git diff --cached -U0 -- . ':(exclude)tools/hygiene-patterns.txt' ':(exclude)tools/hygiene-sweep.sh' \
  | grep -E '^\+' | grep -viE '^\+\+\+' | grep -niIE -f "$tmp" 2>/dev/null)"
if [ -n "$staged" ]; then
  echo "HYGIENE SWEEP FAILED — test-org identifiers in the STAGED diff:" >&2
  printf '%s\n' "$staged" | head -50 >&2
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "hygiene-sweep: clean ($(grep -c . "$tmp") pattern(s) over $(git ls-files | wc -l | tr -d ' ') tracked files + staged diff)."
fi
exit "$fail"
