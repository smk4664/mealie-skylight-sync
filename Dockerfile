FROM sebrandon1/go-skylight:0.2.6
RUN apk add --no-cache bash curl jq coreutils tzdata
COPY sync.sh /usr/local/bin/sync.sh
RUN chmod +x /usr/local/bin/sync.sh
ENTRYPOINT ["/usr/local/bin/sync.sh"]
