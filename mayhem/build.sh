#!/usr/bin/env bash
# raptorjit/mayhem/build.sh — build the RaptorJIT VM as the fuzz target.
#
# RaptorJIT is a LuaJIT fork: a tracing-JIT Lua VM written in C under src/. The CLI binary
# `src/raptorjit` reads a Lua SOURCE file (or precompiled bytecode) given as a path argument,
# then LEXES (lj_lex.c), PARSES (lj_parse.c), and EXECUTES it — and, for hot loops, JIT-compiles
# bytecode to native machine code (the trace recorder + x86 assembler). It also accepts compiled
# bytecode chunks via the bytecode loader (lj_bcread.c). The Mayhem target is FILE-INPUT (CLI):
# the fuzz bytes are handed to /mayhem/raptorjit as the program file, exercising the whole
# lexer + parser + bytecode-reader + VM pipeline. There is NO libFuzzer harness — the VM binary
# IS the natural fuzz surface (exactly like the lacc / my_basic / LISP file-input integrations), so
# there is no *-standalone reproducer either: the file-input target already crashes on one input.
#
# build.sh produces TWO binaries:
#   (1) src/raptorjit (copied to /mayhem/raptorjit) — SANITIZED fuzz target (ASan halting; UBSan
#       halting except four benign, by-design LuaJIT checks; see the relax note below).
#   (2) /mayhem/raptorjit-tests — NORMAL-flags oracle binary for mayhem/test.sh's golden suite (no
#       sanitizers, real shipped behavior, never false-fails on the relaxed benign UB).
#
# ---------------------------------------------------------------------------------------------
# BUILD MECHANICS (LuaJIT 2-stage build, made host-luajit-free and deterministic):
#   RaptorJIT's normal bootstrap runs DynASM (dynasm/dynasm.lua) under a HOST Lua (the Makefile
#   defaults HOST_LUA=luajit) to generate the VM assembly + a `host/buildvm` codegen tool. The
#   base image ships no luajit, and pulling one in would be an un-pinned, non-reproducible host
#   dependency. RaptorJIT ships a checked-in REFERENCE VM under src/reusevm/ (host/buildvm_arch.h,
#   lj_vm.S, and the generated lj_*def.h headers) for exactly this case: `make -C src reusevm`
#   copies it into place, so `host/buildvm` builds natively from C with NO DynASM/luajit needed,
#   and the rest of the VM compiles normally. Fully self-contained and deterministic.
#
# HOST vs TARGET flag separation (critical): only the TARGET VM must be instrumented — the HOST
# codegen tool (host/buildvm) must stay CLEAN. The Makefile keeps these separate: TARGET_CFLAGS /
# TARGET_LDFLAGS feed only the VM, while a global CFLAGS/HOST_CFLAGS also reaches host/buildvm.
# So $SANITIZER_FLAGS goes in TARGET_CFLAGS/TARGET_LDFLAGS, NOT global CFLAGS — otherwise the
# sanitized host/buildvm aborts (DynASM's dasm_x86.h trips a UBSan pointer-overflow) before it can
# emit the VM. The only global CFLAGS we add is -Wno-implicit-function-declaration (clang 19 makes
# the implicit decl of __clear_cache in lj_mcode.c a hard error; gcc — what upstream uses — warns;
# harmless on the host too).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs from the base ENV, overridable. SANITIZER_FLAGS uses `=` (not `:=`) so an explicit
# empty value (--build-arg SANITIZER_FLAGS=) is honored → no-sanitizer build (the VM's natural
# crash / full backtrace). The VM links only -lm/-ldl (added by the Makefile), present without the
# sanitizer runtime, so the empty-sanitizer build links cleanly.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC MAYHEM_JOBS

cd "$SRC"

