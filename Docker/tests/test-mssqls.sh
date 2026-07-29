#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"; validate_common
run bash -euc 'grep -F -- --enable-fastvalidate /usr/local/unixODBC-configure.args; odbcinst -j; odbcinst -q -d | grep -Fx "[ODBC Driver 18 for SQL Server]"; grep -E "^Driver=/opt/microsoft/msodbcsql18/.*/libmsodbcsql-.*\.so" "$ODBCSYSINI/odbcinst.ini"'
librarycheck '(SQL Server|MSSQL).*(SUCCESS|loaded|available)'
