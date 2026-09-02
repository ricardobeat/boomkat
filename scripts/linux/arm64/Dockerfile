# Linux build/test/link-validation image for the JS engine and its bindings.
#
# ARCHITECTURE: linux/arm64, native on an Apple Silicon host.
#
# linux/amd64 was tried first, because c3c 0.8.3 publishes an official x86-64
# Linux binary and no arm64 one. It does not work: under Apple `container`'s
# amd64 emulation, c3c's `posix_spawn` of the C compiler fails before exec, so
# every C-source compile and every link step dies with
#   "Failed to compile c sources using command 'cc ...'"
# even though the identical command run by hand from the same shell succeeds
# and c3c has already written all its .o files. A `cc` shim proved the compiler
# is never invoked (0 shim invocations). Emulated `posix_spawn` also returns
# errno 38 (ENOSYS) where native arm64 returns the usual 2. Hence: build c3c
# 0.8.3 from source for arm64 and run everything natively.
FROM --platform=linux/arm64 debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

# Base toolchain, the LLVM/LLD development packages c3c links against, and the
# per-binding runtimes. libffi is what ruby's fiddle dlopen()s through; python3
# needs no extra package for ctypes.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        clang \
        cmake \
        ninja-build \
        curl \
        ca-certificates \
        xz-utils \
        git \
        jq \
        file \
        binutils \
        python3 \
        ruby \
        ruby-dev \
        libffi-dev \
        zlib1g-dev \
        libzstd-dev \
        llvm-19-dev \
        libclang-19-dev \
        liblld-19-dev \
        libpolly-19-dev \
        libclang-rt-19-dev \
    && rm -rf /var/lib/apt/lists/*

# c3c 0.8.3 built from source: the upstream release has no linux-arm64 asset
# (only x86-64), and matching the host's 0.8.3 exactly is what makes results
# here comparable to the macOS ones.
ARG C3C_VERSION=0.8.3
RUN git clone --depth 1 --branch "v${C3C_VERSION}" https://github.com/c3lang/c3c.git /tmp/c3c \
    && cmake -S /tmp/c3c -B /tmp/c3c/build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_PREFIX_PATH=/usr/lib/llvm-19 \
        -DC3_LLVM_VERSION=19.1.7 \
    && cmake --build /tmp/c3c/build --parallel \
    && mkdir -p /opt/c3 \
    && cp /tmp/c3c/build/c3c /opt/c3/c3c \
    && cp -r /tmp/c3c/lib /opt/c3/lib \
    && rm -rf /tmp/c3c \
    && ln -s /opt/c3/c3c /usr/local/bin/c3c \
    && c3c --version

# Zig, for the static-link init hazard test and the Zig binding. build.zig
# requires 0.16.x exactly (b.createModule + .root_module, std.process.Init).
ARG ZIG_VERSION=0.16.0
RUN curl -fsSL -o /tmp/zig.tar.xz \
        "https://ziglang.org/download/${ZIG_VERSION}/zig-aarch64-linux-${ZIG_VERSION}.tar.xz" \
    && mkdir -p /opt/zig && tar xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
    && rm /tmp/zig.tar.xz \
    && ln -s /opt/zig/zig /usr/local/bin/zig \
    && zig version

# Rust via rustup, for the Rust binding and its half of the static-link test.
ENV RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo
ENV PATH=/opt/cargo/bin:$PATH
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable \
    && rustc --version && cargo --version

WORKDIR /work
