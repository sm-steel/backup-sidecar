# backup-sidecar

A shared image, `ghcr.io/sm-steel/backup-sidecar:<version>`, that backs up one
service's database into its own restic repository on S3. Each deployer repo on
the smsteel fleet runs it as a `backup` service in its compose stack, pinned to
an exact tag. Design: `priv-vps-infrastructure`,
`docs/superpowers/specs/2026-09-24-per-deployer-backups-design.md`.

## Modes

| Command | What it does | Where it runs |
|---|---|---|
| `schedule` (default) | runs `run` on `SCHEDULE` under supercronic; optional `RUN_ON_START` | on the host, in the deployer's compose |
| `run` | dump → size floor → `restic backup --tag nightly`, init on first use | host (one-off: `docker compose run --rm backup run`) |
| `check` | daily: newest snapshot age, snapshot count, stale locks | the deployer's CI, with the **prune** user |
| `weekly` | `forget` 7d/4w/6m `--prune`, `check --read-data-subset`, multipart sweep, then the daily checks | the deployer's CI, with the **prune** user |
| `healthcheck` | Docker `HEALTHCHECK`: unhealthy once the last success (or start) is older than `MAX_AGE_SECONDS` | host |

`run` never forgets, prunes, unlocks or deletes anything. The host's write-only
S3 user couldn't anyway. Every problem found by `check`/`weekly` is posted to
Telegram and makes the command exit 1.

The repository is initialised only when restic says it doesn't exist. An
unreachable endpoint, bad credentials or a TLS error fail the run instead
(`not initialising`), and the probe gives up after `PROBE_TIMEOUT_SECONDS`
rather than riding restic's ~15-minute retry loop.

## Environment

| Variable | Default | Meaning |
|---|---|---|
| `DUMP_KIND` | — | `postgres`, `mariadb`, `sqlite` or `none` |
| `DB_HOST`, `DB_USER`, `DB_PASSWORD` | — | connection (postgres/mariadb); service names on the compose network |
| `DB_NAME` | — | database to dump (mariadb; postgres uses `pg_dumpall`) |
| `SQLITE_FILES` | — | space-separated database paths, copied with `.backup` (sqlite) |
| `EXTRA_PATHS` | — | files/directories included as-is (mount them read-only) |
| `DUMP_MIN_BYTES` | `1024` | per-dump size floor; a smaller dump fails the run |
| `SCHEDULE` | — | cron expression for `schedule` mode |
| `RUN_ON_START` | `false` | `true` runs one backup at start-up (first deploy only) |
| `RESTIC_REPOSITORY` | — | `s3:https://s3.ru-6.storage.selcloud.ru/smsteel-backup-1/<host>/<service>` |
| `RESTIC_PASSWORD` | — | moved into a tmpfs file (`RESTIC_PASSWORD_FILE`) and unset from the environment |
| `RESTIC_HOST` | — | pinned group key `<host>-<service>`, passed as `--host` |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | — | write user on the host; prune user in CI |
| `TELEGRAM_BOT_URL` | — | full `sendMessage?chat_id=…` URL; never logged |
| `PROBE_TIMEOUT_SECONDS` | `120` | cap on the "does the repository exist" probe |
| `MAX_AGE_SECONDS` | `93600` | healthcheck and daily freshness threshold (26 h) |
| `MAX_SNAPSHOTS` | `20` | daily: more than this means retention isn't running |
| `LOCK_MAX_AGE_SECONDS` | `86400` | daily: older locks are reported (never removed) |
| `KEEP_DAILY` / `KEEP_WEEKLY` / `KEEP_MONTHLY` | `7` / `4` / `6` | weekly retention |
| `READ_SUBSET` | `250M` | weekly `restic check --read-data-subset` |
| `MULTIPART_MAX_AGE` | `72h` | weekly: abort abandoned multipart uploads older than this (younger ones are reported only) |
| `S3_REGION` | `us-east-1` | region for rclone's multipart sweep (`ru-6` on Selectel) |

Mount `/run/backup` and `/var/tmp` as tmpfs: state and dumps never touch disk.

## Compose

```yaml
  backup:
    image: ghcr.io/sm-steel/backup-sidecar:${BACKUP_SIDECAR_VERSION:-0.1.0}
    container_name: keycloak-backup
    hostname: moscow-keycloak-backup
    restart: unless-stopped
    environment:
      DUMP_KIND: postgres
      DB_HOST: keycloak-db
      DB_USER: keycloak
      DB_PASSWORD: ${DB_PASSWORD}
      DUMP_MIN_BYTES: "1000000"
      SCHEDULE: "0 1 * * *"
      RESTIC_REPOSITORY: s3:https://s3.ru-6.storage.selcloud.ru/smsteel-backup-1/moscow/keycloak
      RESTIC_HOST: moscow-keycloak
      RESTIC_PASSWORD: ${RESTIC_PASSWORD}
      AWS_ACCESS_KEY_ID: ${BACKUP_S3_ACCESS_KEY}
      AWS_SECRET_ACCESS_KEY: ${BACKUP_S3_SECRET_KEY}
      RUN_ON_START: ${BACKUP_RUN_ON_START:-false}
    tmpfs:
      - /run/backup
      - /var/tmp
    depends_on:
      - keycloak-db
```

## Restore (operator)

Restores run from an operator machine with the service's **prune** user, which
can read. Never use the host's write user. Password #1 is in the deployer's
SOPS; password #2 (a second key on the same repository) is in the vault.

```sh
export AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=…   # prune user
export RESTIC_REPOSITORY=s3:https://s3.ru-6.storage.selcloud.ru/smsteel-backup-1/moscow/keycloak
restic snapshots --host moscow-keycloak
restic restore latest --host moscow-keycloak --target ./restore
restic dump latest --host moscow-keycloak /var/tmp/dump/pg_dumpall.sql > pg_dumpall.sql
```

Dumps sit under `/var/tmp/dump/` in the snapshot: `pg_dumpall.sql`,
`<DB_NAME>.sql`, or the sqlite file's basename. `EXTRA_PATHS` keep their
original paths.

## Pinned versions and bumping

| Component | Version | Where |
|---|---|---|
| Alpine | 3.22.6 | `FROM` |
| restic | 0.19.1 | `RESTIC_VERSION` + `RESTIC_SHA256` (upstream `SHA256SUMS`) |
| supercronic | 0.2.49 | `SUPERCRONIC_VERSION` + `SUPERCRONIC_SHA1` (release notes) |
| rclone | 1.75.1 | `RCLONE_VERSION` + `RCLONE_SHA256` (upstream `SHA256SUMS`) |
| DB clients | Alpine packages | `postgresql16-client`, `mariadb-client`, `sqlite` |

To bump: change the ARG and its checksum together, taken from the upstream
release's checksum file (never computed from a download you just made), run
the tests, then tag `vX.Y.Z`. CI publishes `ghcr.io/sm-steel/backup-sidecar:X.Y.Z`.
Deployers move to it in their own PR.

## Tests

`docker build -t backup-sidecar:test . && sh test/run-tests.sh` runs the
integration suite: SeaweedFS as S3, postgres, mariadb, sqlite, and a mock
Telegram endpoint. SeaweedFS doesn't report multipart `Initiated` times, so
the "abandoned upload is aborted" half of T10 prints `SKIP` there; it is
proven against Selectel.
