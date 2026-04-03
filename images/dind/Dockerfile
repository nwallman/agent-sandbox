FROM docker:dind
COPY entrypoint.sh /usr/local/bin/dind-entrypoint.sh
RUN chmod +x /usr/local/bin/dind-entrypoint.sh
ENTRYPOINT ["dind-entrypoint.sh"]
