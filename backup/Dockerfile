FROM alpine:3.21

# postgresql16-client must match the server major version (postgres:16).
RUN apk add --no-cache bash postgresql16-client rclone tzdata

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY dump.sh /usr/local/bin/dump.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/dump.sh \
    && mkdir -p /backups

VOLUME ["/backups"]
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
