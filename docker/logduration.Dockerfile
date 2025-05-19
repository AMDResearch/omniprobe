# syntax=docker/dockerfile:1.4

FROM rocm/rocm-build-ubuntu-22.04:6.3
LABEL Description="Docker container for LOGDURATION" 
WORKDIR /app

COPY triton_install.sh /app/triton_install.sh

# =========================
# Dependencies install
# =========================
RUN apt-get update && \
    apt-get install -y software-properties-common && \
    apt-get upgrade -y && \
    apt-get install -y git build-essential wget clang lld libzstd-dev libomp-dev ccache libdwarf-dev python3-dev nlohmann-json3-dev && \
    python3 -m pip install --upgrade pip && \
    python3 -m pip install --upgrade setuptools 

# =========================
# ROCm install
# =========================
RUN ROCM_VERSION="6.3" && \
    ROCM_MAJOR=$(echo ${ROCM_VERSION} | sed 's/\./ /g' | awk '{print $1}') && \
    ROCM_MINOR=$(echo ${ROCM_VERSION} | sed 's/\./ /g' | awk '{print $2}') && \
    ROCM_VERSN=$(( (${ROCM_MAJOR}*10000)+(${ROCM_MINOR}*100) )) && \
    echo "ROCM_MAJOR=${ROCM_MAJOR} ROCM_MINOR=${ROCM_MINOR} ROCM_VERSN=${ROCM_VERSN}" && \
    OS_CODENAME="jammy" && \
    wget -q https://repo.radeon.com/amdgpu-install/${ROCM_VERSION}/ubuntu/${OS_CODENAME}/amdgpu-install_${ROCM_MAJOR}.${ROCM_MINOR}.${ROCM_VERSN}-1_all.deb && \
    apt-get install -y ./amdgpu-install_${ROCM_MAJOR}.${ROCM_MINOR}.${ROCM_VERSN}-1_all.deb && \
    apt-get update -y && \
    apt-get install -y rocm-dev${ROCM_VERSION} rocm-llvm-dev${ROCM_VERSION} rocm-hip-runtime-dev${ROCM_VERSION} rocm-smi-lib${ROCM_VERSION} rocminfo${ROCM_VERSION}
    
ENV PATH=/opt/rocm/bin:${PATH} 
ENV ROCM_PATH=/opt/rocm 
ENV LD_LIBRARY_PATH=/opt/rocm/lib:${LD_LIBRARY_PATH}

# =========================
# Triton install
# =========================
RUN  bash -c "source /app/triton_install.sh -g 368c864e9"

ENV TRITON_HIP_LDD_PATH=${ROCM_PATH}/llvm/bin/ld.lld
ENV TRITON_LLVM=/root/.triton/llvm/llvm-7ba6768d-ubuntu-x64
ENV PATH=/app/triton/.venv/bin:${PATH}

# =========================
# logduration install
# =========================
RUN mkdir -p ~/.ssh && \
    touch ~/.ssh/known_hosts && \
    ssh-keyscan github.com >> ~/.ssh/known_hosts && \
    chmod 700 ~/.ssh && \
    chmod 644 ~/.ssh/known_hosts

RUN --mount=type=ssh \
    cd /app && \
    git clone git@github.com:AMDResearch/logduration.git && \
    cd logduration && \
    git submodule update --init --recursive && \
    mkdir -p /opt/logduration && \
    cmake --version && \
    mkdir -p build && \
    cmake -DCMAKE_INSTALL_PREFIX=/opt/logduration -DCMAKE_PREFIX_PATH=${ROCM_PATH} -DTRITON_LLVM=${TRITON_LLVM} -DCMAKE_BUILD_TYPE=Release -DCMAKE_VERBOSE_MAKEFILE=ON -S . -B build && \
    cmake --build build --target install

ENV PATH=/opt/logduration/bin/logDuration:${PATH}

# Set the default command to run when the container starts
CMD ["bash"]