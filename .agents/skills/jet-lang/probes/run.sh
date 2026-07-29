#!/usr/bin/env bash
# Check every factual claim SKILL.md makes against the compiler that is actually installed.
#
# A language reference for an agent rots silently: the language moves, the prose doesn't, and
# the skill then teaches wrong syntax with total confidence -- which is worse than shipping no
# skill at all. Jet is unusually well placed to prevent that, because compiling IS the
# assertion. Every claim in SKILL.md has a probe here, so when a claim stops being true this
# script says which one.
#
# Four kinds of claim, one directory each:
#   compile_fail/  this must NOT compile          (the trap)
#   compile_ok/    this must compile              (guards against cargo-culting a FIXED trap)
#   value/         this must print <name>.expected (the silent traps -- compiling can't catch them)
#   run_fail/      this compiles but must fail at run time
#
# Usage:  ./run.sh [path-to-jet-binary]      (default: the repo root's ./jet)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
JET="${1:-$(cd "$HERE/../../../.." && pwd)/jet}"
[ -x "$JET" ] || { echo "no jet binary at $JET — build it first (see the repo README)"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

report() { # ok|no, name, detail
  if [ "$1" = ok ]; then pass=$((pass+1)); printf '  ok    %s\n' "$2"
  else fail=$((fail+1)); printf '  FAIL  %s\n        %s\n' "$2" "$3"; fi
}

# Compile in a scratch copy so the probes never leave .beam files in the repo.
compile() { cp "$1" "$WORK/" && "$JET" "$WORK/$(basename "$1")" 2>&1; }

echo "jet-lang probes  (jet: $JET)"

echo "must NOT compile:"
for f in "$HERE"/compile_fail/*.jet; do
  n="$(basename "$f" .jet)"
  if out="$(compile "$f")"; then
    report no "$n" "it COMPILED — the trap is gone, so remove the claim from SKILL.md"
  else
    report ok "$n"
  fi
done

echo "must compile:"
for f in "$HERE"/compile_ok/*.jet; do
  n="$(basename "$f" .jet)"
  if out="$(compile "$f")"; then
    report ok "$n"
  else
    report no "$n" "$(printf '%s' "$out" | head -1)"
  fi
done

echo "must print its .expected:"
for f in "$HERE"/value/*.jet; do
  n="$(basename "$f" .jet)"
  exp="$HERE/value/$n.expected"
  [ -f "$exp" ] || { report no "$n" "no $n.expected next to it"; continue; }
  cp "$f" "$WORK/"
  got="$("$JET" -r "$n::run" "$WORK/$n.jet" 2>/dev/null)"
  if [ "$got" = "$(cat "$exp")" ]; then
    report ok "$n"
  else
    report no "$n" "expected [$(tr '\n' '|' < "$exp")] got [$(printf '%s' "$got" | tr '\n' '|')]"
  fi
done

echo "must compile but fail at run time:"
for f in "$HERE"/run_fail/*.jet; do
  n="$(basename "$f" .jet)"
  cp "$f" "$WORK/"
  if ! "$JET" "$WORK/$n.jet" >/dev/null 2>&1; then
    report no "$n" "it did not even compile — the claim is about a RUN-time failure"
  elif "$JET" -r "$n::run" "$WORK/$n.jet" >/dev/null 2>&1; then
    report no "$n" "it ran fine — the trap is gone, so remove the claim from SKILL.md"
  else
    report ok "$n"
  fi
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || { echo "SKILL.md now contains at least one false claim — fix the prose, not the probe."; exit 1; }
