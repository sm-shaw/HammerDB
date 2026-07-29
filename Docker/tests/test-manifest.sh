#!/usr/bin/env bash
set -euo pipefail
: "${IMAGE:?set IMAGE to a pushed image reference}"
json=$(docker buildx imagetools inspect --raw "$IMAGE")
python3 -c 'import json,sys; d=json.load(sys.stdin); p={(x["platform"]["os"],x["platform"]["architecture"]) for x in d["manifests"]}; missing={("linux","amd64"),("linux","arm64")}-p; assert not missing, f"missing platforms: {missing}"' <<< "$json"
echo 'PASS: linux/amd64 and linux/arm64 manifests present'
