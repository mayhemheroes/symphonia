#!/usr/bin/env bash
#
# symphonia/mayhem/test.sh — RUN Symphonia's OWN upstream test suite (`cargo test`) and emit a
# CTRF summary. exit 0 iff no test failed. build.sh pre-compiled it with `cargo test --no-run`.
#
# PATCH-grade oracle: Symphonia ships a real assertion suite that asserts concrete values, so a
# no-op / "exit(0)" patch CANNOT pass:
#   - workspace unit tests (#[test]) across symphonia-core (bitstream/IO readers, CRC32/MD5
#     checksums, MDCT/FFT DSP known-answer tests, sample conversion, time units, packet handling),
#     symphonia-bundle-flac / -mp3 (frame + synthesis math), symphonia-codec-vorbis (codebooks),
#     symphonia-common (xiph/vorbis), symphonia-format-* (mkv EBML, riff/wave & caf chunk parsing),
#     and symphonia-metadata (id3v2 frame/unsync/base64 decoding, std tags);
#   - symphonia-codec-aac/tests/tests.rs: known-answer decoder tests over hand-built ADTS byte
#     streams that assert the exact error variant / decode outcome.
# These are asserted values / known-answer tests (not "ran without crashing").
#
# Skipped: symphonia-play (the demo audio player) is excluded — it links libpulse (a system audio
# output library, not part of the decoding/demuxing library under test) and ships no tests.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
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

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo not available — cannot run the test suite" >&2
  emit_ctrf "cargo-test" 0 1 0; exit 2
fi

echo "=== running cargo test (Symphonia upstream workspace suite) ==="
# Image DEFAULT toolchain (Dockerfile pins the nightly the fuzz build uses) — no `+toolchain`.
# --no-fail-fast so every test is counted; RUSTFLAGS cleared so nothing leaks from the sanitizer
# build. symphonia-play excluded (system-audio demo, no tests) — matches build.sh's pre-build.
out="$(RUSTFLAGS="" cargo test --no-fail-fast --workspace --exclude symphonia-play --jobs "$MAYHEM_JOBS" 2>&1)"; rc=$?
echo "$out"

# libtest prints one line per test binary:
#   test result: ok. 12 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; ...
PASSED=0; FAILED=0; IGNORED=0
while read -r p f i; do
  PASSED=$(( PASSED + p )); FAILED=$(( FAILED + f )); IGNORED=$(( IGNORED + i ))
done < <(printf '%s\n' "$out" \
  | sed -n 's/^test result:.* \([0-9][0-9]*\) passed; \([0-9][0-9]*\) failed; \([0-9][0-9]*\) ignored.*/\1 \2 \3/p')

# If we parsed no result lines, fall back to the cargo exit code (e.g. compile error).
if [ "$(( PASSED + FAILED + IGNORED ))" -eq 0 ]; then
  echo "could not parse any 'test result:' lines; using cargo exit code $rc" >&2
  [ "$rc" -eq 0 ] && { emit_ctrf "cargo-test" 1 0 0; exit 0; }
  emit_ctrf "cargo-test" 0 1 0; exit 1
fi

emit_ctrf "cargo-test" "$PASSED" "$FAILED" "$IGNORED"
