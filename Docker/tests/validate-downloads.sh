#!/usr/bin/env bash
set -euo pipefail
for var in HAMMERDB_AMD64_SHA256 HAMMERDB_ARM64_SHA256 MYSQL_AMD64_SHA256 MYSQL_ARM64_SHA256 ORACLE_AMD64_SHA256 ORACLE_ARM64_SHA256; do value=${!var:-}; [[ $value =~ ^[0-9a-fA-F]{64}$ ]] || { echo "FAIL: $var must be a 64-character SHA-256" >&2; exit 1; }; done
printf 'PASS: checksum inputs are syntactically valid (values not printed)\n'
