# syntax=docker/dockerfile:1.4
#
# Omniprobe application image — cheap, rebuilt on code changes.
# Layers on top of the toolchain image (toolchain.Dockerfile).

ARG TOOLCHAIN_IMAGE
FROM ${TOOLCHAIN_IMAGE}
ARG HIP_ARCHITECTURES=gfx90a
LABEL Description="Omniprobe: GPU kernel instrumentation toolkit"

# =========================
# Copy project files
# =========================
COPY . /app/omniprobe
WORKDIR /app/omniprobe

# =========================
# Build and install
# =========================
RUN python3 -m pip install -r omniprobe/requirements.txt && \
    mkdir -p /opt/logduration && \
    cmake --version && \
    rm -rf build && \
    mkdir -p build && \
    cmake -DCMAKE_INSTALL_PREFIX=/opt/logduration -DCMAKE_PREFIX_PATH=${ROCM_PATH} -DTRITON_LLVM=${TRITON_LLVM} -DCMAKE_HIP_ARCHITECTURES=${HIP_ARCHITECTURES} -DCMAKE_BUILD_TYPE=Release -DCMAKE_VERBOSE_MAKEFILE=ON -S . -B build && \
    cmake --build build --target install && \
    rm -rf build

ENV PATH=/opt/logduration/bin/logDuration:${PATH}

# Set working directory for mounted projects
WORKDIR /workspace

CMD ["/bin/bash"]
