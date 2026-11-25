# syntax=docker/dockerfile:1

FROM ghcr.io/cirruslabs/flutter:3.35.5 AS flutter-builder
WORKDIR /build/flutter_app
COPY flutter_app/pubspec.yaml flutter_app/pubspec.lock ./
COPY flutter_app/third_party ./third_party
RUN flutter pub get
COPY flutter_app .
RUN flutter build web --release --base-href /app/

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

FROM debian:trixie-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates ffmpeg libgomp1 tini \
 && rm -rf /var/lib/apt/lists/*

RUN groupadd --gid 1000 neorecall \
 && useradd --uid 1000 --gid 1000 --home-dir /data --no-create-home --shell /usr/sbin/nologin neorecall \
 && mkdir -p /data \
 && chown neorecall:neorecall /data

WORKDIR /app
COPY --from=go-builder /out/neorecall /usr/local/bin/neorecall
COPY models ./models
COPY test/fixtures ./test/fixtures
COPY landing ./landing
COPY --from=flutter-builder /build/flutter_app/build/web ./flutter_app/build/web

ENV NEORECALL_HOME=/data \
    NEORECALL_APP_DIR=/app \
    NEORECALL_CONTAINER_IMAGE=1 \
    NEORECALL_HOST=0.0.0.0 \
    NEORECALL_PORT=4500 \
    NEORECALL_REQUIRE_VECTOR=true

USER neorecall
VOLUME ["/data"]
EXPOSE 4500
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD ["neorecall", "healthcheck"]

ENTRYPOINT ["tini", "--"]
CMD ["neorecall", "serve"]
