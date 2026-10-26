# shellcheck shell=sh
# Shared helpers for backup.sh / check.sh. Never echo a secret or a URL
# that embeds one (TELEGRAM_BOT_URL, S3 keys, passwords).
STATE_DIR=${STATE_DIR:-/run/backup}

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

require_env() {
  for v in "$@"; do
    eval "val=\${$v:-}"
    [ -n "$val" ] || { log "missing required env $v"; exit 2; }
  done
}

# Password from env into a 0600 file on tmpfs; the env copy is dropped so
# child processes never inherit it.
restic_setup() {
  require_env RESTIC_REPOSITORY RESTIC_HOST RESTIC_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  mkdir -p "$STATE_DIR"
  umask 077
  printf '%s' "$RESTIC_PASSWORD" > "$STATE_DIR/restic-pass"
  export RESTIC_PASSWORD_FILE="$STATE_DIR/restic-pass"
  unset RESTIC_PASSWORD
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
}

# Telegram sendMessage. TELEGRAM_BOT_URL is the full
# https://api.telegram.org/bot<TOKEN>/sendMessage?chat_id=<ID> URL; it is
# passed to curl only, never logged. curl's own errors are suppressed so a
# failure cannot print the URL.
alert() {
  msg="[backup ${RESTIC_HOST:-?}] $*"
  log "ALERT: $*"
  [ -n "${TELEGRAM_BOT_URL:-}" ] || return 0
  if ! curl -fsS -o /dev/null --max-time 20 --data-urlencode "text=$msg" "$TELEGRAM_BOT_URL" 2>/dev/null; then
    log "alert delivery failed"
  fi
}

fail() { alert "$*"; exit 1; }

to_epoch() { # restic RFC3339 time -> epoch (busybox date handles "YYYY-MM-DD HH:MM:SS")
  date -u -d "$(printf '%s' "$1" | cut -c1-19 | tr T ' ')" +%s
}

# "<id> <age in seconds> <exclusive|shared> <hostname>" per lock. A lock that
# vanishes between list and cat (a run just finished) is skipped rather than
# aborting the caller.
lock_ages() {
  ts=$(date +%s)
  for id in $(restic list locks --no-lock 2>/dev/null); do
    l=$(restic cat lock "$id" --no-lock 2>/dev/null | jq -r 'select(.time)
      | "\(.time) \(if .exclusive then "exclusive" else "shared" end) \(.hostname // "?")"' 2>/dev/null) || continue
    [ -n "$l" ] || continue
    echo "$id $(( ts - $(to_epoch "${l%% *}") )) ${l#* }"
  done
}

# A killed run (CI's weekly prune, say) leaves its lock behind, and an
# exclusive one blocks every later run. Once a lock is STALE_LOCK_AGE_SECONDS
# old, plain `restic unlock` removes only the locks restic itself proves stale
# (unrefreshed for 30 minutes, or a dead PID on this hostname), never a live
# one: since restic 0.15 a process that misses its lock refresh aborts rather
# than carry on unlocked. Every removed lock is alerted. Returns 0 only if a
# lock was removed.
clear_stale_locks() {
  before=$(lock_ages)
  printf '%s\n' "$before" | awk -v max="${STALE_LOCK_AGE_SECONDS:-3600}" 'NF && $2 >= max { f=1 } END { exit !f }' \
    || return 1
  case "$(restic unlock 2>&1)" in *"successfully removed"*) ;; *) return 1 ;; esac
  after=$(restic list locks --no-lock 2>/dev/null) || return 1
  removed=1
  while read -r id lage kind host; do
    [ -n "$id" ] || continue
    printf '%s\n' "$after" | grep -qx "$id" && continue
    alert "removed stale lock $(printf '%s' "$id" | cut -c1-8) ($kind, $host, $((lage/60)) min old)"
    removed=0
  done <<EOF
$before
EOF
  return "$removed"
}
