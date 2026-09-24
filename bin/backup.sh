#!/bin/sh
# run: dump -> size floor -> restic backup. Exit 0 only after a snapshot
# was written; any failure leaves no new snapshot and no last-success.
set -eu
. /usr/local/lib/backup/common.sh
restic_setup
require_env DUMP_KIND

DUMP_DIR=/var/tmp/dump
MIN=${DUMP_MIN_BYTES:-1024}
rm -rf "$DUMP_DIR"; mkdir -p "$DUMP_DIR"
trap 'rm -rf "$DUMP_DIR"' EXIT

# Init only when the repo definitely does not exist. restic reports network,
# DNS, TLS and permission failures inside the same "unable to open config
# file" wording as a missing repository, so those markers are checked first:
# initialising over an existing-but-unreachable repository must never happen.
if ! out=$(restic cat config 2>&1 >/dev/null); then
  case "$out" in
    *"no such host"*|*"dial tcp"*|*"connection refused"*|*"i/o timeout"*|*"TLS handshake"*|*"x509"*|*"AccessDenied"*|*"Access Denied"*|*"Forbidden"*|*"SignatureDoesNotMatch"*|*"InvalidAccessKeyId"*)
      fail "cannot reach repository (not initialising): $(printf '%s' "$out" | tail -c 300)" ;;
    *"repository does not exist"*|*"unable to open config file"*|*"Is there a repository at the following location?"*)
      log "no repository yet: initialising"; restic init >/dev/null || fail "restic init failed" ;;
    *) fail "cannot read repository config (not initialising): $(printf '%s' "$out" | tail -c 300)" ;;
  esac
fi

case "$DUMP_KIND" in
  postgres)
    require_env DB_HOST DB_USER DB_PASSWORD
    PGPASSWORD="$DB_PASSWORD" pg_dumpall -h "$DB_HOST" -U "$DB_USER" -f "$DUMP_DIR/pg_dumpall.sql" \
      || fail "pg_dumpall failed" ;;
  mariadb)
    require_env DB_HOST DB_USER DB_PASSWORD DB_NAME
    MYSQL_PWD="$DB_PASSWORD" mariadb-dump -h "$DB_HOST" -u "$DB_USER" \
      --single-transaction --routines --triggers --events "$DB_NAME" > "$DUMP_DIR/$DB_NAME.sql" \
      || fail "mariadb-dump failed" ;;
  sqlite)
    require_env SQLITE_FILES
    for f in $SQLITE_FILES; do
      sqlite3 "$f" ".backup '$DUMP_DIR/$(basename "$f")'" || fail "sqlite .backup of $(basename "$f") failed"
    done ;;
  none) ;;
  *) fail "unknown DUMP_KIND=$DUMP_KIND" ;;
esac

for f in "$DUMP_DIR"/*; do
  [ -e "$f" ] || continue
  size=$(wc -c < "$f")
  [ "$size" -ge "$MIN" ] || fail "dump $(basename "$f") is $size bytes (< $MIN): refusing to back it up"
done

# shellcheck disable=SC2086 # EXTRA_PATHS is intentionally word-split
restic backup --host "$RESTIC_HOST" --tag nightly --retry-lock 10m "$DUMP_DIR" ${EXTRA_PATHS:-} \
  || fail "restic backup failed"
date +%s > "$STATE_DIR/last-success"
log "backup complete"
