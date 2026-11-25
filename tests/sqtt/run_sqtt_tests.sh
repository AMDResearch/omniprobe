#!/bin/bash
################################################################################
# SQTT site marker tests
#
# Usage: tests/sqtt/run_sqtt_tests.sh
#
# 1. test_counter_fit.py: the fit, grouping and SPM timelines (no GPU).
# 2. With a GPU: rewrite the lds_conflict kernel (LDS sites) and the
#    cache_miss kernel (--sites memory) with each marker mode (in place,
#    relayout, per block) and check the output is bit-for-bit the original's
#    (lds_module / cache_module load a code object and dump the kernel output).
# 3. With a GPU: run both programs under `omniprobe --sqtt-sites` and check
#    they print the same result as without markers.
#
# Environment: OMNIPROBE_BUILD (default <repo>/build), OMNIPROBE_PYTHON (default
# python3, needs the launcher requirements), ROCM_PATH (default
# /opt/rocm), HIP_VISIBLE_DEVICES to pick a GPU.
################################################################################

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BUILD="${OMNIPROBE_BUILD:-$ROOT/build}"
ROCM="${ROCM_PATH:-/opt/rocm}"
PY="${OMNIPROBE_PYTHON:-python3}"  # needs the launcher requirements (pyfiglet)
LLVM="$ROCM/llvm/bin"
PASS=0
FAIL=0

check() {  # check <name> <command...>
  local name=$1
  shift
  if "$@"; then
    echo "PASS  $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL  $name"
    FAIL=$((FAIL + 1))
  fi
}

check "counter_fit unit tests" python3 "$HERE/test_counter_fit.py"

ARCH=$("$ROCM/bin/rocminfo" 2>/dev/null | grep -o -m1 "gfx[0-9a-f]*")
if [ -z "$ARCH" ] || [ ! -x "$ROCM/bin/hipcc" ]; then
  echo "SKIP  GPU tests (no GPU or no hipcc)"
else
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  "$ROCM/bin/hipcc" -O2 -g --offload-arch="$ARCH" --genco "$HERE/lds_conflict.hip" -o "$TMP/lds.bundle" &&
    "$LLVM/clang-offload-bundler" --unbundle --type=o --input="$TMP/lds.bundle" \
      --targets="hipv4-amdgcn-amd-amdhsa--$ARCH" --output="$TMP/lds.co" &&
    "$ROCM/bin/hipcc" -O2 "$HERE/lds_module.cpp" -o "$TMP/lds_module" &&
    "$ROCM/bin/hipcc" -O2 -g --offload-arch="$ARCH" "$HERE/lds_conflict.hip" -o "$TMP/lds_conflict" ||
    { echo "FAIL  building the test kernel for $ARCH"; exit 1; }

  "$TMP/lds_module" "$TMP/lds.co" "$TMP/orig.bin" 1024 64 64 > /dev/null
  for mode in "" "--relayout" "--per-block" "--per-block --relayout"; do
    # shellcheck disable=SC2086  # mode is a list of options
    check "rewrite ${mode:-in place}: output identical on $ARCH" sh -c \
      "python3 '$ROOT/omniprobe/sqtt/sqtt_site_rewrite.py' $mode --llvm '$LLVM' '$TMP/lds.co' '$TMP/marked.co' > /dev/null &&
       '$TMP/lds_module' '$TMP/marked.co' '$TMP/marked.bin' 1024 64 64 > /dev/null &&
       cmp -s '$TMP/orig.bin' '$TMP/marked.bin'"
  done

  # Global-memory sites (--sites memory) on the cache_miss kernel.
  "$ROCM/bin/hipcc" -O2 -g --offload-arch="$ARCH" --genco "$HERE/cache_miss.hip" -o "$TMP/cm.bundle" &&
    "$LLVM/clang-offload-bundler" --unbundle --type=o --input="$TMP/cm.bundle" \
      --targets="hipv4-amdgcn-amd-amdhsa--$ARCH" --output="$TMP/cm.co" &&
    "$ROCM/bin/hipcc" -O2 "$HERE/cache_module.cpp" -o "$TMP/cache_module" &&
    "$ROCM/bin/hipcc" -O2 -g --offload-arch="$ARCH" "$HERE/cache_miss.hip" -o "$TMP/cache_miss" ||
    { echo "FAIL  building the cache_miss kernel for $ARCH"; exit 1; }
  "$TMP/cache_module" "$TMP/cm.co" "$TMP/cm_orig.bin" 1024 64 64 > /dev/null
  for mode in "" "--relayout" "--per-block" "--per-block --relayout"; do
    # shellcheck disable=SC2086  # mode is a list of options
    check "rewrite --sites memory ${mode:-in place}: output identical on $ARCH" sh -c \
      "python3 '$ROOT/omniprobe/sqtt/sqtt_site_rewrite.py' --sites memory $mode --llvm '$LLVM' '$TMP/cm.co' '$TMP/cm_marked.co' > /dev/null &&
       '$TMP/cache_module' '$TMP/cm_marked.co' '$TMP/cm_marked.bin' 1024 64 64 > /dev/null &&
       cmp -s '$TMP/cm_orig.bin' '$TMP/cm_marked.bin'"
  done

  plain=$("$TMP/lds_conflict" 1024 64 64 | tail -1)
  marked=$("$PY" "$BUILD/bin/omniprobe" --sqtt-sites -k lds_conflict -- "$TMP/lds_conflict" 1024 64 64 2>&1 | tail -1)
  check "omniprobe --sqtt-sites: same program output" test "$plain" = "$marked"
  plain=$("$TMP/cache_miss" 1024 64 64 | tail -1)
  marked=$("$PY" "$BUILD/bin/omniprobe" --sqtt-sites --sites all --per-block -k cache_miss -- "$TMP/cache_miss" 1024 64 64 2>&1 | tail -1)
  check "omniprobe --sqtt-sites --sites all: same program output" test "$plain" = "$marked"
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
