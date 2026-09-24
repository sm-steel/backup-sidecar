CREATE TABLE marker (id int PRIMARY KEY, note text);
INSERT INTO marker VALUES (1, 'backup-sidecar-postgres-marker');
CREATE ROLE extra_role LOGIN PASSWORD 'x';  -- cluster-level object pg_dumpall must capture