# ---------------------------------------------------------------------------
# Benign-UB relaxation (PORTING.md "benign UB that floods under halting UBSan").
# RaptorJIT/LuaJIT, by design, trips a handful of ubiquitous UBSan checks on essentially EVERY
# program — they fire during normal lexing/parsing and JIT codegen, BEFORE any real defect can be
# reached, so halting UBSan aborts the VM on the default seed and every valid program. They are
# intrinsic to LuaJIT's design, not defects, and were smoke-tested across arithmetic, JIT-compiled
# loops, recursion, tables and string ops — each fires on valid input:
#   * shift            — signed left-shift overflow in the bit-packing of bytecode words and the
#                        string buffer (lj_buf.c, lj_bcread.c). LuaJIT packs fields into int words.
#   * alignment        — the JIT machine-code assembler (lj_asm*.h, lj_emit_x86.h) writes 16/32-bit
#                        operands at unaligned offsets into the mcode buffer; the parser/GC read
#                        tagged GCobj pointers whose low bits encode tags (lj_parse.c). x86 tolerates
#                        the unaligned access — it's the whole point of the design.
#   * function         — the GC frees objects through a dispatch table of `void(*)(g, GCobj*)`
#                        pointers whose real signatures differ per type (lj_gc.c:399). A standard
#                        LuaJIT idiom; UBSan's strict function-type check flags every collection.
#   * pointer-overflow — "applying zero offset to null pointer" in the parser (lj_parse.c) — NULL
#                        used as a base for pointer arithmetic on empty collections.
# We relax ONLY these four checks, and ONLY when UBSan is active (the no-sanitizer off-switch stays
# a clean build). ASan stays FULLY ON and HALTING — it catches the real attack surface here
# (heap/stack overflow, use-after-free in the lexer / parser / bytecode reader on malformed input),
# which is what the file-input fuzz target is exploring. Smoke-tested: every golden program runs to
# exit 0 with no sanitizer output after the relaxation.
UBSAN_RELAX=""
if printf '%s' "$SANITIZER_FLAGS" | grep -q undefined; then
  UBSAN_RELAX="-fno-sanitize=shift,alignment,function,pointer-overflow"
fi

# clang 19 makes the implicit decl of __clear_cache (lj_mcode.c) a hard error; suppress as a warning
# (upstream builds with gcc, which warns). Goes in the GLOBAL CFLAGS so both host + target tolerate it.
GLOBAL_CFLAGS="-Wno-implicit-function-declaration"

# Weak __asan_default_options (detect_leaks=0) baked into the fuzz target so no ASAN_OPTIONS is ever
# needed in a Mayhemfile (Mayhem forbids it). Compiled with the sanitizer flags and linked into the
# fuzz binary via TARGET_LDFLAGS (additive — no upstream Makefile edit). See asan_default_options.c.
ASAN_OPTS_OBJ=/tmp/raptorjit_asan_default_options.o
if printf '%s' "$SANITIZER_FLAGS" | grep -q address; then
  $CC $SANITIZER_FLAGS $UBSAN_RELAX $DEBUG_FLAGS -c "$SRC/mayhem/asan_default_options.c" -o "$ASAN_OPTS_OBJ"
  ASAN_OPTS_LINK="$ASAN_OPTS_OBJ"
else
  ASAN_OPTS_LINK=""
fi

# Copy the checked-in reference VM so the bootstrap needs no host luajit/DynASM (see header).
make -C src reusevm

# ---------------------------------------------------------------------------
# (1) FUZZ build — the VM compiled WITH $SANITIZER_FLAGS (+ the benign-UB relax) so the fuzzed code
#     (lexer, parser, bytecode reader, JIT, runtime) is instrumented. Sanitizers go in TARGET_* ONLY
#     so host/buildvm stays clean. Fresh tree first (reusevm just refreshed generated files).
# ---------------------------------------------------------------------------
SAN_TARGET="$SANITIZER_FLAGS $UBSAN_RELAX $DEBUG_FLAGS"
make -C src -j"$MAYHEM_JOBS" \
  CC="$CC" HOST_CC="$CC" \
  CFLAGS="$GLOBAL_CFLAGS" \
  TARGET_CFLAGS="$SAN_TARGET" \
  TARGET_LDFLAGS="$SAN_TARGET $ASAN_OPTS_LINK"
cp src/raptorjit /mayhem/raptorjit

# ---------------------------------------------------------------------------
# (2) TEST-ORACLE build — the SAME VM with NORMAL flags (no sanitizer) for mayhem/test.sh's golden
#     suite. A clean, independent build so the oracle reflects real shipped behavior; test.sh only
#     RUNS this binary (it never compiles). make clean first so we relink without sanitizers.
# ---------------------------------------------------------------------------
make -C src clean >/dev/null 2>&1 || true
make -C src reusevm
make -C src -j"$MAYHEM_JOBS" CC="$CC" HOST_CC="$CC" CFLAGS="$GLOBAL_CFLAGS"
cp src/raptorjit /mayhem/raptorjit-tests
# Restore the sanitized fuzz target as the canonical /mayhem/raptorjit (the Mayhemfile target).
make -C src clean >/dev/null 2>&1 || true
make -C src reusevm
make -C src -j"$MAYHEM_JOBS" \
  CC="$CC" HOST_CC="$CC" \
  CFLAGS="$GLOBAL_CFLAGS" \
  TARGET_CFLAGS="$SAN_TARGET" \
  TARGET_LDFLAGS="$SAN_TARGET $ASAN_OPTS_LINK"
cp src/raptorjit /mayhem/raptorjit

echo "build.sh: built /mayhem/raptorjit (sanitized fuzz target) and /mayhem/raptorjit-tests (test oracle)"
ls -l /mayhem/raptorjit /mayhem/raptorjit-tests
