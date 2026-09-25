#!/bin/sh
# run: dump -> size floor -> restic backup. Exit 0 only after a snapshot
# was written; any failure leaves no new snapshot and no last-success.
set -eu
# shellcheck source=lib/common.sh
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
# restic retries an unreachable backend for ~15 min; the probe is capped so a
# dead endpoint fails fast (a timed-out probe falls through to "not initialising").
if ! out=$(timeout "${PROBE_TIMEOUT_SECONDS:-120}" restic cat config 2>&1 >/dev/null); then
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
    # SQLITE_FILES: space-separated "path" or "path:min_bytes" (a per-file
    # floor; DUMP_MIN_BYTES otherwise). Each copy is named after the file's
    # basename, so basenames must be unique and plain.
    require_env SQLITE_FILES
    for entry in $SQLITE_FILES; do
      f=$entry
      case "$entry" in
        *:*[!0-9]*|*:) ;;                  # colon not followed by digits only: part of the path
        *:*) f=${entry%:*}; FLOORS="${FLOORS:-} $(basename "$f")=${entry##*:}" ;;
      esac
      name=$(basename "$f")
      case "$name" in
        *[!A-Za-z0-9._-]*) fail "sqlite file name $name: only letters, digits, . _ - are supported" ;;
      esac
      [ ! -e "$DUMP_DIR/$name" ] || fail "two sqlite files are named $name: basenames must be unique"
      # sqlite3 would silently create a missing file (on a read-write mount).
      [ -f "$f" ] || fail "sqlite file $f does not exist"
      sqlite3 "$f" ".backup '$DUMP_DIR/$name'" || fail "sqlite .backup of $name failed"
      [ "$(sqlite3 "$DUMP_DIR/$name" 'PRAGMA integrity_check')" = ok ] || fail "sqlite copy of $name fails integrity_check"
    done
    # SQLITE_CHECK: "basename:SQL"; the query runs on the copy and must return >= 1.
    if [ -n "${SQLITE_CHECK:-}" ]; then
      cname=${SQLITE_CHECK%%:*}; csql=${SQLITE_CHECK#*:}
      [ -f "$DUMP_DIR/$cname" ] || fail "SQLITE_CHECK names $cname, which is not in SQLITE_FILES"
      got=$(sqlite3 "$DUMP_DIR/$cname" "$csql" 2>&1) || fail "sanity check on $cname failed to run: $got"
      case "$got" in ''|*[!0-9]*) fail "sanity check on $cname returned '$got', not a number" ;; esac
      [ "$got" -ge 1 ] || fail "sanity check on $cname returned $got (< 1): refusing to back it up"
    fi ;;
  none) ;;
  *) fail "unknown DUMP_KIND=$DUMP_KIND" ;;
esac

floor_for() { # per-file floor from SQLITE_FILES, else DUMP_MIN_BYTES
  for pair in ${FLOORS:-}; do
    case "$pair" in "$1="*) echo "${pair#*=}"; return ;; esac
  done
  echo "$MIN"
}
for f in "$DUMP_DIR"/*; do
  [ -e "$f" ] || continue
  size=$(wc -c < "$f"); floor=$(floor_for "$(basename "$f")")
  [ "$size" -ge "$floor" ] || fail "dump $(basename "$f") is $size bytes (< $floor): refusing to back it up"
done

# shellcheck disable=SC2086 # EXTRA_PATHS is intentionally word-split
restic backup --host "$RESTIC_HOST" --tag nightly --retry-lock 10m "$DUMP_DIR" ${EXTRA_PATHS:-} \
  || fail "restic backup failed"
date +%s > "$STATE_DIR/last-success"
log "backup complete"
