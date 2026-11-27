# PWA (SvelteKit adapter-static) is built here and shipped inside the backend image, so one origin serves UI and API.
FROM node:22.21.1-bookworm-slim AS web
WORKDIR /web
COPY web/package.json web/package-lock.json ./
RUN npm ci
COPY web ./
RUN npm run build

FROM swift:6.2-noble AS build
WORKDIR /src
COPY Package.swift Package.resolved* ./
RUN swift package resolve
# Licence notices must match the resolved BoringSSL copies; the build fails if they drift (card 72A0421F).
COPY licenses licenses
COPY scripts/check-third-party-notices.sh scripts/
RUN scripts/check-third-party-notices.sh
COPY Sources Sources
COPY Tests Tests
RUN swift build -c release --product App --static-swift-stdlib

# rclone for deploy targets (ADR 0039): official release, pinned version and checksum per architecture.
FROM ubuntu:noble AS rclone
ARG TARGETARCH
ARG RCLONE_VERSION=1.76.0
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl unzip && rm -rf /var/lib/apt/lists/*
RUN case "$TARGETARCH" in \
      amd64) sum=b00f00b3266c3764413afe599d3ec316f6f43b3e0ea8a0bc1d186d2133e46df7 ;; \
      arm64) sum=ee169016675e23a69d77240565133ff7dbc9b33d16fa8f7053d4af39f1eaeb78 ;; \
      *) echo "unsupported architecture $TARGETARCH" >&2; exit 1 ;; \
    esac \
 && curl -fsSLo /tmp/rclone.zip "https://downloads.rclone.org/v${RCLONE_VERSION}/rclone-v${RCLONE_VERSION}-linux-${TARGETARCH}.zip" \
 && echo "$sum  /tmp/rclone.zip" | sha256sum -c - \
 && mkdir /out && unzip -j /tmp/rclone.zip '*/rclone' -d /out && chmod 755 /out/rclone

FROM ubuntu:noble
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libjemalloc2 libcurl4t64 libxml2 openssh-client curl && rm -rf /var/lib/apt/lists/* \
 && useradd --system --create-home todo
COPY --from=build /src/.build/release/App /usr/local/bin/todo-app
COPY --from=rclone /out/rclone /usr/local/bin/rclone
COPY --from=web /web/build /srv/web
COPY licenses /usr/share/licenses/todo-app
ENV WEB_ROOT=/srv/web
USER todo
EXPOSE 8080
ENTRYPOINT ["todo-app"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
