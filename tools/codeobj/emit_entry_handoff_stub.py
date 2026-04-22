#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


SUPPORTED_CLASSES = {
    "wave32-direct-vgpr-xyz-setreg-flat-scratch-v1",
    "wave64-packed-v0-10_10_10-flat-scratch-alias-v1",
    "wave64-packed-v0-10_10_10-src-private-base-v1",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Emit a symbolic original-body handoff stub plan from a fail-closed "
            "entry handoff recipe."
        )
    )
    parser.add_argument("recipe", help="Entry handoff recipe JSON")
    parser.add_argument("--output", default=None, help="Optional JSON output path")
    return parser.parse_args()


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def action_by_name(recipe: dict, action_name: str) -> list[dict]:
    return [
        entry
        for entry in recipe.get("reconstruction_actions", [])
        if isinstance(entry, dict) and entry.get("action") == action_name
    ]


def handoff_field_map(recipe: dict) -> dict[str, dict]:
    contract = recipe.get("supplemental_handoff_contract", {})
    fields = contract.get("fields", [])
    return {
        str(entry.get("name")): entry
        for entry in fields
        if isinstance(entry, dict) and isinstance(entry.get("name"), str)
    }


def validation_requirement_map(recipe: dict) -> dict[str, dict]:
    contract = recipe.get("supplemental_handoff_contract", {})
    fields = contract.get("validation_requirements", [])
    return {
        str(entry.get("name")): entry
        for entry in fields
        if isinstance(entry, dict) and isinstance(entry.get("name"), str)
    }


def build_required_inputs(recipe: dict) -> list[dict]:
    fields = handoff_field_map(recipe)
    validation = validation_requirement_map(recipe)
    inputs = [
        {
            "name": "original_launch_kernarg_image",
            "kind": "pointer",
            "required": True,
            "source_class": str(fields.get("original_kernarg_pointer", {}).get("source_class", "dispatch_carried")),
            "acquisition": "hidden_handoff.original_kernarg_pointer",
            "reason": "original body reloads visible args from the original kernarg layout",
        },
        {
            "name": "workgroup_ids",
            "kind": "triple-u32",
            "required": True,
            "source_class": "entry_captured",
            "acquisition": "capture-from-entry-system-sgprs-before-helper-execution",
            "reason": "original body expects workgroup IDs in entry system SGPRs",
        },
        {
            "name": "trampoline_private_segment_wave_offset",
            "kind": "u32",
            "required": True,
            "source_class": str(fields.get("private_segment_wave_offset", {}).get("source_class", "entry_captured")),
            "acquisition": "capture-from-entry-system-sgpr-before-helper-execution",
            "reason": "original body prologue uses the entry private-segment wave offset",
        },
        {
            "name": "preserved_entry_workitem_vgprs",
            "kind": "vgpr-liveins",
            "required": True,
            "source_class": "entry_captured",
            "acquisition": "capture-from-entry-vgprs-before-helper-execution",
            "reason": "original body expects entry workitem VGPR state",
        },
        {
            "name": "wavefront_mode",
            "kind": "enum",
            "required": True,
            "source_class": str(validation.get("wavefront_size", {}).get("source_class", "descriptor_derived")),
            "acquisition": "validate-from-merged-launch-descriptor",
            "reason": "original body was compiled for a specific wave mode",
        },
    ]
    if any(
        entry.get("action") == "materialize-private-segment-state"
        for entry in recipe.get("reconstruction_actions", [])
        if isinstance(entry, dict)
    ):
        inputs.append(
            {
                "name": "flat_scratch_state",
                "kind": "hardware-private-state",
                "required": True,
                "source_class": "entry_captured",
                "acquisition": "reconstruct-from-entry-private-state-before-helper-execution",
                "reason": "original body prologue initializes flat scratch from entry-private state",
            }
        )
    return inputs


