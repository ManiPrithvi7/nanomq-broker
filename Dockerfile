# Railway: set service Root Directory to repo root (where this Dockerfile lives).
FROM emqx/nanomq:latest-full

# Install openssl for cert validation in entrypoint
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openssl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# CRITICAL: Remove baked-in certs and any base-image startup hooks
RUN rm -rf /etc/nanomq/certs/* 2>/dev/null || true \
 && rm -f /etc/s6-overlay/s6-rc.d/*/run 2>/dev/null || true \
 && rm -f /etc/cont-init.d/* 2>/dev/null || true

COPY nanomq.conf /etc/nanomq.conf
COPY nanomq.plain.conf /etc/nanomq.plain.conf
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh \
 && test -s /etc/nanomq.conf \
 && grep -q '0.0.0.0:8883' /etc/nanomq.conf

EXPOSE 8883 1883

# CRITICAL: Override base image entrypoint completely
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD []