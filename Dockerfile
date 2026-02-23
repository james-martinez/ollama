# vim: filetype=dockerfile

ARG FLAVOR=${TARGETARCH}
ARG PARALLEL=8
ARG ROCMVERSION=7.2
ARG CMAKEVERSION=3.31.2
ARG VULKANVERSION=1.4.321.1

# ==========================================
# PHASE 1: THE FEDORA 43 COMPILER TOOLCHAIN
# ==========================================
FROM registry.fedoraproject.org/fedora:43 AS base-amd64
RUN tee /etc/yum.repos.d/rocm.repo <<REPO
[ROCm-7.2]
name=ROCm7.2
baseurl=https://repo.radeon.com/rocm/rhel10/7.2/main
enabled=1
priority=50
gpgcheck=1
gpgkey=https://repo.radeon.com/rocm/rocm.gpg.key
REPO

RUN dnf -y --nodocs --setopt=install_weak_deps=False \
    install make gcc gcc-c++ cmake lld clang clang-devel compiler-rt libcurl-devel ninja-build \
    rocm-llvm rocm-device-libs hip-runtime-amd hip-devel \
    rocblas rocblas-devel hipblas hipblas-devel rocm-cmake libomp-devel libomp \
    git-core wget python3 ccache tar xz \
    && dnf clean all

ENV ROCM_PATH=/opt/rocm \
    HIP_PATH=/opt/rocm \
    HIP_CLANG_PATH=/opt/rocm/llvm/bin \
    HIP_DEVICE_LIB_PATH=/opt/rocm/amdgcn/bitcode \
    PATH=/opt/rocm/bin:/opt/rocm/llvm/bin:$PATH

ARG VULKANVERSION
RUN wget https://sdk.lunarg.com/sdk/download/${VULKANVERSION}/linux/vulkansdk-linux-x86_64-${VULKANVERSION}.tar.xz -O /tmp/vulkansdk-linux-x86_64-${VULKANVERSION}.tar.xz \
    && tar xvf /tmp/vulkansdk-linux-x86_64-${VULKANVERSION}.tar.xz \
    && /${VULKANVERSION}/vulkansdk -j 8 vulkan-headers \
    && /${VULKANVERSION}/vulkansdk -j 8 shaderc \
    && cp -r /${VULKANVERSION}/x86_64/include/* /usr/local/include/ \
    && cp -r /${VULKANVERSION}/x86_64/lib/* /usr/local/lib
ENV PATH=/${VULKANVERSION}/x86_64/bin:$PATH

FROM --platform=linux/arm64 almalinux:8 AS base-arm64
RUN yum install -y yum-utils epel-release \
    && dnf install -y clang ccache git \
    && yum-config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/rhel8/sbsa/cuda-rhel8.repo
ENV CC=clang CXX=clang++

FROM base-${TARGETARCH} AS base
ARG CMAKEVERSION
RUN curl -fsSL https://github.com/Kitware/CMake/releases/download/v${CMAKEVERSION}/cmake-${CMAKEVERSION}-linux-$(uname -m).tar.gz | tar xz -C /usr/local --strip-components 1
ENV LDFLAGS=-s

# ==========================================
# PHASE 2: APU-OPTIMIZED CMAKE BUILD
# ==========================================
FROM base AS rocm-7
ARG PARALLEL
COPY CMakeLists.txt CMakePresets.json .
COPY ml/backend/ggml/ggml ml/backend/ggml/ggml
RUN --mount=type=cache,target=/root/.ccache \
    cmake --preset 'ROCm 7' \
        -DGPU_TARGETS="gfx1151" \
        -DCMAKE_HIP_FLAGS="-mllvm --amdgpu-unroll-threshold-local=600 -DGGML_HIP_UMA=1" \
        -DCMAKE_CXX_FLAGS="-DGGML_HIP_UMA=1" \
        && cmake --build --parallel ${PARALLEL} --preset 'ROCm 7' \
        && cmake --install build --component HIP --strip --parallel ${PARALLEL}

FROM base AS build
WORKDIR /go/src/github.com/ollama/ollama
COPY go.mod go.sum .
RUN curl -fsSL https://golang.org/dl/go$(awk '/^go/ { print $2 }' go.mod).linux-$(case $(uname -m) in x86_64) echo amd64 ;; aarch64) echo arm64 ;; esac).tar.gz | tar xz -C /usr/local
ENV PATH=/usr/local/go/bin:$PATH
RUN go mod download
COPY . .
ARG GOFLAGS="'-ldflags=-w -s'"
ENV CGO_ENABLED=1
RUN --mount=type=cache,target=/root/.cache/go-build \
    go build -trimpath -buildmode=pie -o /bin/ollama .

FROM scratch AS rocm
COPY --from=rocm-7 dist/lib/ollama /lib/ollama

FROM ${FLAVOR} AS archive
COPY --from=build /bin/ollama /bin/ollama

# ==========================================
# PHASE 3: FEDORA RUNTIME ASSEMBLY
# ==========================================
FROM registry.fedoraproject.org/fedora-minimal:43
RUN tee /etc/yum.repos.d/rocm.repo <<REPO
[ROCm-7.2]
name=ROCm7.2
baseurl=https://repo.radeon.com/rocm/rhel10/7.2/main
enabled=1
priority=50
gpgcheck=1
gpgkey=https://repo.radeon.com/rocm/rocm.gpg.key
REPO

RUN microdnf -y --nodocs --setopt=install_weak_deps=0 \
    install bash ca-certificates libatomic libstdc++ libgcc libgomp \
    hip-runtime-amd rocblas hipblas \
    && microdnf clean all

COPY --from=archive /bin/ollama /usr/bin/ollama
COPY --from=archive /lib/ollama /usr/lib/ollama

ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV LD_LIBRARY_PATH=/usr/lib/ollama:/usr/lib/ollama/rocm:/opt/rocm/lib:/opt/rocm/lib64
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility
ENV NVIDIA_VISIBLE_DEVICES=all
ENV OLLAMA_HOST=0.0.0.0:11434
ENV GGML_CUDA_ENABLE_UNIFIED_MEMORY=1

EXPOSE 11434
ENTRYPOINT ["/usr/bin/ollama"]
CMD ["serve"]
