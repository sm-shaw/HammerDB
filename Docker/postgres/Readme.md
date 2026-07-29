# PostgreSQL image

This HammerDB 6.0 Ubuntu 24.04 image configures the architecture-neutral official PGDG repository and pins `libpq5` to major 17 with `postgresql-client-17`. Validation checks `psql`, `pg_config`, the loaded path and `170000 <= PQlibVersion() < 180000`.

This addresses the client prerequisite behind [issue #901](https://github.com/TPC-Council/HammerDB/issues/901). It is **not** a claim that the issue is resolved: `test-postgres-direct-tls.sh` must connect to a real TLS server with `sslnegotiation=direct` first.
