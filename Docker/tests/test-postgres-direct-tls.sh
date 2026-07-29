#!/usr/bin/env bash
set -euo pipefail
if [[ -z "${PG_DIRECT_TLS_DSN:-}" ]]; then echo 'NOT RUN: set PG_DIRECT_TLS_DSN for a PostgreSQL 17 TLS endpoint'; exit 0; fi
: "${IMAGE:?set IMAGE}"; : "${PLATFORM:?set PLATFORM}"
docker run --rm --platform "$PLATFORM" -e PG_DIRECT_TLS_DSN "$IMAGE" bash -euc 'psql "$PG_DIRECT_TLS_DSN" -v ON_ERROR_STOP=1 -c "select version()"'
echo 'PASS: sslnegotiation=direct connection succeeded'
