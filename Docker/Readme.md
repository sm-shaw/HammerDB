# HammerDB 6.0 Docker images

These Dockerfiles package the published HammerDB 6.0 Ubuntu 24.04 release tarballs; HammerDB is **not compiled from source**. A single Dockerfile per logical image builds `linux/amd64` and `linux/arm64`, and a multi-platform manifest lets Docker select the host architecture automatically.

Images are built in dependency order: **base → MySQL → MariaDB → PostgreSQL → Oracle → SQL Server → combined**. Child builds accept image build arguments so validation never mixes 6.0 work with an existing production image. The combined image contains all five clients (Db2 remains excluded). The obsolete remote-GUI Docker variant was removed; normal HammerDB GUI and web service functionality are unchanged.

## Client design

* MySQL uses the architecture-specific `libmysqlclient.so.24` supplied by HammerDB and validates its SHA-256, ELF machine and SONAME.
* MariaDB uses Ubuntu 24.04's architecture-selected `libmariadb3` package.
* PostgreSQL uses PGDG PostgreSQL/libpq 17. This enables testing `sslnegotiation=direct` for issue #901, but the issue is not considered resolved until the separate direct-TLS integration test passes.
* Oracle uses the matching official Instant Client archive at `/opt/oracle/instantclient`.
* SQL Server uses Microsoft's Ubuntu 24.04 ODBC Driver 18 on both architectures and a custom `/usr/local/unixODBC` build with `--enable-fastvalidate`.

## Building and publishing

Run the manual **HammerDB 6.0 multi-architecture images** workflow. Its only trigger is `workflow_dispatch` and its modes are:

* `build-only`: builds and smoke-tests each architecture without logging in or pushing.
* `push-test`: uses only `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN`, and publishes immutable `v6.0-test-<component>-<commit>` manifests.
* `promote-production`: copies the exact tested manifests without rebuilding. It requires explicit confirmation and is blocked outside `TPC-Council/HammerDB`.

Production version tags are `v6.0-*` and aliases are the component names (`latest` for combined). Inspect a manifest with `IMAGE=docker.io/tpcorg/hammerdb:v6.0-test-<sha> Docker/tests/test-manifest.sh`. See [the test plan](TESTING-6.0-MULTIARCH.md).
