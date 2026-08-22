# Linux/amd64 build+test image for the JS engine, for reproducing x86-64 CI
# results on an Apple Silicon host via emulation (podman/QEMU or docker).
#
# ARCHITECTURE: linux/amd64. This is the arch GitHub Actions runs, so it is what
# reproduces an x86-64-specific failure (dtoa rounding, 80-bit long double, and
# other places arm64 and x86-64 differ).
#
# Unlike scripts/linux/arm64 (arm64), this image does NOT build c3c from source: c3c
# publishes an x86-64 Linux binary, and under a real Linux VM with working
# binfmt (podman/QEMU, docker) its posix_spawn of the C compiler works. That
# failure only happened under Apple's `container` amd64 emulation, which is why
# scripts/linux/arm64 went arm64 + source. Here the prebuilt binary is enough.
FROM --platform=linux/amd64 debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

# clang is c3c's C compiler and linker driver; python3 runs the test262 harness;
# the rest are what the engine's build and the test scripts call.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        clang \
        curl \
        ca-certificates \
        xz-utils \
        git \
        python3 \
    && rm -rf /var/lib/apt/lists/*

# Prebuilt c3c, the same version and binary the GitHub workflow downloads.
ARG C3C_VERSION=0.8.2
RUN curl -fsSL -o /tmp/c3c.tar.gz \
        "https://github.com/c3lang/c3c/releases/download/v${C3C_VERSION}/c3-linux.tar.gz" \
    && mkdir -p /opt/c3c \
    && tar xzf /tmp/c3c.tar.gz -C /opt/c3c --strip-components=1 \
    && rm /tmp/c3c.tar.gz \
    && ln -s /opt/c3c/c3c /usr/local/bin/c3c \
    && c3c --version

WORKDIR /work
