# Standalone NanoMQ — build context MUST be this directory (proof_broker/).
# docker build -t proof-nanomq .
# Railway: set service Root Directory to repo root (where this Dockerfile lives).
FROM emqx/nanomq:latest-full

# openssl: NANOMQ_DEBUG_CERTS fingerprint / chain validation in entrypoint
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openssl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY nanomq.conf /etc/nanomq.conf
COPY nanomq.plain.conf /etc/nanomq.plain.conf
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh \
 && test -s /etc/nanomq.conf \
 && grep -q '0.0.0.0:8883' /etc/nanomq.conf

EXPOSE 8883 1883

# Clear base image CMD so Railway does not pass stray args to our entrypoint.
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD []
