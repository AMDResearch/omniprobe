#!/bin/bash
################################################################################
# Python API, end to end on real instrumented binaries (ft_python-api-coverage).
#
# tests/test_python_api.py checks the parsers against canned JSON; this checks
# that what the analyzers actually emit comes back through the API with the
# meaning the result classes document: one address per active lane, block ids
# that agree between BasicBlockLogger and BasicBlockAnalysis, extended
# MemoryAccess fields, flat accesses counted, uninstrumented kernels reported.
#
# This script must never print the string that run_all_tests.sh treats as a
# whole-suite skip marker.
################################################################################

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

check_omniprobe

OUT="$OUTPUT_DIR/python_api_e2e"
mkdir -p "$OUT"
K="${BUILD_DIR}/tests/test_kernels"
for b in dual_kernel_test bb_counts_test bb_counts_am_test; do
    if [ ! -x "$K/$b" ]; then
        echo -e "${RED}ERROR: test kernel not found: $K/$b${NC}"
        exit 1
    fi
done

# Two extra probes compiled here: a kernel without the plugin (no clone at
# all) and the same kernel at -O0 with the plugin (all accesses flat).
HIPCC="${ROCM_PATH:-/opt/rocm-7.2.0}/bin/hipcc"
[ -x "$HIPCC" ] || HIPCC="$(command -v hipcc)"
ARCH="$(rocminfo 2>/dev/null | sed -n 's/^ *Name: *\(gfx[0-9a-z]*\) *$/\1/p' | head -1)"
cat > "$OUT/plain.hip" <<'EOF'
#include <hip/hip_runtime.h>
__global__ void plain_kernel(int* d) { d[threadIdx.x] = 1; }
int main() { int* d; (void)hipMalloc(&d, 256); plain_kernel<<<1, 64>>>(d); plain_kernel<<<1, 64>>>(d);
             (void)hipDeviceSynchronize(); return 0; }
EOF
"$HIPCC" --offload-arch="${ARCH:-gfx90a}" "$OUT/plain.hip" -o "$OUT/plain" > "$OUT/plain.log" 2>&1 || \
    echo "  (compile of the uninstrumented probe failed, see $OUT/plain.log)"
"$HIPCC" --offload-arch="${ARCH:-gfx90a}" -O0 -g -fgpu-rdc \
    -fpass-plugin="${OMNIPROBE_ROOT}/lib/plugins/libAMDGCNSubmitAddressMessages-rocm.so" \
    "$OUT/plain.hip" -o "$OUT/plain_O0" > "$OUT/plain_O0.log" 2>&1 || \
    echo "  (compile of the -O0 probe failed, see $OUT/plain_O0.log)"

echo "================================================================================"
echo "Python API end to end"
echo "================================================================================"

QUARTER_LINE="$(grep -n '// BB_LINE_QUARTER$' "$SCRIPT_DIR/test_kernels/bb_counts_test.cpp" | cut -d: -f1)"

# The repository root on PYTHONPATH makes omniprobe.api importable, as for users.
PYTHONPATH="$(dirname "$SCRIPT_DIR")${PYTHONPATH:+:$PYTHONPATH}" \
ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" \
python3 - "$OMNIPROBE" "$K" "$OUT" "$QUARTER_LINE" > "$OUT/results.txt" 2>&1 <<'PY'
import os, sys, traceback
from omniprobe.api import Omniprobe

exe, k, out, quarter = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
op = Omniprobe(exe)

def check(name, fn):
    try:
        msg = fn()
        print(f"RESULT PASS {name}: {msg}")
    except Exception as e:
        print(f"RESULT FAIL {name}: {type(e).__name__}: {e}")
        traceback.print_exc()

def heatmap():
    r = op.analyze_heatmap(f"{k}/dual_kernel_test")
    assert len(r.kernels) == 2, [x.kernel_name for x in r.kernels]
    for x in r.kernels:
        assert x.page_size == 1 << 20, x.page_size
        assert x.pages and all(p.accesses > 0 and p.end_address == p.start_address + x.page_size - 1 for p in x.pages)
    assert r.uninstrumented_kernels == {}, r.uninstrumented_kernels
    return f"{len(r.kernels)} dispatches, page_size {r.kernels[0].page_size}"

