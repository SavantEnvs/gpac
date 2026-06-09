#!/usr/bin/env bash
#
# gpac/mayhem/test.sh — RUN gpac's in-tree unit-test suite (built by mayhem/build.sh) → CTRF.
# PATCH-grade oracle. build.sh configured a SEPARATE normal-flags build with `./configure --unittests`
# and ran `make unit_tests`, producing the runner at unittests/build/bin/gcc/unittests. This script
# only RUNS it (never compiles) and maps its summary to CTRF.
#
# The suite is assertion-based (assert_equal_* / assert_true / assert_false), so it asserts real
# BEHAVIOUR — a no-op / exit(0) patch fails the assertions. The runner prints, at the end:
#   Tests passed: N      Tests failed: M      Checks passed: P      Checks failed: Q
# and exits non-zero iff a test failed. We parse those and emit CTRF (tests=N+M); pass iff M==0.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

UT_BIN=unittests/build/bin/gcc/unittests
[ -x "$UT_BIN" ] || { echo "missing $UT_BIN — run mayhem/build.sh first" >&2; exit 2; }

# launch.sh sets LD_LIBRARY_PATH to the unittests build dir (where its libgpac.so lives) and runs
# the binary. Capture its output AND its exit code (non-zero iff a test failed).
out="$(bash unittests/launch.sh 2>&1)"; rc=$?
echo "$out"

# Final-summary lines printed by run_tests() in unittests/tests.c.
passed=$( printf '%s\n' "$out" | sed -n 's/^Tests passed: \([0-9][0-9]*\)$/\1/p'  | tail -1)
failed=$( printf '%s\n' "$out" | sed -n 's/^Tests failed: \([0-9][0-9]*\)$/\1/p'  | tail -1)
cpassed=$(printf '%s\n' "$out" | sed -n 's/^Checks passed: \([0-9][0-9]*\)$/\1/p' | tail -1)
cfailed=$(printf '%s\n' "$out" | sed -n 's/^Checks failed: \([0-9][0-9]*\)$/\1/p' | tail -1)

# If the summary lines are missing the runner didn't complete — treat as failure (don't pass silently).
if [ -z "${passed:-}" ] || [ -z "${failed:-}" ]; then
  echo "ERROR: could not parse 'Tests passed/failed' from the unit-test output" >&2
  emit_ctrf "gpac-unittests" 0 1 || true
  exit 1
fi
echo "checks: passed=${cpassed:-?} failed=${cfailed:-?}"

# Belt-and-suspenders: if the binary itself reported a non-zero exit but printed failed=0, flag it.
if [ "$failed" -eq 0 ] && [ "$rc" -ne 0 ]; then
  echo "ERROR: runner exited $rc but reported 0 failed tests — treating as failure" >&2
  failed=1; passed=$(( passed > 0 ? passed - 1 : 0 ))
fi

emit_ctrf "gpac-unittests" "$passed" "$failed"
