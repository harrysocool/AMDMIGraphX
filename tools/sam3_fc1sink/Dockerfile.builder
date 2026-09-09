# syntax=docker/dockerfile:1

FROM ubuntu:24.04@sha256:1e0a86e57d247923571b75e0aaf48a1449cf8c543d51fb3e07a4a7d7bfa79316
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

ARG ROCM_VERSION=7.14
ARG GPU_ARCH=gfx1151
ARG JOBS
ARG RBUILD_COMMIT=6b12f6a10c85a6fc2c0b906da6478d92b4957e29

ENV LC_ALL=C.UTF-8 \
    LANG=C.UTF-8 \
    PIP_BREAK_SYSTEM_PACKAGES=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_INDEX_URL=https://pypi.org/simple

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        bison \
        build-essential \
        ca-certificates \
        cmake \
        curl \
        diffutils \
        flex \
        git \
        gnupg \
        gzip \
        libnuma-dev \
        libssl-dev \
        ninja-build \
        pkg-config \
        python3 \
        python3-dev \
        python3-pip \
        python3-venv \
        zlib1g-dev \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://repo.amd.com/rocm/packages/gpg/rocm.gpg \
        | gpg --dearmor -o /etc/apt/keyrings/amdrocm.gpg \
    && printf '%s\n' \
        'deb [arch=amd64 signed-by=/etc/apt/keyrings/amdrocm.gpg] https://repo.amd.com/rocm/packages-multi-arch/ubuntu2404 stable main' \
        > /etc/apt/sources.list.d/rocm.list

WORKDIR /opt/migraphx-builder
COPY requirements.txt dev-requirements.txt rbuild.ini ./
COPY tools/install_prereqs.sh tools/requirements-py.txt ./
COPY tools/sam3_fc1sink/align_sink_final.patch \
     tools/sam3_fc1sink/check_rocmlir_patch.sh ./tools/sam3_fc1sink/
COPY LICENSE /usr/share/licenses/migraphx-builder/LICENSE

# Keep the source dependency graph intact. Only floating bootstrap tools are
# pinned, and Ninja is selected so CMAKE_BUILD_PARALLEL_LEVEL/CGET_JOBS are
# honored rather than replaced by cget's Makefiles job count.
RUN jobs="${JOBS:-$(nproc)}" \
    && [[ "${jobs}" =~ ^[1-9][0-9]*$ ]] \
    && export CMAKE_BUILD_PARALLEL_LEVEL="${jobs}" CGET_JOBS="${jobs}" \
    && grep -Fq 'https://github.com/RadeonOpenCompute/rbuild/archive/master.tar.gz' \
        install_prereqs.sh \
    && sed -i \
        -e "s|https://github.com/RadeonOpenCompute/rbuild/archive/master.tar.gz|https://github.com/RadeonOpenCompute/rbuild/archive/${RBUILD_COMMIT}.tar.gz|g" \
        -e 's|pip3 install setuptools wheel pipx|pip3 install setuptools==68.1.2 wheel==0.42.0 pipx==1.16.7|' \
        -e 's|rbuild prepare -d \$PREFIX -s develop|rbuild prepare -d $PREFIX -s develop -G Ninja|' \
        install_prereqs.sh \
    && grep -Fq 'ROCm/rocm-recipes@d7827046100ac0ed8167e16c53999baa126e760d' \
        rbuild.ini \
    && grep -Fq 'ROCm/rocm-recipes@d7827046100ac0ed8167e16c53999baa126e760d' \
        dev-requirements.txt \
    && ./install_prereqs.sh --rocm-version "${ROCM_VERSION}" --gpu "${GPU_ARCH}" \
    && test -f /usr/local/hash \
    && ./tools/sam3_fc1sink/check_rocmlir_patch.sh \
    && grep -aFq ROCMLIR_SINK_FINAL_ERF /usr/local/lib/librockCompiler.a \
    && printf '%s\n' /opt/rocm/lib /opt/rocm/llvm/lib \
        > /etc/ld.so.conf.d/migraphx-rocm.conf \
    && rm -rf /opt/rocm/share/rocmcmakebuildtools /var/lib/apt/lists/* \
    && ldconfig

ENV LD_LIBRARY_PATH=/usr/local/lib \
    MIOPEN_FIND_DB_PATH=/tmp/miopen/find-db \
    MIOPEN_USER_DB_PATH=/tmp/miopen/user-db

WORKDIR /src
CMD ["bash"]
