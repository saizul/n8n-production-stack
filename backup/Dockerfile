FROM alpine:3.21

# postgresql16-client must match the server major version (postgres:16).
# curl sends the optional monitor pings (BACKUP_HEALTHCHECK_URL).
RUN apk add --no-cache bash curl postgresql16-client rclone tzdata

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY dump.sh /usr/local/bin/dump.sh
COPY status.sh /usr/local/bin/status.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/dump.sh /usr/local/bin/status.sh \
    && mkdir -p /backups

VOLUME ["/backups"]
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
