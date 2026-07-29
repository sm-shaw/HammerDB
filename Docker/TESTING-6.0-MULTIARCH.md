# HammerDB 6.0 multi-architecture test plan

Only these status terms are used: `PASS`, `FAIL`, `BLOCKED`, `NOT RUN`.

## Automated validation

The manually dispatched workflow accepts the required archive/library checksum inputs. `build-only` uses Buildx and QEMU, builds in dependency order, then loads and smoke-tests separate AMD64 and ARM64 images. Every test validates Ubuntu 24.04, image architecture, HammerDB 6.0, CLI startup and `librarycheck`. Component tests additionally validate MySQL ELF/SONAME, the Ubuntu MariaDB package, libpq 17 through `PQlibVersion()`, Oracle dependencies, and SQL Server's stored `--enable-fastvalidate` evidence.

`push-test` publishes only immutable commit-SHA test tags using `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN`; each manifest must contain `linux/amd64` and `linux/arm64`. It never changes production tags. `promote-production` is upstream-only, explicitly confirmed, and copies previously tested manifests without rebuilding.

## Manual test matrix

| Test | Initial status | Completion criterion |
|---|---|---|
| GitHub Actions `build-only` | NOT RUN | Both platform jobs and every smoke test complete |
| Native AMD64 CLI/library checks | NOT RUN | Tests pass without emulation |
| Native ARM64 CLI/library checks | NOT RUN | Tests pass without emulation |
| PostgreSQL direct TLS / issue #901 | NOT RUN | `PG_DIRECT_TLS_DSN` including `sslnegotiation=direct` succeeds |
| Oracle connection | NOT RUN | Authenticated connection succeeds |
| SQL Server connection | NOT RUN | Authenticated ODBC connection succeeds |
| MySQL connection | NOT RUN | Authenticated connection succeeds |
| MariaDB connection | NOT RUN | Authenticated connection succeeds |
| PostgreSQL connection | NOT RUN | Authenticated connection succeeds |
| Schema build, workload, result and schema deletion for each database | NOT RUN | Each lifecycle completes on its matching test image |
| Immutable pushed manifests | NOT RUN | Manifest inspection reports AMD64 and ARM64 |

Do not change a row to `PASS` without recorded evidence. External database credentials must be provided only through the runtime environment and test scripts must never print them.
