# syntax=docker/dockerfile:1.7

FROM registry.fedoraproject.org/fedora:44 AS builder

RUN <<'EOF'
tee /etc/yum.repos.d/rocm.repo <<'REPO'
[rocm]
name=ROCm 7.14.0
baseurl=https://repo.amd.com/rocm/packages-multi-arch/rhel10/x86_64
enabled=1
priority=50
gpgcheck=1
gpgkey=https://repo.amd.com/rocm/packages-multi-arch/gpg/rocm.gpg
REPO
EOF

RUN dnf -y --nodocs --setopt=install_weak_deps=False install \
      make gcc gcc-c++ cmake libcurl-devel ninja-build rdma-core-devel \
      amdrocm-core-devel7.14-gfx1151 git-core patch \
    && dnf clean all \
    && rm -rf /var/cache/dnf/*

ENV ROCM_PATH=/opt/rocm \
    HIP_PATH=/opt/rocm \
    PATH=/opt/rocm/bin:/opt/rocm/core/bin:/opt/rocm/core/lib/llvm/bin:$PATH \
    LD_LIBRARY_PATH=/opt/rocm/core/lib/rocm_sysdeps/lib:/opt/rocm/core/lib

ARG ENGRAMHALO_REPO=https://github.com/Aristo94/EngramHalo.cpp.git
ARG ENGRAMHALO_REF=15176583b358d791b7a73f210ef4ab9e167cfba7
WORKDIR /opt/llama.cpp

RUN git clone --filter=blob:none --no-checkout "$ENGRAMHALO_REPO" . \
    && git checkout --detach "$ENGRAMHALO_REF" \
    && git submodule update --init --recursive \
    && if git apply --check docs/strix-halo/llama-cpp-25992-rocm-host-buffer.patch; then \
         git apply docs/strix-halo/llama-cpp-25992-rocm-host-buffer.patch; \
       elif git apply --reverse --check docs/strix-halo/llama-cpp-25992-rocm-host-buffer.patch; then \
         echo "Host-buffer workaround is already present"; \
       else \
         echo "ERROR: required Strix Halo host-buffer workaround does not apply" >&2; exit 1; \
       fi \
    && if git apply --check docs/strix-halo/llama-cpp-qwen38-per-buffer-mmap.patch; then \
         git apply docs/strix-halo/llama-cpp-qwen38-per-buffer-mmap.patch; \
       else \
         echo "Per-buffer mmap patch is obsolete at the pinned revision; using the in-tree loader"; \
       fi \
    && cmake -S . -B build -G Ninja \
         -DGGML_HIP=ON \
         -DAMDGPU_TARGETS=gfx1151 \
         -DCMAKE_BUILD_TYPE=Release \
         -DGGML_RPC=OFF \
         -DROCM_PATH=/opt/rocm \
         -DHIP_PLATFORM=amd \
    && cmake --build build --config Release --parallel "$(nproc)" \
    && cmake --install build --config Release

RUN mkdir -p /usr/local/lib64 \
    && find /opt/llama.cpp/build -type f -name 'lib*.so*' -exec cp {} /usr/local/lib64/ \; \
    && ldconfig

FROM registry.fedoraproject.org/fedora-minimal:44

RUN <<'EOF'
tee /etc/yum.repos.d/rocm.repo <<'REPO'
[rocm]
name=ROCm 7.14.0
baseurl=https://repo.amd.com/rocm/packages-multi-arch/rhel10/x86_64
enabled=1
priority=50
gpgcheck=1
gpgkey=https://repo.amd.com/rocm/packages-multi-arch/gpg/rocm.gpg
REPO
EOF

RUN microdnf -y --nodocs --setopt=install_weak_deps=0 install \
      bash ca-certificates curl libatomic libstdc++ libgcc libgomp libibverbs \
      amdrocm-runtime7.14 amdrocm-blas7.14-gfx1151 procps-ng \
    && microdnf clean all \
    && rm -rf /var/cache/dnf/* \
    && ln -s core-7.14 /opt/rocm/core \
    && ln -s core-7.14/bin /opt/rocm/bin \
    && ln -s core-7.14/include /opt/rocm/include \
    && ln -s core-7.14/lib /opt/rocm/lib \
    && ln -s core-7.14/libexec /opt/rocm/libexec \
    && ln -s core-7.14/lib/llvm /opt/rocm/llvm \
    && ln -s core-7.14/share /opt/rocm/share \
    && ln -s core-7.14/lib/llvm/amdgcn /opt/rocm/amdgcn

ENV ROCM_PATH=/opt/rocm \
    HIP_PATH=/opt/rocm \
    PATH=/opt/rocm/bin:/opt/rocm/core/bin:/opt/rocm/core/lib/llvm/bin:$PATH \
    LD_LIBRARY_PATH=/opt/rocm/core/lib/rocm_sysdeps/lib:/opt/rocm/core/lib \
    HF_HOME=/cache/huggingface

COPY --from=builder /usr/local/ /usr/local/
COPY config/model-manifest.env /opt/engramhalo/config/model-manifest.env
COPY scripts/ /opt/engramhalo/bin/

RUN echo "/usr/local/lib" > /etc/ld.so.conf.d/local.conf \
    && echo "/usr/local/lib64" >> /etc/ld.so.conf.d/local.conf \
    && echo "/opt/rocm/core/lib" > /etc/ld.so.conf.d/rocm.conf \
    && echo "/opt/rocm/core/lib/rocm_sysdeps/lib" >> /etc/ld.so.conf.d/rocm.conf \
    && ldconfig \
    && chmod 0755 /opt/engramhalo/bin/*.sh \
    && useradd --system --uid 10001 --create-home --home-dir /home/engramhalo engramhalo \
    && mkdir -p /models /cache/huggingface \
    && chown -R engramhalo:engramhalo /models /cache/huggingface /home/engramhalo

USER engramhalo
WORKDIR /models
EXPOSE 8080
CMD ["/opt/engramhalo/bin/start-server.sh"]
