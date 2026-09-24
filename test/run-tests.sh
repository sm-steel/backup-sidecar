#!/bin/sh
# Integration tests: run from anywhere with Docker available (built image
# backup-sidecar:test, or IMG=...). Scenarios T1-T10, see the M4 plan.
set -eu
cd "$(dirname "$0")"
C="docker compose -f compose.yml"
NET=bsc-test_default
IMG=${IMG:-backup-sidecar:test}
REPO_BASE="s3:http://s3:8333/bsc"
pass=0; failn=0
ok() { pass=$((pass+1)); echo "PASS $1"; }
no() { failn=$((failn+1)); echo "FAIL $1"; }
S3ENV="-e AWS_ACCESS_KEY_ID=testkey -e AWS_SECRET_ACCESS_KEY=testsecret123"

# sidecar <docker args...> <image> <mode>: the image with the common test
# env; container hostname is random unless --hostname is given.
sidecar() {
  # shellcheck disable=SC2086
  docker run --rm --network "$NET" --tmpfs /run/backup --tmpfs /var/tmp $S3ENV \
    -e RESTIC_PASSWORD=repo-pass -e "TELEGRAM_BOT_URL=http://tg:8080/botSECRETTOKEN123/sendMessage?chat_id=1" \
    "$@"
}
# restic_raw <repo> <args...>: plain restic against a test repo.
restic_raw() {
  r=$1; shift
  # shellcheck disable=SC2086
  docker run --rm --network "$NET" --entrypoint restic $S3ENV -e RESTIC_PASSWORD=repo-pass "$IMG" -r "$r" "$@"
}
snapcount() { restic_raw "$1" snapshots --json 2>/dev/null | jq length 2>/dev/null || echo 0; }

$C down -v >/dev/null 2>&1 || true
$C up -d >/dev/null
i=0
until docker run --rm --network "$NET" --entrypoint rclone -e RCLONE_CONFIG_M_TYPE=s3 \
    -e RCLONE_CONFIG_M_PROVIDER=SeaweedFS -e RCLONE_CONFIG_M_ENDPOINT=http://s3:8333 \
    -e RCLONE_CONFIG_M_ACCESS_KEY_ID=testkey -e RCLONE_CONFIG_M_SECRET_ACCESS_KEY=testsecret123 \
    "$IMG" mkdir m:bsc >/dev/null 2>&1; do
  i=$((i+1)); [ "$i" -lt 30 ] || { echo "S3 never came up"; exit 1; }; sleep 2
done
sleep 8  # DB init scripts

PG="-e DUMP_KIND=postgres -e DB_HOST=postgres -e DB_USER=app -e DB_PASSWORD=pgpass -e DUMP_MIN_BYTES=100"
R1="$REPO_BASE/t/pg"

# T1: first run on an empty prefix -> init + 1 snapshot with the marker and the extra role
# shellcheck disable=SC2086
if sidecar $PG -e RESTIC_REPOSITORY=$R1 -e RESTIC_HOST=t-pg "$IMG" run >/tmp/t1.log 2>&1 \
   && [ "$(snapcount $R1)" = 1 ]; then ok T1-first-run; else no T1-first-run; cat /tmp/t1.log; fi
dump=$(restic_raw $R1 dump latest /var/tmp/dump/pg_dumpall.sql 2>/dev/null || true)
if echo "$dump" | grep -q 'backup-sidecar-postgres-marker' && echo "$dump" | grep -q 'extra_role'; then
  ok T1-dump-content; else no T1-dump-content; echo "--- dump head:"; echo "$dump" | head -20; restic_raw $R1 ls latest 2>&1 | tail -5; fi

# T2: second run -> no re-init, 2 snapshots
# shellcheck disable=SC2086
if sidecar $PG -e RESTIC_REPOSITORY=$R1 -e RESTIC_HOST=t-pg "$IMG" run >/tmp/t2.log 2>&1 \
   && [ "$(snapcount $R1)" = 2 ] && ! grep -q 'no repository yet' /tmp/t2.log; then ok T2-second-run; else no T2-second-run; cat /tmp/t2.log; fi

# T2b: unreachable endpoint -> non-zero, and it must NOT try to init (review focus #5)
# shellcheck disable=SC2086
if sidecar $PG -e RESTIC_REPOSITORY=s3:http://no-such-host:9000/bsc/t/pg -e RESTIC_HOST=t-pg "$IMG" run >/tmp/t2b.log 2>&1; then no T2b-unreachable
elif grep -q 'not initialising' /tmp/t2b.log && ! grep -q 'no repository yet' /tmp/t2b.log; then ok T2b-unreachable-no-init; else no T2b-wrong-path; cat /tmp/t2b.log; fi

# T3: wrong DB password -> non-zero, no new snapshot (review focus #1)
if sidecar -e DUMP_KIND=postgres -e DB_HOST=postgres -e DB_USER=app -e DB_PASSWORD=WRONG \
     -e RESTIC_REPOSITORY=$R1 -e RESTIC_HOST=t-pg "$IMG" run >/tmp/t3.log 2>&1; then no T3-bad-password
elif [ "$(snapcount $R1)" = 2 ]; then ok T3-bad-password; else no T3-bad-password-snapshot-created; fi

# T4: size floor -> non-zero, no snapshot
# shellcheck disable=SC2086
if sidecar $PG -e DUMP_MIN_BYTES=999999999 -e RESTIC_REPOSITORY=$R1 -e RESTIC_HOST=t-pg "$IMG" run >/tmp/t4.log 2>&1; then no T4-size-floor
elif [ "$(snapcount $R1)" = 2 ]; then ok T4-size-floor; else no T4-size-floor-snapshot-created; fi

# T5: mariadb as the app user
R5="$REPO_BASE/t/mdb"
if sidecar -e DUMP_KIND=mariadb -e DB_HOST=mariadb -e DB_USER=app -e DB_PASSWORD=mdbpass -e DB_NAME=app \
     -e DUMP_MIN_BYTES=100 -e RESTIC_REPOSITORY=$R5 -e RESTIC_HOST=t-mdb "$IMG" run >/tmp/t5.log 2>&1 \
   && restic_raw $R5 dump latest /var/tmp/dump/app.sql 2>/dev/null | grep -q 'backup-sidecar-mariadb-marker'; then
  ok T5-mariadb; else no T5-mariadb; cat /tmp/t5.log; fi

# T6: sqlite online .backup of a WAL database + an extra file
docker run --rm -v bsc-test_sqlite:/data --entrypoint sh "$IMG" -c \
  "sqlite3 /data/data.db 'PRAGMA journal_mode=WAL; CREATE TABLE t(x); INSERT INTO t VALUES (42);' && echo keydata > /data/id_ed25519" >/dev/null
R6="$REPO_BASE/t/sqlite"
if sidecar -v bsc-test_sqlite:/data -e DUMP_KIND=sqlite -e SQLITE_FILES=/data/data.db -e EXTRA_PATHS=/data/id_ed25519 \
     -e DUMP_MIN_BYTES=100 -e RESTIC_REPOSITORY=$R6 -e RESTIC_HOST=t-sqlite "$IMG" run >/tmp/t6.log 2>&1 \
   && restic_raw $R6 ls latest 2>/dev/null | grep -q '/data/id_ed25519'; then ok T6-sqlite; else no T6-sqlite; cat /tmp/t6.log; fi

# --- Task 3 appends T7-T10 above this line ---

$C down -v >/dev/null 2>&1
echo "passed=$pass failed=$failn"
[ "$failn" = 0 ]
