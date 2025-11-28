#!/usr/bin/env bash
set -euo pipefail
# Ensure TMP is set
if [[ -z "${TMP:-}" ]]; then
    export TMP="$(pwd)/TMP"
    mkdir -p "$TMP"
    echo "TMP not set — defaulting to $TMP"
fi
# REFNAME and PROFILEID are provided by the bisect driver
: "${REFNAME:?need REFNAME in env}"
: "${PROFILEID:?need PROFILEID in env}"
echo "BUILD HAMMERDB SCHEMA"
echo "+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-"
./hammerdbcli auto ./scripts/tcl/maria/tprocc/maria_tprocc_buildschema.tcl 
echo "+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-"
echo "CHECK HAMMERDB SCHEMA"
echo "+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-"
./hammerdbcli auto ./scripts/tcl/maria/tprocc/maria_tprocc_checkschema.tcl
echo "+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-"
echo "RUN HAMMERDB TEST"
echo "+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-"
./hammerdbcli auto ./scripts/tcl/maria/tprocc/maria_tprocc_run_compare.tcl 
echo "+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-"
echo "DROP HAMMERDB SCHEMA"
./hammerdbcli auto ./scripts/tcl/maria/tprocc/maria_tprocc_deleteschema.tcl
echo "+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-"
