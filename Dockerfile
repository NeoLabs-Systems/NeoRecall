FROM ghcr.io/cirruslabs/flutter:3.35.5 AS flutter-builder
WORKDIR /build/flutter_app
COPY flutter_app/pubspec.yaml flutter_app/pubspec.lock ./
COPY flutter_app/third_party ./third_party
RUN flutter pub get
COPY flutter_app .
RUN flutter build web --release --base-href /app/

FROM node:20-bookworm-slim
ENV NODE_ENV=production \
    NEORECALL_HOME=/root/.neorecall \
    NEORECALL_HOST=0.0.0.0 \
    NEORECALL_PORT=4500 \
    NEORECALL_REQUIRE_VECTOR=true
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates tini && rm -rf /var/lib/apt/lists/*
WORKDIR /opt/neorecall
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force
COPY bin ./bin
COPY lib ./lib
COPY models ./models
COPY runtime ./runtime
COPY server ./server
COPY test/fixtures ./test/fixtures
COPY landing ./landing
COPY --from=flutter-builder /build/flutter_app/build/web ./flutter_app/build/web
RUN chmod +x bin/neorecall.js server/index.js
EXPOSE 4500
VOLUME ["/root/.neorecall"]
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["node", "server/index.js"]
