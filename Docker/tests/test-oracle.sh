#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/common.sh"
validate_common

run bash -euc '
  test "$ORACLE_HOME" = /opt/oracle/instantclient
  test "$ORACLE_LIBRARY" = "$ORACLE_HOME/libclntsh.so"
  test "$TNS_ADMIN" = "$ORACLE_HOME/network/admin"
  test -e "$ORACLE_LIBRARY"

  resolved=$(readlink -f "$ORACLE_LIBRARY")
  test -f "$resolved"

  file "$resolved" | grep -F "$1"

  if ldd "$resolved" | grep -q "not found"; then
    ldd "$resolved"
    exit 1
  fi
' -- "${ORACLE_FILE_MACHINE:?}"

librarycheck '(Success|loaded library).*Oracle'
