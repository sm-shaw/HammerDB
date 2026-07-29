#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"; validate_common
for db in MySQL MariaDB PostgreSQL Oracle 'SQL Server'; do librarycheck "(Success|loaded library).*$db"; done
