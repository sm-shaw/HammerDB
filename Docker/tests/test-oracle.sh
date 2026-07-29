#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"; validate_common
run bash -euc 'test "$ORACLE_LIBRARY" = /opt/oracle/instantclient/libclntsh.so; file "$ORACLE_LIBRARY" | grep -F "'"${ORACLE_FILE_MACHINE:?}"'"; ldd "$ORACLE_LIBRARY" | grep -q "not found" && exit 1 || true'
librarycheck 'Oracle.*(SUCCESS|loaded|available)'
