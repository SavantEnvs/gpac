/*
 * mayhem/lsan_off.c — disable ONLY LeakSanitizer, at build time (SPEC 6.2 item 15).
 *
 * -fsanitize=address always bundles LSan; leaks are not the defect class this fleet fuzzes for.
 * Defining this hook makes the LSan runtime skip its exit-time leak check. ASan and UBSan stay
 * fully active. Compiled with $SANITIZER_FLAGS and linked into every fuzz and -standalone binary
 * by mayhem/build.sh. It sets no runtime options — Mayhem alone owns ASAN_OPTIONS.
 */
int __lsan_is_turned_off(void) { return 1; }
