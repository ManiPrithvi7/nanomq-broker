# syntax=docker/dockerfile:1
# caddy:builder (not 2.8-builder) — caddy-l4 v0.1.1 requires Go 1.25+ (GOTOOLCHAIN=auto).
FROM caddy:builder AS builder

ENV GOTOOLCHAIN=auto
RUN xcaddy build --with github.com/mholt/caddy-l4

FROM caddy:latest

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
COPY Caddyfile /etc/caddy/Caddyfile

EXPOSE 8883
