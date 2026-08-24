# AssetTracker sync server (single-user, SQLite-backed snapshot store).
# Build: docker build -t asset-sync-server .
# Run:   docker compose up -d   (see docker-compose.yml)
FROM dart:stable AS build
WORKDIR /app
COPY pubspec.* ./
RUN dart pub get
COPY . .
RUN dart compile exe bin/server.dart -o /app/server

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libsqlite3-0 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app/server ./server
EXPOSE 8787
ENV PORT=8787 HOST=0.0.0.0 SYNC_DB_PATH=/data/sync_state.sqlite
VOLUME ["/data"]
ENTRYPOINT ["/app/server"]
