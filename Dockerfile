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

FROM ubuntu:noble
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libjemalloc2 libcurl4t64 libxml2 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --create-home todo
COPY --from=build /src/.build/release/App /usr/local/bin/todo-app
COPY --from=web /web/build /srv/web
COPY licenses /usr/share/licenses/todo-app
ENV WEB_ROOT=/srv/web
USER todo
EXPOSE 8080
ENTRYPOINT ["todo-app"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
