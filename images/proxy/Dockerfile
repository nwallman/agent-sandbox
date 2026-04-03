FROM alpine:3.20
RUN apk add --no-cache squid
RUN mkdir -p /etc/squid /var/cache/squid /var/log/squid /var/run/squid \
    && chown -R squid:squid /var/cache/squid /var/log/squid /var/run/squid
USER squid
ENTRYPOINT ["squid", "-N", "-f", "/etc/squid/squid.conf"]
