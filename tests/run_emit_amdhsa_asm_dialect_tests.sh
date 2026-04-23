#!/bin/bash
################################################################################
# AMDHSA asm emitter dialect tests
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

EMITTER="${REPO_ROOT}/tools/codeobj/emit_amdhsa_asm.py"

echo ""
echo "================================================================================"
echo "AMDHSA Asm Dialect Tests"
echo "================================================================================"
echo "  Emitter: $EMITTER"
echo "================================================================================"

if [ ! -f "$EMITTER" ]; then
    echo -e "${RED}ERROR: emitter not found${NC}"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
WORK_DIR="$OUTPUT_DIR/emit_amdhsa_asm_dialect"
mkdir -p "$WORK_DIR"

GFX942_IR="$WORK_DIR/gfx942.ir.json"
GFX942_MANIFEST="$WORK_DIR/gfx942.manifest.json"
GFX1030_IR="$WORK_DIR/gfx1030.ir.json"
GFX1030_MANIFEST="$WORK_DIR/gfx1030.manifest.json"
GFX942_OUT="$WORK_DIR/gfx942.s"
GFX1030_OUT="$WORK_DIR/gfx1030.s"

if ! python3 - "$GFX942_IR" "$GFX942_MANIFEST" gfx942 "$GFX1030_IR" "$GFX1030_MANIFEST" gfx1030 <<'PY'
import json
import sys
from pathlib import Path


def write_fixture(ir_path: str, manifest_path: str, arch: str) -> None:
    kernel_name = "synthetic_kernel"
    descriptor_name = f"{kernel_name}.kd"
    ir = {
        "arch": arch,
        "functions": [
            {
                "name": kernel_name,
                "start_address": 256,
                "instructions": [
                    {
                        "address": 256,
                        "mnemonic": "s_endpgm",
                        "operand_text": "",
                    }
                ],
                "basic_blocks": [{"start_address": 256}],
            }
        ],
    }
    manifest = {
        "arch": arch,
        "sections": [
            {
                "name": ".text",
                "address": 256,
                "alignment": 256,
            }
        ],
        "functions": {
            "all_symbols": [
                {
                    "name": kernel_name,
                    "value": 256,
                    "size": 4,
                    "section": ".text",
                    "binding": "global",
                }
            ],
            "helper_symbols": [],
        },
        "kernels": {
            "function_symbols": [{"name": kernel_name}],
            "descriptor_symbols": [{"name": descriptor_name, "binding": "global"}],
            "descriptors": [
                {
                    "name": descriptor_name,
                    "kernel_name": kernel_name,
                    "group_segment_fixed_size": 0,
                    "private_segment_fixed_size": 0,
                    "kernarg_size": 16,
                    "compute_pgm_rsrc1": {
                        "float_round_mode_32": 0,
                        "float_round_mode_16_64": 0,
                        "float_denorm_mode_32": 0,
                        "float_denorm_mode_16_64": 0,
                        "enable_dx10_clamp": 1,
                        "enable_ieee_mode": 1,
                        "fp16_overflow": 0,
                        "workgroup_processor_mode": 0,
                        "memory_ordered": 0,
                        "forward_progress": 0,
                    },
                    "compute_pgm_rsrc2": {
                        "user_sgpr_count": 2,
                        "enable_private_segment": 1,
                        "enable_sgpr_workgroup_id_x": 1,
                        "enable_sgpr_workgroup_id_y": 0,
                        "enable_sgpr_workgroup_id_z": 0,
                        "enable_sgpr_workgroup_info": 0,
                        "enable_vgpr_workitem_id": 0,
                        "exception_fp_ieee_invalid_op": 0,
                        "exception_fp_denorm_src": 0,
                        "exception_fp_ieee_div_zero": 0,
                        "exception_fp_ieee_overflow": 0,
                        "exception_fp_ieee_underflow": 0,
                        "exception_fp_ieee_inexact": 0,
                        "exception_int_div_zero": 0,
                    },
                    "compute_pgm_rsrc3": {
                        "shared_vgpr_count": 0,
                    },
                    "kernel_code_properties": {
                        "enable_sgpr_private_segment_buffer": 1,
                        "enable_sgpr_dispatch_ptr": 0,
                        "enable_sgpr_queue_ptr": 0,
                        "enable_sgpr_kernarg_segment_ptr": 1,
                        "enable_sgpr_dispatch_id": 0,
                        "enable_sgpr_flat_scratch_init": 1,
                        "enable_sgpr_private_segment_size": 0,
                        "enable_wavefront_size32": 0,
                        "uses_dynamic_stack": 0,
                        "kernarg_preload_spec_length": 0,
                        "kernarg_preload_spec_offset": 0,
                    },
                }
            ],
            "metadata": {
                "kernels": [
                    {
                        "name": kernel_name,
                        "symbol": descriptor_name,
                        "sgpr_count": 8,
                        "vgpr_count": 2,
                        "kernarg_segment_size": 16,
                        "private_segment_fixed_size": 0,
                        "wavefront_size": 64,
                    }
                ],
                "raw": (
                    "---\n"
                    "amdhsa.kernels:\n"
                    f"  - .name: {kernel_name}\n"
                    f"    .symbol: '{descriptor_name}'\n"
                    f"amdhsa.target: amdgcn-amd-amdhsa--{arch}\n"
                ),
            },
        },
    }
    Path(ir_path).write_text(json.dumps(ir, indent=2) + "\n", encoding="utf-8")
    Path(manifest_path).write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


