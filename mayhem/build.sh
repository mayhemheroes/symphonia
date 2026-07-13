#!/usr/bin/env bash
#
# symphonia/mayhem/build.sh — build Symphonia's cargo-fuzz targets as sanitized libFuzzer
# binaries (OSS-Fuzz Rust path: cargo-fuzz + ASan via RUSTFLAGS), then pre-build the upstream
# test suite so mayhem/test.sh only RUNS it.
#
# Symphonia is a pure-Rust audio decoding & demuxing library. cargo-fuzz drives the build:
#   - the produced binaries ARE libFuzzer targets (Mayhem runs them directly, `libfuzzer: true`);
#   - ASan is enabled the Rust way via RUSTFLAGS `-Zsanitizer=address` (NOT clang's
#     $SANITIZER_FLAGS/CFLAGS — those don't apply to rustc). nightly is required for `-Zsanitizer`.
#
# Targets (mayhem/fuzz/fuzz_targets/*.rs — the two historically-fuzzed Mayhem targets, harness
# source copied additively from upstream's fuzz/ crate so upstream stays untouched):
#   decode_any — full probe -> demux -> decode pipeline over arbitrary container bytes.
#   decode_mp3 — MPEG audio (MP1/MP2/MP3) decoder driven directly (upstream's decode_mpa harness;
#                kept under the historical Mayhem name decode_mp3 so run history isn't orphaned).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer (cargo's cc-built deps).
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
export MAYHEM_JOBS
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

# DWARF < 4 debug-info contract (§6.2 item 10). Force DWARF 2 so Mayhem triage / gdb can resolve
# project source lines. The rlenv runtime may export RUST_DEBUG_FLAGS before re-running offline.
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=--dwarf-version=2}"

cd "$SRC"

# ── DWARF < 4 enforcement (§6.2 item 10) ────────────────────────────────────────────────────────
# Rust's ASan runtime is compiled with the nightly's bundled LLVM (DWARF 5) and is linked before
# the project code, so strip its debug sections once so it contributes no debug info.
ASAN_RT="$(find "$RUSTUP_HOME/toolchains" -name "librustc-nightly_rt.asan.a" 2>/dev/null | head -1)"
if [ -n "$ASAN_RT" ] && [ -f "$ASAN_RT" ]; then
    echo "Stripping debug info from Rust ASan runtime to enforce DWARF < 4: $ASAN_RT"
    objcopy --strip-debug "$ASAN_RT"
fi

# libfuzzer-sys compiles libFuzzer from C++ via the cc crate; force DWARF 3 so those CUs also pass.
export CFLAGS="${CFLAGS:+$CFLAGS }-gdwarf-3"
export CXXFLAGS="${CXXFLAGS:+$CXXFLAGS }-gdwarf-3"

# The cargo-fuzz crate is ADDITIVE under mayhem/fuzz/ (harness sources copied from upstream's
# fuzz/ crate; leaving upstream untouched keeps the overlay purely additive).
FUZZ_DIR="mayhem/fuzz"
TRIPLE="x86_64-unknown-linux-gnu"

# Discover every target from the crate's fuzz_targets/ dir (one binary per target).
FUZZ_TARGETS=()
for f in "$FUZZ_DIR"/fuzz_targets/*.rs; do
  FUZZ_TARGETS+=("$(basename "${f%.*}")")
done
[ "${#FUZZ_TARGETS[@]}" -gt 0 ] || { echo "ERROR: no fuzz targets under $FUZZ_DIR/fuzz_targets/" >&2; exit 1; }

# Replicate OSS-Fuzz `compile` RUSTFLAGS for a libFuzzer+ASan Rust build.
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing -Zsanitizer=address ${RUST_DEBUG_FLAGS}"

echo "=== cargo fuzz build (image-default nightly toolchain, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  cargo fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$t"
  bin="$SRC/$FUZZ_DIR/target/$TRIPLE/release/$t"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; ls -la "$SRC/$FUZZ_DIR/target/$TRIPLE/release" >&2 || true; exit 1; }
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

# Pre-build the upstream test suite with the crate's NORMAL flags (no sanitizer RUSTFLAGS, the
# default workspace target dir) so mayhem/test.sh only RUNS it. symphonia-play is a demo player
# that links libpulse (a system audio lib, not part of the library under test) — exclude it.
echo "=== cargo test --no-run (upstream workspace suite, normal flags) ==="
RUSTFLAGS="" cargo test --no-run --workspace --exclude symphonia-play --jobs "$MAYHEM_JOBS"

echo "build.sh complete:"
ls -la /mayhem/decode_any /mayhem/decode_mp3 2>&1 || true
