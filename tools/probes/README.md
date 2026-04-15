# Probe Spec Tooling

This directory holds Omniprobe's user-facing probe-spec scaffolding that is
shared by the LLVM/source and binary-only code-object frontends.

Current scope:

- `validate_probe_spec.py`
  - parses a constrained v1 YAML subset without external dependencies
  - validates the shared probe schema described in
    `docs/hsaco-instrumentation-architecture.md`
  - emits normalized JSON so later frontends can consume one canonical shape
- `generate_probe_surrogates.py`
  - consumes the same v1 spec
  - emits generated surrogate HIP/C++ scaffolding plus a JSON manifest
  - gives the LLVM and code-object frontends a stable generated call target for
    each probe instead of forcing them to encode user-helper signatures directly

Current parser constraints:

- block mappings and block sequences
- simple scalars (`true`, `false`, integers, bare strings, quoted strings)
- flow-style lists such as `["kernel"]` or `[kernel_entry, kernel_exit]`
- full-line comments and simple trailing comments

The parser is intentionally smaller than full YAML. It is meant to validate the
first Omniprobe-owned schema without introducing a runtime or build dependency
on an external YAML package.
