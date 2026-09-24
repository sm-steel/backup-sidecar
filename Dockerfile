FROM alpine:3.22.6

ARG RESTIC_VERSION=0.19.1
ARG RESTIC_SHA256=f415415624dcc452f2a02b8c33641791a8c6d6d3b65bbb3543fcf9a25151585c
ARG SUPERCRONIC_VERSION=0.2.49
ARG SUPERCRONIC_SHA1=e63c11a9726b775a6a11801e81af4f3fb926aa68
ARG RCLONE_VERSION=1.75.1
ARG RCLONE_SHA256=982b5aa772841168f8e380f139e9e787b2a105403e32b94da8676a0e1c0a13ab

RUN apk add --no-cache ca-certificates curl jq tzdata \
      postgresql16-client mariadb-client sqlite \
 && cd /tmp \
 && curl -fsSLo restic.bz2 "https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}/restic_${RESTIC_VERSION}_linux_amd64.bz2" \
 && echo "${RESTIC_SHA256}  restic.bz2" | sha256sum -c - \
 && bunzip2 restic.bz2 && install -m 0755 restic /usr/local/bin/restic \
 && curl -fsSLo supercronic "https://github.com/aptible/supercronic/releases/download/v${SUPERCRONIC_VERSION}/supercronic-linux-amd64" \
 && echo "${SUPERCRONIC_SHA1}  supercronic" | sha1sum -c - \
 && install -m 0755 supercronic /usr/local/bin/supercronic \
 && curl -fsSLo rclone.zip "https://github.com/rclone/rclone/releases/download/v${RCLONE_VERSION}/rclone-v${RCLONE_VERSION}-linux-amd64.zip" \
 && echo "${RCLONE_SHA256}  rclone.zip" | sha256sum -c - \
 && unzip -q rclone.zip && install -m 0755 "rclone-v${RCLONE_VERSION}-linux-amd64/rclone" /usr/local/bin/rclone \
 && rm -rf /tmp/*

COPY lib/common.sh /usr/local/lib/backup/common.sh
COPY bin/entrypoint.sh bin/backup.sh bin/check.sh /usr/local/bin/

# Unhealthy if the last successful backup (or container start, before the
# first one) is older than MAX_AGE_SECONDS (default 26 h).
HEALTHCHECK --interval=5m --timeout=10s --start-period=1m CMD ["/usr/local/bin/entrypoint.sh", "healthcheck"]
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["schedule"]
