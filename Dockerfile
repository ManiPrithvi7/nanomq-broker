FROM emqx/nanomq:latest-full

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      openssl ca-certificates stunnel4 \
 && rm -rf /var/lib/apt/lists/*

RUN rm -rf /etc/nanomq/certs/* 2>/dev/null || true \
 && rm -f /etc/s6-overlay/s6-rc.d/*/run 2>/dev/null || true \
 && rm -f /etc/cont-init.d/* 2>/dev/null || true

COPY nanomq.conf /etc/nanomq.conf
RUN test -s /etc/nanomq.conf && grep -q '0.0.0.0:1883' /etc/nanomq.conf
COPY nanomq.plain.conf /etc/nanomq.plain.conf
COPY stunnel.conf /etc/stunnel/stunnel.conf
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

EXPOSE 8883 1883

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD []