# syntax=docker/dockerfile:1.7

FROM golang:1.25.7-alpine3.23 AS builder

WORKDIR /src

COPY app/go.mod app/go.sum ./
RUN go mod download && go mod verify

COPY app/*.go ./
RUN CGO_ENABLED=0 GOOS=linux go build \
    -ldflags="-s -w" \
    -o /out/server .

FROM alpine:3.23.8

ARG APP_VERSION=1.0.0
ARG VCS_REF=unknown
ARG BUILD_DATE=unknown

LABEL org.opencontainers.image.title="devops-task-app" \
    org.opencontainers.image.description="Production-ready web service for DevOps assessment" \
    org.opencontainers.image.version="${APP_VERSION}" \
    org.opencontainers.image.revision="${VCS_REF}" \
    org.opencontainers.image.created="${BUILD_DATE}" \
    org.opencontainers.image.source="https://github.com/jubayedHdipu/devops-task"

# hadolint ignore=DL3018
RUN apk --no-cache add ca-certificates && \
    addgroup -g 10001 -S appgroup && \
    adduser -u 10001 -S appuser -G appgroup

WORKDIR /app
COPY --from=builder --chown=appuser:appgroup /out/server /app/server

ENV PORT=8080 \
    LOG_LEVEL=info \
    APP_ENV=production \
    APP_VERSION=${APP_VERSION}

EXPOSE 8080

USER 10001:10001

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -qO- http://127.0.0.1:8080/health || exit 1

ENTRYPOINT ["/app/server"]