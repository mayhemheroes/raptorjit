#!/usr/bin/env bash
# raptorjit/mayhem/test.sh — GOLDEN / known-answer oracle for the RaptorJIT Lua VM.
#
# RaptorJIT ships a testsuite/ directory, but its own README states it has "no steps to build it
# or run it", no portable test runner, and is "not in the best state" — it is an unmaintained
# collection meant to one day merge upstream, with no self-contained, deterministic harness in the
# image. So instead we author a small KNOWN-ANSWER suite of deterministic Lua programs (no input,
# no rand/time) and diff each program's output against a committed golden:
#
#   * mayhem/build.sh built /mayhem/raptorjit-tests with the project's NORMAL flags (NO sanitizer),
#     so the oracle exercises the real shipped VM behavior and never false-fails on the benign UB
#     the fuzz build deliberately relaxes. This script only RUNS that binary — it never compiles
#     (PATCH grading: patch -> build.sh -> test.sh).
#   * For each program (mayhem/testdata/prog/<name>.lua) it runs the VM and DIFFs stdout+stderr
#     against the committed golden (mayhem/testdata/golden/<name>.out). The goldens were captured
#     once from the normal-flags binary and verified byte-stable across repeated runs.
#
# This is a PATCH-grade, anti-reward-hack oracle by construction: it asserts the EXACT computed
# OUTPUT of each program (arithmetic results, a JIT-compiled loop sum, a fibonacci sequence, table
# sums, string-library results), not merely "exited 0". A no-op / exit(0) "patch", or any change
# that breaks the lexer/parser/JIT/runtime so a program stops producing its correct output, FAILS
# the diff. The programs deliberately drive hot loops so the JIT trace compiler is exercised too.
set -uo pipefail

# clang/gcc reject SOURCE_DATE_EPOCH='' (empty); must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"

# SRC is /mayhem in the commit image; default to this checkout's repo root so the suite also runs
# straight from a developer checkout (mayhem/ is one level below the repo root).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${SRC:=$(cd "$HERE/.." && pwd)}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# The normal-flags oracle binary that build.sh produced.
BIN="$SRC/raptorjit-tests"
[ -x "$BIN" ] || { echo "missing $BIN — run mayhem/build.sh first" >&2; emit_ctrf "raptorjit-golden" 0 1; exit 2; }

PROG="$SRC/mayhem/testdata/prog"
GOLDEN="$SRC/mayhem/testdata/golden"
[ -d "$GOLDEN" ] || { echo "missing golden dir $GOLDEN — wrong tree?" >&2; emit_ctrf "raptorjit-golden" 0 1; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

passed=0; failed=0

# run_case <name>: runs $BIN on prog/<name>.lua, diffs combined stdout+stderr against
# golden/<name>.out. MUST exit 0 AND match the golden byte-for-byte.
run_case() {
  local name="$1"
  local prog="$PROG/$name.lua" gold="$GOLDEN/$name.out" got="$WORK/$name.out" rc
  if [ ! -f "$prog" ]; then echo "FAIL $name: missing program $prog" >&2; failed=$((failed+1)); return; fi
  if [ ! -f "$gold" ]; then echo "FAIL $name: missing golden $gold" >&2; failed=$((failed+1)); return; fi
  "$BIN" "$prog" > "$got" 2>&1; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL $name: raptorjit $name.lua exited $rc (expected 0)" >&2
    sed 's/^/    /' "$got" >&2
    failed=$((failed+1)); return
  fi
  if diff -u "$gold" "$got" > "$WORK/$name.diff" 2>&1; then
    echo "PASS $name"; passed=$((passed+1))
  else
    echo "FAIL $name: output differs from golden" >&2
    head -20 "$WORK/$name.diff" | sed 's/^/    /' >&2
    failed=$((failed+1))
  fi
}

# Each program exercises a different VM path; the loop/table/fib programs run hot enough to trigger
# JIT trace compilation, so the oracle covers the interpreter AND the compiler.
run_case arith    # arithmetic, precedence, math library
run_case loop     # numeric for-loop sum (JIT trace) + power loop
run_case table    # table build/index/length/sum (JIT array path) + hash fields
run_case fib      # recursive function calls -> fibonacci sequence
run_case string   # string library: upper/rep/format/sub/length/gsub

emit_ctrf "raptorjit-golden" "$passed" "$failed"