def build_register_plan(recipe: dict) -> list[dict]:
    plan: list[dict] = []
    for action in action_by_name(recipe, "materialize-kernarg-base-pair"):
        target_sgprs = action.get("target_sgprs", [])
        if isinstance(target_sgprs, list) and len(target_sgprs) == 2:
            plan.append(
                {
                    "kind": "sgpr-pair",
                    "target": [int(target_sgprs[0]), int(target_sgprs[1])],
                    "source": "original_launch_kernarg_image",
                }
            )
    for action in action_by_name(recipe, "materialize-system-sgpr"):
        target_sgpr = action.get("target_sgpr")
        role = action.get("role")
        if not isinstance(target_sgpr, int) or not isinstance(role, str):
            continue
        if role.startswith("workgroup_id_"):
            source = f"dispatch.{role}"
        elif role == "private_segment_wave_offset":
            source = "trampoline.entry.private_segment_wave_offset"
        else:
            source = f"reconstructed.{role}"
        plan.append({"kind": "sgpr", "target": target_sgpr, "role": role, "source": source})

    for action in action_by_name(recipe, "materialize-entry-workitem-vgprs"):
        count = int(action.get("count", 0) or 0)
        for vgpr in range(count):
            plan.append(
                {
                    "kind": "vgpr",
                    "target": vgpr,
                    "role": f"workitem_id_component_{vgpr}",
                    "source": f"preserved_entry_vgpr[{vgpr}]",
                }
            )
    return plan


def build_symbolic_asm(recipe: dict) -> list[str]:
    lines = [
        "// symbolic handoff stub plan emitted by emit_entry_handoff_stub.py",
        "// not directly assemblable; placeholders identify required reconstruction sources",
    ]
    for entry in build_register_plan(recipe):
        kind = entry.get("kind")
        if kind == "sgpr-pair":
            target = entry.get("target")
            lines.append(
                f"s_mov_b64 s[{target[0]}:{target[1]}], <{entry['source']}>"
            )
        elif kind == "sgpr":
            lines.append(
                f"s_mov_b32 s{entry['target']}, <{entry['source']}>  // {entry.get('role')}"
            )
        elif kind == "vgpr":
            lines.append(
                f"v_mov_b32_e32 v{entry['target']}, <{entry['source']}>  // {entry.get('role')}"
            )
    lines.append("s_setpc_b64 <original_body_entry_symbol_addr_pair>")
    return lines


def build_stub_plan(recipe: dict) -> dict:
    supported = bool(recipe.get("supported"))
    supported_class = recipe.get("supported_class")
    blockers = list(recipe.get("blockers", []))
    if supported and supported_class not in SUPPORTED_CLASSES:
        supported = False
        blockers.append(f"unsupported-stub-generator-class-{supported_class}")

    return {
        "function": recipe.get("function"),
        "arch": recipe.get("arch"),
        "supported": supported,
        "supported_class": supported_class,
        "blockers": blockers,
        "handoff_strategy": "branch-to-original-entry",
        "branch_transfer_kind": "s_setpc_b64",
        "branch_target_symbol": recipe.get("function"),
        "required_inputs": build_required_inputs(recipe),
        "register_plan": build_register_plan(recipe),
        "symbolic_asm": build_symbolic_asm(recipe) if supported else [],
        "notes": [
            "This plan assumes the original body is entered at its function entry.",
            "The kernarg source must preserve the original launch layout, not the trampoline-only layout.",
            "The private-segment wave offset should be forwarded from the trampoline's entry live-in when the merged launch descriptor preserves the original private-segment contract conservatively.",
            "Only the original kernarg pointer is modeled as a dispatch-carried hidden-payload input here; workgroup IDs, private-segment wave offset, and entry VGPR state must be captured before helper execution perturbs them.",
        ],
    }


def main() -> int:
    args = parse_args()
    recipe = load_json(Path(args.recipe).resolve())
    plan = build_stub_plan(recipe)
    payload = json.dumps(plan, indent=2) + "\n"
    if args.output:
        Path(args.output).resolve().write_text(payload, encoding="utf-8")
    sys.stdout.write(payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
