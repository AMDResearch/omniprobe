# syntax=docker/dockerfile:1.4
#
# Omniprobe toolchain image — expensive, rarely rebuilt.
# Contains: ROCm, LLVM (shared libs), Triton, PyTorch ROCm wheel.
# The omniprobe.Dockerfile layers on top of this image.

ARG ROCM_VERSION=7.2
FROM rocm/dev-ubuntu-24.04:${ROCM_VERSION}
ARG ROCM_VERSION=7.2
ARG TRITON_VERSION=v3.7.1
LABEL Description="Omniprobe toolchain: ROCm + LLVM + Triton + PyTorch"
WORKDIR /app

# =========================
# Dependencies
# =========================
RUN apt-get update && \
    apt-get install -y software-properties-common && \
    apt-get upgrade -y && \
    apt-get install -y git build-essential cmake ninja-build wget clang lld libzstd-dev libomp-dev ccache libdwarf-dev python3-dev python3-venv rocm-llvm-dev jq && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

ENV PATH=/opt/rocm/bin:${PATH}
ENV ROCM_PATH=/opt/rocm
ENV LD_LIBRARY_PATH=/opt/rocm/lib:${LD_LIBRARY_PATH}

# =========================
# LLVM build (checkpoint)
# =========================
# This is the most expensive step (~3.5h on GHA, ~25min with 128 cores).
# It is inlined here (not via COPY + script) so it has NO dependency on
# local files. This means:
#   - Changes to triton_install.sh do NOT invalidate this layer
#   - Only changes to ROCM_VERSION, TRITON_VERSION, the apt layer,
#     or this RUN command itself trigger a rebuild
# If any later layer fails, this layer remains cached.
RUN git clone https://github.com/triton-lang/triton.git /app/triton && \
    cd /app/triton && \
    git checkout ${TRITON_VERSION} && \
    # Patch assertion that fails when instrumentation clones kernels
    sed -i 's/^\([[:space:]]*\)assert len(names) == 1/\1# assert len(names) == 1  # patched for Omniprobe/' \
        third_party/amd/backend/compiler.py 2>/dev/null || \
    sed -i 's/^\([[:space:]]*\)assert len(names) == 1/\1# assert len(names) == 1  # patched for Omniprobe/' \
        python/triton/backends/amd/compiler.py 2>/dev/null || true && \
    export PATH=${ROCM_PATH}/llvm/bin:${PATH} && \
    # Resolve the LLVM pin here and pass it in, rather than letting
    # build-llvm-project.sh look it up. That script has no `set -e` and ends with
    # ninja, so an unreadable pin leaves it building whatever commit the freshly
    # cloned llvm-project landed on -- and still exiting 0, which would cache this
    # ~3.5h layer as good. `jq -e` makes a missing/null key an error; the `&&` chain
    # makes any failure fail the RUN. llvm-info.json is v3.8.0+, llvm-hash.txt v3.7.x.
    LLVM_COMMIT_HASH=$(jq -re '.llvm_hash' cmake/llvm-info.json 2>/dev/null || cat cmake/llvm-hash.txt) && \
    [ -n "${LLVM_COMMIT_HASH}" ] && \
    export LLVM_COMMIT_HASH && \
    echo "LLVM commit (pinned): ${LLVM_COMMIT_HASH}" && \
    scripts/build-llvm-project.sh \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DLLVM_CCACHE_BUILD=OFF \
        -DLLVM_ENABLE_ASSERTIONS=ON \
        -DCMAKE_C_COMPILER=clang \
        -DCMAKE_CXX_COMPILER=clang++ \
        -DLLVM_ENABLE_LLD=ON \
        -DBUILD_SHARED_LIBS=ON \
        -DLLVM_OPTIMIZED_TABLEGEN=ON \
        -DMLIR_ENABLE_BINDINGS_PYTHON=OFF \
        -DLLVM_ENABLE_ZSTD=OFF \
        -DLLVM_TARGETS_TO_BUILD="Native;NVPTX;AMDGPU" \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=1 \
        -DLLVM_ENABLE_PROJECTS="clang;mlir;llvm;lld" \
        -DCMAKE_INSTALL_PREFIX=/app/triton/llvm-project/install \
        -B/app/triton/llvm-project/build \
        /app/triton/llvm-project/llvm && \
    # Verify the outcome, not the exit status: a bad reset is silent in that script.
    # A mismatch fails the RUN, so the wrong-LLVM layer is never cached as good.
    ACTUAL_LLVM="$(git -C /app/triton/llvm-project rev-parse HEAD)" && \
    if [ "${ACTUAL_LLVM}" != "${LLVM_COMMIT_HASH}" ]; then \
        echo "ERROR: LLVM tree is at ${ACTUAL_LLVM}, expected ${LLVM_COMMIT_HASH}" >&2; \
        exit 1; \
    fi && \
    echo "LLVM commit verified: ${ACTUAL_LLVM}"

# =========================
# Triton Python env + build
# =========================
# Separate layer from LLVM. If this fails, the LLVM layer above is preserved.
# Uses triton_install.sh --skip-llvm to reuse the already-built LLVM.
COPY containers/triton_install.sh /app/triton_install.sh
RUN cd /app && /app/triton_install.sh --triton-version ${TRITON_VERSION} --skip-llvm

ENV TRITON_HIP_LLD_PATH=${ROCM_PATH}/llvm/bin/ld.lld
ENV TRITON_LLVM=/app/triton/llvm-project/build
ENV PATH=/app/triton/.venv/bin:${PATH}

CMD ["/bin/bash"]
