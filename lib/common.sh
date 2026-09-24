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
