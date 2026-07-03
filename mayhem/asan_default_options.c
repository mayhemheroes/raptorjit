/* Weak __asan_default_options baked into the raptorjit fuzz target so the Mayhemfile never needs
 * ASAN_OPTIONS (which Mayhem forbids). detect_leaks=0: RaptorJIT is a Lua VM with a tracing GC that
 * intentionally leaves its in-memory object graph live at process exit (a one-shot `raptorjit
 * prog.lua` run does not tear down the heap). In practice RaptorJIT manages the Lua heap through its
 * own mmap-based allocator (lj_alloc.c), so LeakSanitizer already sees no malloc leaks — but a build
 * configured with LUAJIT_USE_SYSMALLOC, or any future change routing allocations through malloc,
 * would otherwise drown real ASan findings in by-design "leaks" on every run. The function is weak so
 * a build that sets ASAN_OPTIONS explicitly can still override it. */
const char *__asan_default_options(void) {
  return "detect_leaks=0";
}
