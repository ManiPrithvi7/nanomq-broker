# Standalone NanoMQ — build context MUST be this directory (nanomq-broker/).
# docker build -t proof-nanomq .
# Railway: set service Root Directory to nanomq-broker (or deploy from this folder only).
FROM emqx/nanomq:latest-full

COPY nanomq.conf /etc/nanomq.conf
COPY nanomq.plain.conf /etc/nanomq.plain.conf
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

EXPOSE 8883 1883

ENTRYPOINT ["/docker-entrypoint.sh"]