write_fixture(sys.argv[1], sys.argv[2], sys.argv[3])
write_fixture(sys.argv[4], sys.argv[5], sys.argv[6])
PY
then
    echo -e "${RED}ERROR: failed to generate emitter fixtures${NC}"
    exit 1
fi

python3 "$EMITTER" "$GFX942_IR" "$GFX942_MANIFEST" --output "$GFX942_OUT" > "$WORK_DIR/gfx942.out"
python3 "$EMITTER" "$GFX1030_IR" "$GFX1030_MANIFEST" --output "$GFX1030_OUT" > "$WORK_DIR/gfx1030.out"

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="emit_amdhsa_asm_gfx942_cdna_dialect"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"

if python3 - "$GFX942_OUT" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
assert ".amdhsa_kernel synthetic_kernel" in text
assert ".amdhsa_accum_offset 4" in text
assert ".amdhsa_enable_private_segment 1" in text
assert ".amdhsa_tg_split 0" in text
assert ".amdhsa_user_sgpr_kernarg_preload_length 0" in text
assert ".amdhsa_user_sgpr_kernarg_preload_offset 0" in text
assert ".amdhsa_user_sgpr_private_segment_buffer " not in text
assert ".amdhsa_user_sgpr_flat_scratch_init " not in text
assert ".amdhsa_system_sgpr_private_segment_wavefront_offset " not in text
assert ".amdhsa_reserve_flat_scratch " not in text
assert ".amdhsa_workgroup_processor_mode " not in text
assert ".amdhsa_memory_ordered " not in text
assert ".amdhsa_forward_progress " not in text
PY
then
    echo -e "  ${GREEN}✓ PASS${NC} - Gfx942 emitter selects the ROCm 7.2 CDNA directive family"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Gfx942 emitter output did not match the expected CDNA dialect"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="emit_amdhsa_asm_gfx1030_rdna_dialect"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"

if python3 - "$GFX1030_OUT" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
assert ".amdhsa_kernel synthetic_kernel" in text
assert ".amdhsa_user_sgpr_private_segment_buffer 1" in text
assert ".amdhsa_user_sgpr_flat_scratch_init 1" in text
assert ".amdhsa_system_sgpr_private_segment_wavefront_offset 1" in text
assert ".amdhsa_reserve_flat_scratch 1" in text
assert ".amdhsa_workgroup_processor_mode 0" in text
assert ".amdhsa_memory_ordered 0" in text
assert ".amdhsa_forward_progress 0" in text
assert ".amdhsa_shared_vgpr_count 0" in text
assert ".amdhsa_accum_offset " not in text
assert ".amdhsa_enable_private_segment " not in text
assert ".amdhsa_tg_split " not in text
PY
then
    echo -e "  ${GREEN}✓ PASS${NC} - Gfx1030 emitter preserves the RDNA directive family"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Gfx1030 emitter output did not match the expected RDNA dialect"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

print_summary
