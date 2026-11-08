# Dossier — rf_triton-v3.9-bump

## Metadata

- Workflow ID: rf_triton-v3.9-bump
- Workflow Type: refactor
- Lifecycle State: done
- Owner / Current Executor: opimpl worker (supervised run, 2026-11-08)
- Base Commit: a8914eb

```write-scope
containers/toolchain.Dockerfile
containers/toolchain.def
containers/triton_install.sh
cmake_modules/add_instrumentation_plugins.cmake
tests/triton/run_test.sh
docs/triton-instrumentation.md
docs/building-from-source.md
```

## Objective

Pin Triton v3.9.0 (owner D4: after the bug fixes) with omniprobe's instrumented output unchanged.

## Acceptance Criteria

- **AC-1**: Triton v3.9.0 + LLVM b010a18d built from source on gfx90a with `triton_install.sh`.
- **AC-2**: omniprobe compiles under `-Werror` against LLVM 24 (both plugin variants).
- **AC-3**: instrumented output unchanged vs v3.8.0 (see artifacts.md).
- **AC-4**: full suite 20/20, 0 skipped, on `build/` with the v3.9.0 environment.
