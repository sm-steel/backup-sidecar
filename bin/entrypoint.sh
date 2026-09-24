#!/bin/sh
set -eu
. /usr/local/lib/backup/common.sh

mode=${1:-schedule}
case "$mode" in
  run) exec /usr/local/bin/backup.sh ;;
  check) exec /usr/local/bin/check.sh daily ;;
  weekly) exec /usr/local/bin/check.sh weekly ;;
  healthcheck)
    max=${MAX_AGE_SECONDS:-93600}
    ref=0
    for f in "$STATE_DIR/last-success" "$STATE_DIR/started"; do
      [ -s "$f" ] && t=$(cat "$f") && [ "$t" -gt "$ref" ] && ref=$t
    done
    [ $(( $(date +%s) - ref )) -lt "$max" ] ;;
  schedule)
    require_env SCHEDULE
    mkdir -p "$STATE_DIR"; date +%s > "$STATE_DIR/started"
    printf '%s /usr/local/bin/backup.sh\n' "$SCHEDULE" > "$STATE_DIR/crontab"
    if [ "${RUN_ON_START:-false}" = "true" ]; then
      /usr/local/bin/backup.sh || log "start-up run failed (see above); scheduler continues"
    fi
    exec supercronic -passthrough-logs "$STATE_DIR/crontab" ;;
  *) log "unknown mode $mode"; exit 2 ;;
esac
