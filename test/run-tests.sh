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
docker volume rm -f bsc-test_sqlite >/dev/null 2>&1 || true  # used only by docker run, so compose never removes it
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
# printf, not echo: dash's echo treats pg_dumpall's "\connect" as "\c" (stop output)
if printf '%s\n' "$dump" | grep -q 'backup-sidecar-postgres-marker' && printf '%s\n' "$dump" | grep -q 'extra_role'; then
  ok T1-dump-content; else no T1-dump-content; echo "--- dump head:"; printf '%s\n' "$dump" | head -20; restic_raw $R1 ls latest 2>&1 | tail -5; fi

# T2: second run -> no re-init, 2 snapshots
# shellcheck disable=SC2086
if sidecar $PG -e RESTIC_REPOSITORY=$R1 -e RESTIC_HOST=t-pg "$IMG" run >/tmp/t2.log 2>&1 \
   && [ "$(snapcount $R1)" = 2 ] && ! grep -q 'no repository yet' /tmp/t2.log; then ok T2-second-run; else no T2-second-run; cat /tmp/t2.log; fi

# T2b: unreachable endpoint -> non-zero, and it must NOT try to init (review focus #5)
# shellcheck disable=SC2086
if sidecar $PG -e PROBE_TIMEOUT_SECONDS=20 -e RESTIC_REPOSITORY=s3:http://no-such-host:9000/bsc/t/pg -e RESTIC_HOST=t-pg "$IMG" run >/tmp/t2b.log 2>&1; then no T2b-unreachable
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

tglog() { docker run --rm -v bsc-test_tglog:/log alpine:3.22.6 cat /log/requests.log 2>/dev/null || true; }
awscli() {
  docker run --rm --network "$NET" -e AWS_ACCESS_KEY_ID=testkey -e AWS_SECRET_ACCESS_KEY=testsecret123 \
    -e AWS_DEFAULT_REGION=us-east-1 amazon/aws-cli:2.27.50 \
    --endpoint-url http://s3:8333 "$@"
}

# T7: daily check passes on a fresh repo; with MAX_AGE_SECONDS=1 it fails and alerts, token never printed
# shellcheck disable=SC2086
if sidecar -e RESTIC_REPOSITORY=$R1 -e RESTIC_HOST=t-pg "$IMG" check >/tmp/t7a.log 2>&1; then ok T7-daily-ok; else no T7-daily-ok; cat /tmp/t7a.log; fi
sleep 2
# shellcheck disable=SC2086
if sidecar -e MAX_AGE_SECONDS=1 -e RESTIC_REPOSITORY=$R1 -e RESTIC_HOST=t-pg "$IMG" check >/tmp/t7b.log 2>&1; then no T7-stale
elif tglog | grep -q 'stale'; then ok T7-stale-alerted; else no T7-stale-not-alerted; fi
if grep -q 'SECRETTOKEN123' /tmp/t*.log; then no T7-token-leaked; else ok T7-token-not-printed; fi

# T8: a killed backup leaves a lock; daily check flags it when LOCK_MAX_AGE_SECONDS=0
# shellcheck disable=SC2086
docker run -d --name bsc-kill --network "$NET" --entrypoint sh $S3ENV -e RESTIC_PASSWORD=repo-pass "$IMG" \
  -c "restic -r $R1 backup --host t-pg --stdin </dev/urandom" >/dev/null
# endless input, so the backup can't finish first; kill once its lock is visible
i=0
until [ -n "$(restic_raw "$R1" list locks --no-lock 2>/dev/null)" ]; do
  i=$((i+1)); [ "$i" -lt 30 ] || break; sleep 1
done
docker rm -f bsc-kill >/dev/null
# shellcheck disable=SC2086
if sidecar -e LOCK_MAX_AGE_SECONDS=0 -e RESTIC_REPOSITORY=$R1 -e RESTIC_HOST=t-pg "$IMG" check >/tmp/t8.log 2>&1; then no T8-stale-lock
elif grep -q 'lock' /tmp/t8.log; then ok T8-stale-lock-flagged; else no T8-stale-lock-wrong-reason; cat /tmp/t8.log; fi
# The killed process's lock is non-exclusive (backup), so a normal run still
# succeeds while it exists; T8b proves that. Then clear it the way an operator
# would (restic can't prove a lock from another container is stale, which is why
# the daily check reports it instead of the sidecar removing it).
# shellcheck disable=SC2086
if sidecar $PG -e RESTIC_REPOSITORY=$R1 -e RESTIC_HOST=t-pg "$IMG" run >/tmp/t8b.log 2>&1; then ok T8b-run-despite-lock; else no T8b-run-despite-lock; cat /tmp/t8b.log; fi
restic_raw "$R1" unlock --remove-all >/dev/null 2>&1

# T9: snapshots from containers with different hostnames all group under RESTIC_HOST; weekly prunes them
# shellcheck disable=SC2086
for h in a b c; do sidecar --hostname "rand-$h" $PG -e RESTIC_REPOSITORY=$R1 -e RESTIC_HOST=t-pg "$IMG" run >/dev/null 2>&1; done
before=$(snapcount "$R1")
# shellcheck disable=SC2086
if sidecar -e READ_SUBSET=10% -e RESTIC_REPOSITORY=$R1 -e RESTIC_HOST=t-pg "$IMG" weekly >/tmp/t9.log 2>&1 \
   && [ "$before" -ge 5 ] && [ "$(snapcount "$R1")" = 2 ]; then ok T9-weekly-retention; else no "T9-weekly-retention before=$before after=$(snapcount "$R1")"; cat /tmp/t9.log; fi

# T10: an abandoned multipart upload under the prefix is aborted by weekly (MULTIPART_MAX_AGE=0s) and alerted
awscli s3api create-multipart-upload --bucket bsc --key t/pg/data/zz-orphan >/dev/null
# shellcheck disable=SC2086
if sidecar -e MULTIPART_MAX_AGE=0s -e READ_SUBSET=10% -e RESTIC_REPOSITORY=$R1 -e RESTIC_HOST=t-pg "$IMG" weekly >/tmp/t10.log 2>&1; then no T10-multipart-not-reported
elif tglog | grep -q 'multipart'; then ok T10-multipart-alerted; else no T10-multipart-no-alert; cat /tmp/t10.log; fi
# rclone aborts only uploads whose age it can prove; SeaweedFS omits Initiated,
# so there the abort half can't be exercised (it is verified against a real S3 provider instead).
initiated=$(awscli s3api list-multipart-uploads --bucket bsc --prefix t/pg/ --query "Uploads[0].Initiated" --output text)
left=$(awscli s3api list-multipart-uploads --bucket bsc --prefix t/pg/ --query "length(Uploads || \`[]\`)")
if [ "$left" = 0 ]; then ok T10-multipart-aborted
elif [ "$initiated" = None ]; then echo "SKIP T10-multipart-aborted (backend reports no Initiated time)"
else no "T10-multipart-left=$left"; fi

# --- Task 3 appends T7-T10 above this line ---

$C down -v >/dev/null 2>&1
docker volume rm -f bsc-test_sqlite >/dev/null 2>&1 || true
echo "passed=$pass failed=$failn"
[ "$failn" = 0 ]
