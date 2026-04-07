# Container Usage

Omniprobe provides container definitions for both Docker and Apptainer (formerly
Singularity). Containers bundle ROCm, LLVM, Triton, and Omniprobe into a
self-contained environment — no host-side build setup required.

## Architecture

The container build uses a **two-stage** approach:

1. **Toolchain image** — ROCm base + shared-library LLVM + Triton. This is the
   expensive layer (~3.5 hours on GitHub Actions, ~25 minutes on a 128-core
   machine). It rarely changes and is cached between builds.

2. **Omniprobe image** — layers the project source, builds it against the
   toolchain, and installs to `/opt/omniprobe`. This is the cheap layer (~10
   minutes) and rebuilds on every code change.

```
┌──────────────────────────────┐
│  omniprobe image             │  ← rebuilds on code changes
│  pip install + cmake + make  │
│  /opt/omniprobe/{bin,lib,..} │
├──────────────────────────────┤
│  toolchain image             │  ← cached, rarely rebuilt
│  ROCm + LLVM + Triton        │
│  rocm/dev-ubuntu-24.04 base  │
└──────────────────────────────┘
```

### Container files

| File | Purpose |
|------|---------|
| `containers/toolchain.Dockerfile` | Docker toolchain stage |
| `containers/omniprobe.Dockerfile` | Docker Omniprobe stage |
| `containers/toolchain.def` | Apptainer toolchain stage |
| `containers/omniprobe.def` | Apptainer Omniprobe stage |
| `containers/build-container.sh` | Build script (both backends) |
| `containers/run-container.sh` | Run script (both backends) |
| `containers/triton_install.sh` | Triton + LLVM build helper |

## Building containers

```bash
# Docker
./containers/build-container.sh --docker

# Apptainer
./containers/build-container.sh --apptainer

# Both at once
./containers/build-container.sh --docker --apptainer

# Specify ROCm version (default: 7.2)
./containers/build-container.sh --docker --rocm 7.1
```

### Build options

| Flag | Default | Description |
|------|---------|-------------|
| `--docker` | — | Build Docker image |
| `--apptainer` | — | Build Apptainer SIF |
| `--rocm VERSION` | `7.2` | ROCm version (supported: 7.0, 7.1, 7.2) |

At least one of `--docker` or `--apptainer` is required.

### Toolchain caching

- **Docker**: Uses BuildKit layer caching. The LLVM build layer is cached
  independently — subsequent builds skip it unless the Triton version changes.
- **Apptainer**: If a `toolchain_<version>-rocm<rocm>.sif` file exists in the
  project directory, it is reused. Delete it to force a toolchain rebuild.

## Running containers

```bash
# Docker
./containers/run-container.sh --docker

# Apptainer
./containers/run-container.sh --apptainer

# With specific ROCm version
./containers/run-container.sh --docker --rocm 7.1
```

### Run options

| Flag | Default | Description |
|------|---------|-------------|
| `--docker` | — | Run via Docker |
| `--apptainer` | — | Run via Apptainer |
| `--rocm VERSION` | `7.2` | ROCm version |

Exactly one of `--docker` or `--apptainer` is required.

### What happens when you run

1. If the container image does not exist, it is built automatically.
2. The project directory is mounted at `/workspace`.
3. An interactive shell is started.
4. Omniprobe is pre-installed at `/opt/omniprobe` and on `PATH`.

### Docker details

The Docker container runs with:
- GPU device access (`/dev/kfd`, `/dev/dri`)
- `video` group membership
- `SYS_PTRACE` capability (for GPU debugging)

### Apptainer details

The Apptainer container runs with:
- `--cleanenv` for a clean environment
- The project directory bind-mounted at `/workspace`

## Using Omniprobe inside the container

Once inside the container, Omniprobe is ready to use:

```bash
# Run a memory analysis on your application
omniprobe -i -a MemoryAnalysis -- ./your_application

# Build your own project against the container's ROCm + Triton
cd /workspace
cmake -B build -DROCM_PATH=/opt/rocm ...
cmake --build build
```

You can also rebuild Omniprobe itself from source inside the container:

```bash
cd /workspace
cmake -B build \
    -DROCM_PATH=/opt/rocm \
    -DTRITON_LLVM=/app/triton/llvm-project/build \
    -DCMAKE_HIP_ARCHITECTURES=gfx90a \
    -DINTERCEPTOR_BUILD_TESTING=ON

cmake --build build -j$(nproc)
```

## Filesystem requirements

Instrumented GPU libraries (`.hsaco` files) are loaded via `hipModuleLoad`,
which uses `mmap`. Some virtual filesystems (notably **virtiofs**, used by some
VM hypervisors) do not support `mmap`, causing `hipModuleLoad` to fail.

If you encounter this, copy instrumented libraries to a local filesystem before
use:

```bash
cp instrumented_library.hsaco /tmp/
# Point your application at /tmp/instrumented_library.hsaco
```

This affects the host filesystem, not the container itself — container-internal
filesystems are always mmap-capable.
