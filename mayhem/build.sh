#!/usr/bin/env bash
#
# mayhem/build.sh — build gpac's five OSS-Fuzz harnesses (fuzz_parse, fuzz_m2ts_probe,
# fuzz_probe_analyze, fuzz_route, fuzz_scene) plus the unit-test oracle that mayhem/test.sh runs.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image exports the
# build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (linked into the libFuzzer harness)
#   SANITIZER_FLAGS     ASan + UBSan, both HALTing (-fno-sanitize-recover)
#   STANDALONE_FUZZ_MAIN  LLVM run-once driver (non-fuzzer reproducer main)
#   SRC                 /mayhem (the repo source)
#
# This script is also what rlenv's patch grader re-runs (clean tree, offline, inside a fixed build
# window), so it builds exactly what the Mayhemfiles + test.sh need, once each, in parallel:
#
#   1) the LEAN, SANITIZED libgpac (--static-build --isomedia-only) -> fuzz_parse[-standalone];
#   2) the FULL-feature, SANITIZED libgpac (plain --static-build, OSS-Fuzz's feature set) -> the other
#      four harnesses (fuzz_m2ts_probe, fuzz_probe_analyze, fuzz_route, fuzz_scene), which need the
#      MPEG-2 TS demux, the filter session and the BIFS/LASeR decoders that --isomedia-only drops.
#      Their links are independent, so they run concurrently;
#   3) the TEST ORACLE: gpac's in-tree assertion-based unit framework, a separate NORMAL-flags build
#      (`./configure --unittests` + `make unit_tests`), runner at unittests/build/bin/gcc/unittests.
#      `make unit_tests` compiles its OWN libgpac under unittests/build (config.h rewritten to export
#      every symbol) and links the runner against that — so no top-level `make lib` is needed for it
#      (it used to be built and then never used), and the sub-make inherits -j through make's jobserver
#      (it used to run serially: 395 -O3 files on one core).
#
# Every library is rebuilt from the (patched) tree on every run; nothing of the project's own is
# cached. The builds share bin/gcc + config.mak, so they run one after another with `make distclean`
# in between; the sanitized fuzz binaries link libgpac STATICALLY, so the distcleans don't touch them.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs from the ENVIRONMENT (overridable), with sane defaults — no if-plumbing.
# SANITIZER_FLAGS uses `=` (not `:=`) so an explicit empty value (--build-arg SANITIZER_FLAGS=)
# is honored and builds with NO sanitizers (natural crash, no ASan report).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

INCS="-I$SRC/include -I$SRC"
DEFS="-DGPAC_HAVE_CONFIG_H"

# lsan_off.c: fleet build-time hook that turns off ONLY LeakSanitizer (SPEC 6.2 item 15). Compiled with
# $SANITIZER_FLAGS and linked into every fuzz and -standalone binary; ASan + UBSan stay fully on and no
# runtime options are set (Mayhem owns ASAN_OPTIONS).
LSAN_OFF_OBJ="$SRC/mayhem/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.c" -o "$LSAN_OFF_OBJ"

# link_harness <name> <link libs...>: libFuzzer binary + standalone (non-fuzzer) reproducer.
link_harness() {
    local name="$1"; shift
    local harness="$SRC/mayhem/$name.c"
    [ -f "$harness" ] || { echo "ERROR: harness $harness missing" >&2; return 1; }
    # libFuzzer harness (the Mayhem fuzzing binary).
    $CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE $DEFS \
        "$harness" "$LSAN_OFF_OBJ" $INCS "$@" \
        -o "/mayhem/$name"
    # Standalone reproducer: run-once driver, no libFuzzer runtime. C harnesses, so the C driver links
    # directly. Respects $SANITIZER_FLAGS (empty -> clean repro).
    $CC $SANITIZER_FLAGS $DEBUG_FLAGS $DEFS \
        "$STANDALONE_FUZZ_MAIN" "$harness" "$LSAN_OFF_OBJ" $INCS "$@" \
        -o "/mayhem/$name-standalone"
    echo "built: /mayhem/$name (libFuzzer), /mayhem/$name-standalone (reproducer)"
}

# Sanitizer flags flow into the PROJECT compile via --extra-cflags/--extra-ldflags so the fuzzed code
# is instrumented; -fsanitize=fuzzer-no-link adds libFuzzer coverage to the project objects.
# --static-build: libgpac as a static .a (NOT --static-bin, which adds -static to every link and the
# ASan runtime cannot link fully static). --disable-dvb4linux: the in_dvb4linux input module is
# auto-enabled when the kernel DVB headers are present (they are in the base image) but is irrelevant
# to every harness, so drop it.
FUZZ_FLAGS=(--extra-cflags="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link"
            --extra-ldflags="$SANITIZER_FLAGS $DEBUG_FLAGS")

# 1) LEAN sanitized libgpac (--isomedia-only keeps exactly the MP4/ISOBMFF parse path) -> fuzz_parse.
#    zlib is the only external lib --isomedia-only leaves linked in libgpac.
./configure --static-build --isomedia-only --disable-dvb4linux "${FUZZ_FLAGS[@]}"
make -j"$MAYHEM_JOBS" lib
[ -f "$SRC/bin/gcc/libgpac_static.a" ] || { echo "ERROR: lean libgpac_static.a not built" >&2; exit 1; }
link_harness fuzz_parse "$SRC/bin/gcc/libgpac_static.a" -lz -lm -lpthread

# 2) FULL-feature sanitized libgpac -> the other four harnesses. The full build pulls in TLS-using code
#    (DASH/HTTP/route), so link openssl too — matches OSS-Fuzz (-lssl -lcrypto).
make distclean >/dev/null 2>&1 || true
./configure --static-build --disable-dvb4linux "${FUZZ_FLAGS[@]}"
make -j"$MAYHEM_JOBS" lib
[ -f "$SRC/bin/gcc/libgpac_static.a" ] || { echo "ERROR: full-feature libgpac_static.a not built" >&2; exit 1; }
pids=()
for name in fuzz_m2ts_probe fuzz_probe_analyze fuzz_route fuzz_scene; do
    link_harness "$name" "$SRC/bin/gcc/libgpac_static.a" -lz -lm -lpthread -lssl -lcrypto & pids+=("$!")
done
rc=0
for p in "${pids[@]}"; do wait "$p" || rc=1; done
[ "$rc" -eq 0 ] || { echo "ERROR: a harness failed to build" >&2; exit 1; }

# 3) The TEST ORACLE, NORMAL (un-sanitized) flags — it must NOT carry $SANITIZER_FLAGS. Shares
#    bin/gcc + config.mak with the fuzz build, so distclean first (the fuzz binaries are already in
#    /mayhem and link libgpac statically). Default features (no sanitizers) so the filter /
#    media_tools / utils / isomedia / compositor suites link.
make distclean >/dev/null 2>&1 || true
./configure --unittests --disable-dvb4linux
# `make lib` used to run here, but its bin/gcc/libgpac.so is never used by the oracle; the only thing
# it contributed is include/gpac/revision.h (its `version` prerequisite), so run just that.
make version
# Builds the runner (its own symbol-exporting libgpac under unittests/build, in parallel) AND runs
# launch.sh once, so the build fails fast on a broken suite; mayhem/test.sh runs it again as the
# graded oracle.
# unittests/build/ is the unit-test build dir: ./configure --unittests fills it with symlinked
# Makefiles, and make unit_tests adds config.mak/config.h, the runner's libgpac objects and bin/.
# Upstream's .gitignore covers those generated files but not the directory, so `git clean -ffdX` left
# the symlinks (and a stale .dep) behind. SPEC §6.2 item 16 requires build dirs to be gitignored, so
# mark it self-ignoring (a `*` .gitignore matches itself too) and the clean removes the whole
# directory. Neither configure nor make unit_tests/distclean removes the marker. No upstream file is
# edited.
mkdir -p "$SRC/unittests/build" && printf '*\n' > "$SRC/unittests/build/.gitignore"
make -j"$MAYHEM_JOBS" unit_tests

UT_BIN="$SRC/unittests/build/bin/gcc/unittests"
[ -x "$UT_BIN" ] || { echo "ERROR: unit-test runner $UT_BIN not built" >&2; exit 1; }
echo "built: $UT_BIN (unit-test oracle)"
