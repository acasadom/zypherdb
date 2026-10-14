# syntax=docker/dockerfile:1
FROM debian:trixie-slim

ARG DEBIAN_FRONTEND=noninteractive

# Ultima release estable de LLVM/Clang a fecha de creacion de este Dockerfile
# es la 22.x; usamos la 20 por ser una rama ya asentada en apt.llvm.org.
# Sube este ARG cuando quieras la ultima:
#   docker build --build-arg LLVM_VERSION=22 -f docker/Dockerfile .
ARG LLVM_VERSION=20

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates wget gnupg lsb-release \
        git curl zip unzip tar pkg-config python3 make gdb \
        cmake ninja-build \
    && wget -q https://apt.llvm.org/llvm.sh -O /tmp/llvm.sh \
    && chmod +x /tmp/llvm.sh \
    && /tmp/llvm.sh ${LLVM_VERSION} all \
    && rm -f /tmp/llvm.sh \
    && rm -rf /var/lib/apt/lists/*

RUN update-alternatives --install /usr/bin/clang        clang        /usr/bin/clang-${LLVM_VERSION}        100 \
 && update-alternatives --install /usr/bin/clang++      clang++      /usr/bin/clang++-${LLVM_VERSION}      100 \
 && update-alternatives --install /usr/bin/clang-format clang-format /usr/bin/clang-format-${LLVM_VERSION} 100 \
 && update-alternatives --install /usr/bin/clang-tidy   clang-tidy   /usr/bin/clang-tidy-${LLVM_VERSION}   100 \
 && update-alternatives --install /usr/bin/lld          lld          /usr/bin/lld-${LLVM_VERSION}          100

ENV CC=clang CXX=clang++

# vcpkg fijado a un commit concreto para builds reproducibles.
# (HEAD de microsoft/vcpkg#master a 2026-09-11). Sube el SHA cuando querais
# refrescar el catalogo de paquetes disponibles.
ENV VCPKG_ROOT=/opt/vcpkg
ARG VCPKG_COMMIT=a1cae005c39be7b18ba319fced856b68d7276271
RUN git clone https://github.com/microsoft/vcpkg.git ${VCPKG_ROOT} \
    && git -C ${VCPKG_ROOT} checkout ${VCPKG_COMMIT} \
    && ${VCPKG_ROOT}/bootstrap-vcpkg.sh -disableMetrics
ENV PATH="${VCPKG_ROOT}:${PATH}"

WORKDIR /workspace
CMD ["/bin/bash"]
