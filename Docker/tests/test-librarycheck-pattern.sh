#!/usr/bin/env bash
set -euo pipefail
pattern='(Success|loaded library).*(SQL Server|MSSQL)'
inner='output=$1; grep -Ei -- "$2" <<<"$output"'
success='Success: loaded library for SQL Server'
failure='Failed: could not load library for SQL Server'
bash -euc "$inner" -- "$success" "$pattern" >/dev/null
if bash -euc "$inner" -- "$failure" "$pattern" >/dev/null; then
  echo 'FAIL: failed library load matched the success expression' >&2
  exit 1
fi
printf 'PASS: positional librarycheck regex handles parentheses and success ordering\n'
