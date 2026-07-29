#!/usr/bin/env bash
set -euo pipefail
: "${PLATFORM:?set PLATFORM (linux/amd64 or linux/arm64)}"
: "${TAG_PREFIX:=hammerdb-v6-test}"
args=(--platform "$PLATFORM" --load)
for v in HAMMERDB_AMD64_SHA256 HAMMERDB_ARM64_SHA256 MYSQL_AMD64_SHA256 MYSQL_ARM64_SHA256 ORACLE_AMD64_SHA256 ORACLE_ARM64_SHA256; do [[ -n "${!v:-}" ]] || { echo "FAIL: missing $v" >&2; exit 1; }; done
docker buildx build "${args[@]}" --build-arg HAMMERDB_AMD64_SHA256 --build-arg HAMMERDB_ARM64_SHA256 -t "$TAG_PREFIX-base" Docker/base
for name in mysql maria postgres oracle mssqls; do extra=(); [[ $name == mysql ]] && extra+=(--build-arg MYSQL_AMD64_SHA256 --build-arg MYSQL_ARM64_SHA256); [[ $name == oracle ]] && extra+=(--build-arg ORACLE_AMD64_SHA256 --build-arg ORACLE_ARM64_SHA256); docker buildx build "${args[@]}" --build-arg BASE_IMAGE="$TAG_PREFIX-base" "${extra[@]}" -t "$TAG_PREFIX-$name" "Docker/$name"; done
docker buildx build "${args[@]}" $(for n in mysql maria postgres oracle mssqls; do printf -- '--build-arg %s_IMAGE=%s-%s ' "${n^^}" "$TAG_PREFIX" "$n"; done) -t "$TAG_PREFIX" Docker
