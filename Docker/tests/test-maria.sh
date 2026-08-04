#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/common.sh"
validate_common

run bash -euc '
  dpkg-query -W -f="$1" libmariadb3
  ldconfig -p | grep -F libmariadb.so.3
' -- '${Version}\n'

librarycheck '(Success|loaded library).*MariaDB'
