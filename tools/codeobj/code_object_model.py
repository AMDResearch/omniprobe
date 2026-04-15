#!/usr/bin/env python3
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

OMNIPROBE_PREFIX = "__amd_crk_"


def _copy_dicts(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [dict(item) for item in items]


@dataclass
class KernelInventory:
    function_symbols: list[dict[str, Any]] = field(default_factory=list)
    descriptor_symbols: list[dict[str, Any]] = field(default_factory=list)
    descriptors: list[dict[str, Any]] = field(default_factory=list)
    metadata: dict[str, Any] = field(default_factory=dict)
    metadata_note: dict[str, Any] | None = None

    @classmethod
    def from_manifest(cls, payload: dict[str, Any]) -> "KernelInventory":
        return cls(
            function_symbols=_copy_dicts(payload.get("function_symbols", [])),
            descriptor_symbols=_copy_dicts(payload.get("descriptor_symbols", [])),
            descriptors=_copy_dicts(payload.get("descriptors", [])),
            metadata=dict(payload.get("metadata", {})),
            metadata_note=dict(payload["metadata_note"])
            if isinstance(payload.get("metadata_note"), dict)
            else None,
        )

    def to_manifest(self) -> dict[str, Any]:
        manifest = {
            "function_symbols": _copy_dicts(self.function_symbols),
            "descriptor_symbols": _copy_dicts(self.descriptor_symbols),
            "descriptors": _copy_dicts(self.descriptors),
            "metadata": dict(self.metadata),
        }
        if self.metadata_note is not None:
            manifest["metadata_note"] = dict(self.metadata_note)
        return manifest


@dataclass
class FunctionInventory:
    all_symbols: list[dict[str, Any]] = field(default_factory=list)
    helper_symbols: list[dict[str, Any]] = field(default_factory=list)

    @classmethod
    def from_manifest(cls, payload: dict[str, Any]) -> "FunctionInventory":
        return cls(
            all_symbols=_copy_dicts(payload.get("all_symbols", [])),
            helper_symbols=_copy_dicts(payload.get("helper_symbols", [])),
        )

    def to_manifest(self) -> dict[str, Any]:
        return {
            "all_symbols": _copy_dicts(self.all_symbols),
            "helper_symbols": _copy_dicts(self.helper_symbols),
        }


@dataclass
class CodeObjectModel:
    input: str
    input_file: str
    file_size: int
    format: str | None
    arch: str | None
    address_size: str | None
    elf_header: dict[str, Any]
    sections: list[dict[str, Any]] = field(default_factory=list)
    symbols: list[dict[str, Any]] = field(default_factory=list)
    functions: FunctionInventory = field(default_factory=FunctionInventory)
    support_sections: list[dict[str, Any]] = field(default_factory=list)
    kernels: KernelInventory = field(default_factory=KernelInventory)
    clone_intents: list[dict[str, Any]] = field(default_factory=list)

    @classmethod
    def from_manifest(cls, payload: dict[str, Any]) -> "CodeObjectModel":
        return cls(
            input=str(payload.get("input", "")),
            input_file=str(payload.get("input_file", "")),
            file_size=int(payload.get("file_size", 0)),
            format=payload.get("format"),
            arch=payload.get("arch"),
            address_size=payload.get("address_size"),
            elf_header=dict(payload.get("elf_header", {})),
            sections=_copy_dicts(payload.get("sections", [])),
            symbols=_copy_dicts(payload.get("symbols", [])),
            functions=FunctionInventory.from_manifest(payload.get("functions", {})),
            support_sections=_copy_dicts(payload.get("support_sections", [])),
            kernels=KernelInventory.from_manifest(payload.get("kernels", {})),
            clone_intents=_copy_dicts(payload.get("clone_intents", [])),
        )

    def to_manifest(self) -> dict[str, Any]:
        manifest = {
            "input": self.input,
            "input_file": self.input_file,
            "file_size": self.file_size,
            "format": self.format,
            "arch": self.arch,
            "address_size": self.address_size,
            "elf_header": dict(self.elf_header),
            "sections": _copy_dicts(self.sections),
            "symbols": _copy_dicts(self.symbols),
            "functions": self.functions.to_manifest(),
            "support_sections": _copy_dicts(self.support_sections),
            "kernels": self.kernels.to_manifest(),
        }
        if self.clone_intents:
            manifest["clone_intents"] = _copy_dicts(self.clone_intents)
        return manifest

    def kernel_names(self) -> list[str]:
        names: list[str] = []
        for kernel in self.kernels.metadata.get("kernels", []):
            name = kernel.get("name")
            if isinstance(name, str) and name and name not in names:
                names.append(name)
        for descriptor in self.kernels.descriptors:
            name = descriptor.get("kernel_name")
            if isinstance(name, str) and name and name not in names:
                names.append(name)
        return names

    @staticmethod
    def is_omniprobe_clone_name(kernel_name: str) -> bool:
        return kernel_name.startswith(OMNIPROBE_PREFIX)

    @staticmethod
    def kernel_family_name(kernel_name: str) -> str:
        if not CodeObjectModel.is_omniprobe_clone_name(kernel_name):
            return kernel_name
        family = kernel_name[len(OMNIPROBE_PREFIX) :]
        if family.endswith("Pv"):
            family = family[:-2]
        return family

    def primary_kernel_names(self) -> list[str]:
        return [
            name
            for name in self.kernel_names()
            if not self.is_omniprobe_clone_name(name)
        ]

    def kernel_family_map(self) -> dict[str, list[str]]:
        families: dict[str, list[str]] = {}
        for name in self.kernel_names():
            family = self.kernel_family_name(name)
            families.setdefault(family, []).append(name)
        return families

    def descriptor_by_kernel_name(self, kernel_name: str) -> dict[str, Any] | None:
        for descriptor in self.kernels.descriptors:
            if descriptor.get("kernel_name") == kernel_name:
                return descriptor
        return None

    def metadata_by_kernel_name(self, kernel_name: str) -> dict[str, Any] | None:
        kernels = self.kernels.metadata.get("kernels", [])
        if not isinstance(kernels, list):
            return None
        for metadata in kernels:
            if isinstance(metadata, dict) and metadata.get("name") == kernel_name:
                return metadata
        return None
