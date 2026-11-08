#!/bin/bash
################################################################################
# A two-source-file application built without -fgpu-rdc, as a Makefile would
# (bf_source-attribution-gaps, bf_logger-record-interleave).
#
#   1. With -g, every MemoryAnalysis entry names its source file. One load whose
#      ISA instruction was merged into a wider load used to get an empty
#      source_file, and the file-name resolver found nothing for this build.
#   2. Without -g, MemoryAnalysis can attribute nothing and drops every access;
#      it used to say nothing and return empty results. It now reports the
#      count (unattributed_accesses) and suggests -g.
#   3. AddressLogger -t json writes one valid JSON object per line even when the
#      two kernels' dispatches overlap. Records of 1 KiB or more from two
#      dispatches used to interleave ("{A}{B}" and an empty line).
#
# This script must never print the string that run_all_tests.sh treats as a
# whole-suite skip marker.
################################################################################

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

check_omniprobe

SRC="${SCRIPT_DIR}/two_file_app"
OUT="$OUTPUT_DIR/two_file_app"
mkdir -p "$OUT"
HIPCC="${ROCM_PATH:-/opt/rocm-7.2.0}/bin/hipcc"
[ -x "$HIPCC" ] || HIPCC="$(command -v hipcc)"
ARCH="$(rocminfo 2>/dev/null | sed -n 's/^ *Name: *\(gfx[0-9a-z]*\) *$/\1/p' | head -1)"
PLUGIN="${OMNIPROBE_ROOT}/lib/plugins/libAMDGCNSubmitAddressMessages-rocm.so"

echo "================================================================================"
echo "Two-file application, no -fgpu-rdc"
echo "================================================================================"

pass() { echo -e "  ${GREEN}✓ PASS${NC} - $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo -e "  ${RED}✗ FAIL${NC} - $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

# build <name> <extra flags>: separate compile and link, like a Makefile
build() {
    local name="$1" flags="$2"
    rm -f "$OUT/$name" "$OUT/$name".*.o
    "$HIPCC" -O2 $flags --offload-arch="${ARCH:-gfx90a}" -fpass-plugin="$PLUGIN" -c "$SRC/main.hip" -o "$OUT/$name.main.o" &&
    "$HIPCC" -O2 $flags --offload-arch="${ARCH:-gfx90a}" -fpass-plugin="$PLUGIN" -c "$SRC/stencil.hip" -o "$OUT/$name.stencil.o" &&
    "$HIPCC" -O2 --offload-arch="${ARCH:-gfx90a}" "$OUT/$name.main.o" "$OUT/$name.stencil.o" -o "$OUT/$name"
}

build app_g "-g" > "$OUT/build_g.log" 2>&1 || echo "  (build with -g failed, see $OUT/build_g.log)"
build app_nog "" > "$OUT/build_nog.log" 2>&1 || echo "  (build without -g failed, see $OUT/build_nog.log)"

################################################################################
TESTS_RUN=$((TESTS_RUN + 1))
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} with_g_every_access_has_its_source_file"
rm -f "$OUT/g.json"
ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" "$OMNIPROBE" -i -a MemoryAnalysis -t json -o "$OUT/g.json" \
    -- "$OUT/app_g" > "$OUT/g.log" 2>&1
verdict="$(python3 - "$OUT/g.json" <<'PY'
import json, os, sys
want = {"stencil5": "stencil.hip", "scale_rows": "main.hip"}
try:
    data = json.load(open(sys.argv[1]))
except Exception as e:
    print(f"BAD output unusable: {e}"); sys.exit()
bad, n, seen = [], 0, set()
for d in data:
    k = next((k for k in want if k in d["kernel"]), None)
    if not k:
        continue
    seen.add(k)
    for a in d["accesses"]:
        n += 1
        if os.path.basename(a["source_file"]) != want[k]:
            bad.append((k, a["line"], a["column"], a["source_file"]))
if seen != set(want):
    print(f"BAD kernels reported: {sorted(seen)}")
elif bad or not n:
    print(f"BAD {len(bad)} of {n} entries without the right file: {bad[:3]}")
else:
    print(f"OK {n} entries, each in its own source file")
PY
)"
[[ "$verdict" == OK* ]] && pass "$verdict" || fail "$verdict"

################################################################################
TESTS_RUN=$((TESTS_RUN + 1))
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} without_g_dropped_accesses_reported"
rm -f "$OUT/nog.json"
ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" "$OMNIPROBE" -i -a MemoryAnalysis -t json -o "$OUT/nog.json" \
    -- "$OUT/app_nog" > "$OUT/nog.log" 2>&1
verdict="$(python3 - "$OUT/nog.json" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception as e:
    print(f"BAD output unusable: {e}"); sys.exit()
counts = {d["kernel"].split("(")[0]: d.get("unattributed_accesses") for d in data}
if len(counts) < 2 or not all(isinstance(c, int) and c > 0 for c in counts.values()):
    print(f"BAD unattributed_accesses per kernel: {counts}")
else:
    print(f"OK unattributed_accesses {counts}")
PY
)"
if [[ "$verdict" == OK* ]] && grep -q "not analyzed: no ISA instruction found .* compile with -g" "$OUT/nog.log"; then
    pass "$verdict, and stderr suggests -g"
else
    fail "$verdict; stderr hint present: $(grep -c 'compile with -g' "$OUT/nog.log")"
fi

################################################################################
TESTS_RUN=$((TESTS_RUN + 1))
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} address_trace_lines_all_valid"
rm -f "$OUT/trace.jsonl"
ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" "$OMNIPROBE" -i -a AddressLogger -t json -o "$OUT/trace.jsonl" \
    -- "$OUT/app_g" > "$OUT/trace.log" 2>&1
verdict="$(python3 - "$OUT/trace.jsonl" <<'PY'
import json, sys
n = bad = 0
try:
    for line in open(sys.argv[1]):
        n += 1
        try:
            json.loads(line)
        except ValueError:
            bad += 1
except OSError as e:
    print(f"BAD {e}"); sys.exit()
print(f"BAD {bad} of {n} lines are not one JSON object" if bad or not n else f"OK {n} lines, each one JSON object")
PY
)"
[[ "$verdict" == OK* ]] && pass "$verdict" || fail "$verdict"

print_summary
