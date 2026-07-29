#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"; validate_common
run bash -euc 'dpkg-query -W -f="${Version}\n" libmariadb3; ldconfig -p | grep libmariadb.so.3'
librarycheck 'MariaDB.*(SUCCESS|loaded|available)'
