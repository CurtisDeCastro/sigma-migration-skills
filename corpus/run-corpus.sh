#!/usr/bin/env bash
# Regression-corpus runner. No credentials or network needed for --check.
#
#   ./run-corpus.sh --check                 validate every case (default)
#   ./run-corpus.sh --check tableau         validate one tool's cases
#   ./run-corpus.sh --reconvert [case]      print per-case converter invocation
#   ./run-corpus.sh --diff <case> --converted <file>
#                                           diff a fresh converter output
#                                           against the stored golden
set -euo pipefail
cd "$(dirname "$0")"

MODE="--check"
FILTER=""
CONVERTED=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check|--reconvert|--diff) MODE="$1" ;;
    --converted) CONVERTED="$2"; shift ;;
    *) FILTER="$1" ;;
  esac
  shift
done

cases() {
  for m in */*/MANIFEST.md; do
    c="$(dirname "$m")"
    case "$c" in
      ${FILTER:-*}*) echo "$c" ;;
    esac
  done
}

if [ "$MODE" = "--check" ]; then
  # json >= 2.8 pretty-prints empty containers as `[]` / `{}` where earlier
  # versions emitted `[\n\n]` / `{\n\n}`. Every byte-compared golden here was
  # generated with the older form, so a newer json turns each `cmp` into an
  # opaque "differ: byte N" with no hint at the cause. Warn up front instead.
  if command -v ruby >/dev/null 2>&1 &&
     [ "$(ruby -rjson -e 'print JSON.pretty_generate([]) == "[]"' 2>/dev/null)" = "true" ]; then
    echo "WARNING: ruby json $(ruby -rjson -e 'print JSON::VERSION') pretty-prints empty containers"
    echo "         compactly ([] not [<newline><newline>]); goldens were generated with the older"
    echo "         form, so JSON cmp checks will report byte-level differences. CI pins ruby 3.3"
    echo "         (.github/workflows/corpus-check.yml) — use the same locally to reproduce."
  fi

  fail=0; total=0
  for c in $(cases); do
    total=$((total + 1))
    echo "== $c"
    ok=1
    python3 lib/corpus_check.py check "$c" || ok=0
    # Executable expectations: a case may ship a checks.sh (offline,
    # creds-free — e.g. the tableau field-twin cases run the skill's ledger
    # derivations, fixture-mode probes, and gates). Needs ruby for the
    # skill-script cases; both CI runners ship it.
    if [ "$ok" -eq 1 ] && [ -f "$c/checks.sh" ]; then
      echo "   -- checks.sh"
      bash "$c/checks.sh" || ok=0
    fi
    if [ "$ok" -eq 1 ]; then
      echo "   PASS"
    else
      echo "   FAIL"
      fail=$((fail + 1))
    fi
  done
  echo
  echo "corpus: $((total - fail))/$total cases pass"
  [ "$fail" -eq 0 ]
elif [ "$MODE" = "--reconvert" ]; then
  for c in $(cases); do
    echo "== $c"
    # Print the "## Converter" section of the case MANIFEST verbatim.
    awk '/^## Converter/{f=1;next} /^## /{f=0} f' "$c/MANIFEST.md"
    g=$(ls "$c/golden" 2>/dev/null || true)
    if [ -n "$g" ]; then
      echo "Then normalize + diff the fresh output against the golden:"
      for f in $g; do
        echo "  ./run-corpus.sh --diff $c --converted <fresh-output.json>   # golden/$f"
      done
    fi
    echo
  done
  echo "MCP converter tools cannot be shelled out to directly — invoke the"
  echo "named mcp__sigma-data-model__convert_* tool from an MCP client with the"
  echo "listed input file(s), save the JSON result, then use --diff."
  echo "For payloads under ~100 KB, lib/mcp_convert.py calls the hosted server:"
  echo "  python3 lib/mcp_convert.py convert_qlik_to_sigma args.json out.json"
elif [ "$MODE" = "--diff" ]; then
  [ -n "$FILTER" ] || { echo "usage: run-corpus.sh --diff <case-dir> --converted <file>"; exit 2; }
  [ -n "$CONVERTED" ] || { echo "missing --converted <file>"; exit 2; }
  for g in "$FILTER"/golden/*.json; do
    echo "== $g vs $CONVERTED"
    python3 lib/corpus_check.py diff "$g" "$CONVERTED" && exit 0 || true
  done
  exit 1
fi
