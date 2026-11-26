# syntax=docker/dockerfile:1

FROM golang:1.27-trixie AS go-builder
ARG TARGETOS
ARG TARGETARCH
ENV CGO_ENABLED=0 GOWORK=off
WORKDIR /src
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY cmd ./cmd
COPY internal ./internal
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags "-s -w" -o /out/neorecall ./cmd/neorecall
# sherpa-onnx and ONNX Runtime, pinned and checksummed. ffmpeg comes from apt.
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    arch=$TARGETARCH; if [ "$arch" = amd64 ]; then arch=x64; fi; \
    go run ./cmd/neorecall-release native-libs --platform linux --arch "$arch" --output /out/lib

FROM debian:trixie-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates ffmpeg libgomp1 libstdc++6 tini util-linux \
 && rm -rf /var/lib/apt/lists/*

RUN groupadd --gid 1000 neorecall \
 && useradd --uid 1000 --gid 1000 --home-dir /data --no-create-home --shell /usr/sbin/nologin neorecall \
 && mkdir -p /data \
 && chown neorecall:neorecall /data

WORKDIR /app
COPY --from=go-builder /out/neorecall /usr/local/lib/neorecall/neorecall
COPY --from=go-builder /out/lib/ /usr/local/lib/neorecall/
COPY --chmod=0755 scripts/docker-neorecall.sh /usr/local/bin/neorecall
COPY --chmod=0755 scripts/docker-entrypoint.sh /usr/local/bin/docker-entrypoint
COPY LICENSE ./
COPY models ./models
COPY test/fixtures ./test/fixtures
COPY landing ./landing
COPY flutter_app/build/web ./flutter_app/build/web

ENV NEORECALL_HOME=/data \
    NEORECALL_APP_DIR=/app \
    NEORECALL_CONTAINER_IMAGE=1 \
    NEORECALL_RUNTIME_DIR=/usr/local/lib/neorecall \
    NEORECALL_HOST=0.0.0.0 \
    NEORECALL_PORT=4500 \
    NEORECALL_REQUIRE_VECTOR=true

# The container starts as root only so the entrypoint can hand a volume written
# by the Node.js image (which ran as root) to uid 1000 before dropping to it.
VOLUME ["/data"]
EXPOSE 4500
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD ["neorecall", "healthcheck"]

ENTRYPOINT ["tini", "--", "docker-entrypoint"]
CMD ["neorecall", "serve"]
