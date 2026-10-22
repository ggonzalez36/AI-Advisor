# syntax=docker/dockerfile:1

# --- Build stage: static binary (pure-Go SQLite driver, no cgo) ---
FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/portfolio-api ./cmd/api \
    && mkdir -p /out/data

# --- Runtime stage: distroless, no shell, non-root ---
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/portfolio-api /portfolio-api
COPY --from=build --chown=65532:65532 /out/data /data

# Inside a container the service must listen on all interfaces; outside containers
# the binary keeps its secure default (127.0.0.1).
ENV HOST=0.0.0.0 \
    PORT=8080 \
    DB_PATH=/data/portfolio.db

USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/portfolio-api"]
