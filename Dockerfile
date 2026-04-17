# syntax=docker/dockerfile:1

# -- Stage 1: Build ---------------------------------------------------------
FROM --platform=$BUILDPLATFORM alpine:3.23 AS builder

ARG ZIG_VERSION=0.16.0

RUN apk add --no-cache bash curl musl-dev python3 tar xz

COPY .github/scripts/install-zig.sh /tmp/install-zig.sh
RUN set -eu; \
    export GITHUB_PATH=/tmp/zig-path; \
    export RUNNER_OS=Linux; \
    case "$(uname -m)" in \
      x86_64) export RUNNER_ARCH=X64 ;; \
      aarch64|arm64) export RUNNER_ARCH=ARM64 ;; \
      *) echo "Unsupported host arch: $(uname -m)" >&2; exit 1 ;; \
    esac; \
    bash /tmp/install-zig.sh "${ZIG_VERSION}"; \
    zig_dir="$(cat /tmp/zig-path)"; \
    ln -sf "${zig_dir}/zig" /usr/local/bin/zig; \
    zig version

WORKDIR /app
COPY build.zig build.zig.zon ./
COPY src/ src/
COPY deps/ deps/

ARG TARGETARCH
RUN --mount=type=cache,target=/root/.cache/zig \
    --mount=type=cache,target=/app/.zig-cache \
    set -eu; \
    arch="${TARGETARCH:-}"; \
    if [ -z "${arch}" ]; then \
      case "$(uname -m)" in \
        x86_64) arch="amd64" ;; \
        aarch64|arm64) arch="arm64" ;; \
        *) echo "Unsupported host arch: $(uname -m)" >&2; exit 1 ;; \
      esac; \
    fi; \
    case "${arch}" in \
      amd64) zig_target="x86_64-linux-musl" ;; \
      arm64) zig_target="aarch64-linux-musl" ;; \
      *) echo "Unsupported TARGETARCH: ${arch}" >&2; exit 1 ;; \
    esac; \
    zig build -Dtarget="${zig_target}" -Doptimize=ReleaseSmall

# -- Stage 2: Runtime Base (shared) ----------------------------------------
FROM alpine:3.23 AS release-base

LABEL org.opencontainers.image.source=https://github.com/nullclaw/nulltickets

RUN apk add --no-cache ca-certificates tzdata

RUN mkdir -p /nulltickets-data && chown -R 65534:65534 /nulltickets-data

COPY --from=builder /app/zig-out/bin/nulltickets /usr/local/bin/nulltickets

ENV NULLTICKETS_PORT=7700
WORKDIR /nulltickets-data
EXPOSE 7700
ENTRYPOINT ["nulltickets"]
CMD ["--port", "7700", "--db", "/nulltickets-data/nulltickets.db"]

# Optional autonomous/root mode:
#   docker build --target release-root -t nulltickets:root .
FROM release-base AS release-root
USER 0:0

# Safe default image (used when no --target is provided)
FROM release-base AS release
USER 65534:65534