def addresses():
    t = op.log_addresses(f"{k}/bb_counts_am_test")
    assert t.records and not t.truncated
    for r in t.records:
        assert len(r.addresses) == r.active_lane_count == bin(r.exec_mask).count("1"), r
    q = [r for r in t.records if r.line == quarter]
    assert q, f"no record at line {quarter}"
    assert all(r.active_lane_count == 16 and r.op_type == "write" and r.memory_space == "global"
               and r.access_size == 4 and r.source_file.endswith("bb_counts_test.cpp") for r in q), q[0]
    return f"{len(t.records)} records, {len(q)} at the 1-in-4 store, 16 addresses each"

def addresses_truncated():
    t = op.log_addresses(f"{k}/bb_counts_am_test", max_records=5)
    assert len(t.records) == 5 and t.truncated, (len(t.records), t.truncated)
    return "5 records, truncated"

def basic_blocks():
    t = op.log_basic_blocks(f"{k}/bb_counts_test")
    a = op.analyze_basic_blocks(f"{k}/bb_counts_test")
    visits, lanes = {}, {}
    for r in t.records:
        visits[r.basic_block_id] = visits.get(r.basic_block_id, 0) + 1
        lanes[r.basic_block_id] = lanes.get(r.basic_block_id, 0) + r.active_lane_count
    want_v = {b.bb_id: b.wave_visits for kk in a.kernels for b in kk.basic_blocks}
    want_l = {b.bb_id: b.active_lanes for kk in a.kernels for b in kk.basic_blocks}
    assert visits == want_v and lanes == want_l, (visits, want_v, lanes, want_l)
    assert all(r.source_file.endswith("bb_counts_test.cpp") for r in t.records)
    return f"{len(t.records)} records agree with BasicBlockAnalysis per block id"

def memory_fields():
    r = op.analyze_memory(f"{k}/dual_kernel_test")
    acc = [x for kk in r.kernels for x in kk.accesses if x.memory_space == "global"]
    assert acc
    for x in acc:
        assert x.cache_lines_needed > 0 and x.cache_lines_used >= x.cache_lines_needed
        assert x.cache_lines_used - x.cache_lines_needed == x.excess_cache_lines
        assert x.isa_instruction.startswith("global_") and x.ir_bytes == 4 and x.isa_bytes == 4
    assert r.uninstrumented_kernels == {}
    return f"{len(acc)} global accesses with needed/used/isa fields"

def uninstrumented():
    r = op.analyze_memory(f"{out}/plain")
    assert r.uninstrumented_kernels == {"plain_kernel(int*) [clone .kd]": 2}, r.uninstrumented_kernels
    return "plain_kernel reported with 2 dispatches"

def flat_counted():
    r = op.analyze_memory(f"{out}/plain_O0")
    assert r.kernels and all(kk.unanalyzed_flat_accesses > 0 and not kk.accesses for kk in r.kernels), \
        [(kk.kernel_name, kk.unanalyzed_flat_accesses, len(kk.accesses)) for kk in r.kernels]
    return f"{sum(kk.unanalyzed_flat_accesses for kk in r.kernels)} flat accesses counted, none analyzed"

for name, fn in [("heatmap", heatmap), ("log_addresses", addresses), ("log_addresses_max_records", addresses_truncated),
                 ("log_basic_blocks_matches_analysis", basic_blocks), ("memory_access_fields", memory_fields),
                 ("uninstrumented_kernels", uninstrumented), ("flat_accesses_counted", flat_counted)]:
    check(name, fn)
PY

while read -r _ verdict name rest; do
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} ${name%:}"
    if [ "$verdict" = PASS ]; then
        echo -e "  ${GREEN}✓ PASS${NC} - $rest"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - $rest"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
done < <(grep '^RESULT ' "$OUT/results.txt")

if [ "$TESTS_RUN" -ne 7 ]; then
    echo -e "${RED}ERROR: expected 7 results, got $TESTS_RUN; see $OUT/results.txt${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

print_summary
