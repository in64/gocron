#!/usr/bin/env bash
set -euo pipefail

test "$#" -gt 0
test "$(( $# % 3 ))" -eq 0
: "${FERY_ORIGIN:?}"

scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT

publish_immutable() {
  local source=$1 remote=$2 downloaded
  downloaded="$scratch/$(printf '%s' "$remote" | sha256sum | awk '{print $1}')"
  if ./fery get "$remote" "$downloaded"; then
    cmp -s "$source" "$downloaded" || {
      echo "远端不可变对象内容冲突: $remote" >&2
      exit 1
    }
    echo "远端对象已存在且一致: $remote"
    return
  fi
  ./fery put "$source" "$remote"
  ./fery get "$remote" "$downloaded"
  cmp -s "$source" "$downloaded" || {
    echo "Fery 回读内容不一致: $remote" >&2
    exit 1
  }
}

verify_cdn() {
  python3 - "$1" "$2" <<'PY'
import hashlib
import pathlib
import sys
import time
import urllib.request

path, url = sys.argv[1:]
expected = pathlib.Path(path).read_bytes()
digest = hashlib.sha256(expected).hexdigest()
url = f"{url}?seiya_verify={digest[:16]}"
last_error = ""
for attempt in range(1, 11):
    try:
        request = urllib.request.Request(url, headers={"User-Agent": "seiya-release-verifier/1"})
        with urllib.request.urlopen(request, timeout=60) as response:
            actual = response.read()
        if actual == expected:
            print(f"CDN 逐字节校验通过: {url} size={len(actual)} sha256={digest}")
            break
        last_error = f"内容不一致: size={len(actual)} sha256={hashlib.sha256(actual).hexdigest()}"
    except Exception as exc:
        last_error = str(exc)
    if attempt == 10:
        raise SystemExit(f"CDN 回读失败: {url}: {last_error}")
    time.sleep(min(attempt * 2, 10))
PY
}

declare -a services versions artifacts
while [ "$#" -gt 0 ]; do
  name="$(basename "$3")"
  case "$name" in
    "$1-linux-amd64"|"$1-linux-arm64"|"$1-linux-amd64.tar.gz"|"$1-linux-arm64.tar.gz") ;;
    *) echo "非标准 Seiya 制品名: $name" >&2; exit 1 ;;
  esac
  services+=("$1")
  versions+=("$2")
  artifacts+=("$3")
  shift 3
done

for i in "${!artifacts[@]}"; do
  name="$(basename "${artifacts[$i]}")"
  remote="r2p:/seiya/services/${services[$i]}/${versions[$i]}/$name"
  publish_immutable "${artifacts[$i]}" "$remote"
done

for i in "${!artifacts[@]}"; do
  name="$(basename "${artifacts[$i]}")"
  url="${FERY_ORIGIN}/seiya/services/${services[$i]}/${versions[$i]}/$name"
  verify_cdn "${artifacts[$i]}" "$url"
done

for i in "${!artifacts[@]}"; do
  sidecar="${artifacts[$i]}.sha256"
  name="$(basename "$sidecar")"
  remote="r2p:/seiya/services/${services[$i]}/${versions[$i]}/$name"
  publish_immutable "$sidecar" "$remote"
done

for i in "${!artifacts[@]}"; do
  sidecar="${artifacts[$i]}.sha256"
  name="$(basename "$sidecar")"
  url="${FERY_ORIGIN}/seiya/services/${services[$i]}/${versions[$i]}/$name"
  verify_cdn "$sidecar" "$url"
done
