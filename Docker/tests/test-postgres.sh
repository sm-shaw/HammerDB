#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"; validate_common
run bash -euc 'psql --version | grep -E " 17\."; /usr/lib/postgresql/17/bin/pg_config --version | grep -E " 17\."; python3 - <<"PY"
import ctypes
p=ctypes.CDLL("libpq.so.5"); v=p.PQlibVersion(); print(v); assert 170000 <= v < 180000
PY
ldconfig -p | grep libpq.so.5'
librarycheck '(Success|loaded library).*PostgreSQL'
