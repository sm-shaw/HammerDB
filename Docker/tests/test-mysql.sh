#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"; validate_common
run bash -euc 'p=$(ldconfig -p | awk "/libmysqlclient.so.24/{print \\$NF; exit}"); test -n "$p"; file "$p" | grep -F "'"${MYSQL_FILE_MACHINE:?}"'"; readelf -d "$p" | grep -E "SONAME.*libmysqlclient.so.24"'
librarycheck 'MySQL.*(SUCCESS|loaded|available)'
