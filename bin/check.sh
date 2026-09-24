#!/bin/sh
# daily: freshness, snapshot count, stale locks.
# weekly: forget/prune (prune credentials), read-check, multipart sweep.
# Every problem is alerted; exit 1 if any.
set -eu
# shellcheck source=lib/common.sh
. /usr/local/lib/backup/common.sh
restic_setup
mode=${1:-daily}
problems=0
problem() { alert "$*"; problems=$((problems+1)); }
now=$(date +%s)

to_epoch() { # restic RFC3339 time -> epoch (busybox date handles "YYYY-MM-DD HH:MM:SS")
  date -u -d "$(printf '%s' "$1" | cut -c1-19 | tr T ' ')" +%s
}

# "<id> <age in seconds>" per lock. A lock that vanishes between list and cat
# (a run just finished) is skipped rather than aborting the whole check.
lock_ages() {
  for id in $(restic list locks --no-lock 2>/dev/null); do
    t=$(restic cat lock "$id" --no-lock 2>/dev/null | jq -r '.time // empty' 2>/dev/null) || continue
    [ -n "$t" ] || continue
    echo "$id $(( now - $(to_epoch "$t") ))"
  done
}

# Right after the Sunday prune at most KEEP_DAILY+KEEP_WEEKLY+KEEP_MONTHLY
# snapshots remain, and a week of nightlies lands before the next one; the +8
# covers that week plus a manual run.
max_snapshots() {
  echo "${MAX_SNAPSHOTS:-$(( ${KEEP_DAILY:-7} + ${KEEP_WEEKLY:-4} + ${KEEP_MONTHLY:-6} + 8 ))}"
}

daily() {
  snaps=$(restic snapshots --host "$RESTIC_HOST" --json --no-lock 2>/dev/null) \
    || { problem "cannot list snapshots"; return; }
  n=$(printf '%s' "$snaps" | jq length)
  if [ "$n" -eq 0 ]; then problem "no snapshots at all"; else
    latest=$(printf '%s' "$snaps" | jq -r 'max_by(.time).time')
    age=$(( now - $(to_epoch "$latest") ))
    [ "$age" -lt "${MAX_AGE_SECONDS:-93600}" ] || problem "latest snapshot is stale: $((age/3600))h old"
  fi
  limit=$(max_snapshots)
  [ "$n" -le "$limit" ] || problem "$n snapshots exceeds $limit: retention not working?"
  lock_ages > "$STATE_DIR/locks"
  while read -r id lage; do
    [ "$lage" -le "${LOCK_MAX_AGE_SECONDS:-86400}" ] || problem "stale lock $(printf '%s' "$id" | cut -c1-8), $((lage/3600))h old"
  done < "$STATE_DIR/locks"
}

weekly() {
  # rclone view of this repository's own prefix. RESTIC_REPOSITORY = s3:<endpoint>/<bucket>/<prefix>
  rest=${RESTIC_REPOSITORY#s3:}; endpoint=$(printf '%s' "$rest" | cut -d/ -f1-3)
  path=$(printf '%s' "$rest" | cut -d/ -f4-)
  export RCLONE_CONFIG_B_TYPE=s3 RCLONE_CONFIG_B_PROVIDER=Other RCLONE_CONFIG_B_ENDPOINT="$endpoint" \
    RCLONE_CONFIG_B_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" RCLONE_CONFIG_B_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
    RCLONE_CONFIG_B_REGION="${S3_REGION:-us-east-1}" RCLONE_CONFIG_B_FORCE_PATH_STYLE=true

  # A run killed mid-backup leaves a lock restic can't prove stale (it came from
  # another container), and it would block forget/prune's exclusive lock every
  # week. Nothing legitimately holds a lock for LOCK_MAX_AGE_SECONDS (a day), so
  # the prune user removes such locks here, off-host, and reports each one.
  lock_ages > "$STATE_DIR/locks"
  while read -r id lage; do
    [ "$lage" -gt "${LOCK_MAX_AGE_SECONDS:-86400}" ] || continue
    if rclone deletefile "b:$path/locks/$id" >/dev/null 2>&1; then
      problem "removed stale lock $(printf '%s' "$id" | cut -c1-8), $((lage/3600))h old"
    else
      problem "cannot remove stale lock $(printf '%s' "$id" | cut -c1-8)"
    fi
  done < "$STATE_DIR/locks"

  restic forget --host "$RESTIC_HOST" --retry-lock 10m --prune \
    --keep-daily "${KEEP_DAILY:-7}" --keep-weekly "${KEEP_WEEKLY:-4}" --keep-monthly "${KEEP_MONTHLY:-6}" \
    || problem "forget/prune failed"
  restic check --retry-lock 10m --read-data-subset="${READ_SUBSET:-250M}" || problem "restic check failed"

  # Multipart sweep, own prefix only.
  found=$(rclone backend list-multipart-uploads "b:$path" 2>/dev/null | jq '[.[] | length] | add // 0' 2>/dev/null || echo 0)
  if [ "$found" -gt 0 ]; then
    rclone backend cleanup "b:$path" -o max-age="${MULTIPART_MAX_AGE:-72h}" >/dev/null 2>&1 \
      || problem "multipart cleanup failed"
    problem "found $found abandoned multipart upload(s) under $path (cleanup older than ${MULTIPART_MAX_AGE:-72h} ran)"
  fi
}

case "$mode" in
  daily) daily ;;
  weekly) weekly; daily ;;
  *) log "unknown check mode $mode"; exit 2 ;;
esac
[ "$problems" -eq 0 ] || exit 1
log "all checks passed ($mode)"
