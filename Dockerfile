FROM swift:6.2-noble AS build
WORKDIR /src
COPY Package.swift Package.resolved* ./
RUN swift package resolve
COPY Sources Sources
COPY Tests Tests
RUN swift build -c release --product App --static-swift-stdlib

FROM ubuntu:noble
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libjemalloc2 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --create-home todo
COPY --from=build /src/.build/release/App /usr/local/bin/todo-app
USER todo
EXPOSE 8080
ENTRYPOINT ["todo-app"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
