#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  put)
    source_file=$2
    remote=$3
    stored="$FAKE_CDN_STORE/${remote#r2p:/}"
    mkdir -p "$(dirname -- "$stored")"
    test ! -e "$stored"
    cp "$source_file" "$stored"
    printf '%s\n' "${remote#r2p:/}" >> "$FAKE_FERY_LOG"
    exit 0
    ;;
esac

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=seiya-release.sh
# shellcheck disable=SC1091
source "$script_dir/seiya-release.sh"
repo_root=$(cd -- "$script_dir/../.." && pwd)

test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
export FAKE_CDN_STORE="$test_root/store"
export FAKE_FERY_LOG="$test_root/fery.log"
export cdn_origin=https://test.invalid

curl() {
  local output='' url='' write_status=false arg stored status
  while [ "$#" -gt 0 ]; do
    arg=$1
    shift
    case "$arg" in
      -o)
        output=$1
        shift
        ;;
      -w)
        write_status=true
        shift
        ;;
      http*) url=$arg ;;
    esac
  done
  stored="$FAKE_CDN_STORE/${url#https://test.invalid/}"
  stored=${stored%%\?*}
  status=${FAKE_CDN_STATUS:-}
  if [ -z "$status" ]; then
    if [ -f "$stored" ]; then status=200; else status=404; fi
  fi
  if [ "$write_status" = true ]; then
    if [ "$status" = 200 ]; then cp "$stored" "$output"; else : > "$output"; fi
    printf '%s' "$status"
    return 0
  fi
  test "$status" = 200 || return 22
  cp "$stored" "$output"
}

artifact="$test_root/artifact"
printf 'first\n' > "$artifact"
publish_immutable "$artifact" "seiya/sources/test/commit/test-linux-amd64" "$0" >/dev/null
test "$(wc -l < "$FAKE_FERY_LOG")" -eq 1
publish_immutable "$artifact" "seiya/sources/test/commit/test-linux-amd64" "$0" >/dev/null
test "$(wc -l < "$FAKE_FERY_LOG")" -eq 1

printf 'conflict\n' > "$artifact"
if publish_immutable "$artifact" "seiya/sources/test/commit/test-linux-amd64" "$0" >/dev/null 2>&1; then
  echo '远端冲突对象被错误接受' >&2
  exit 1
fi
test "$(wc -l < "$FAKE_FERY_LOG")" -eq 1

FAKE_CDN_STATUS=500
export FAKE_CDN_STATUS
if publish_immutable "$artifact" "seiya/sources/test/commit/other" "$0" >/dev/null 2>&1; then
  echo '远端 500 被错误识别为对象不存在' >&2
  exit 1
fi
unset FAKE_CDN_STATUS
test "$(wc -l < "$FAKE_FERY_LOG")" -eq 1

dist="$test_root/dist"
mkdir -p "$dist/gocron" "$dist/gocron-node"
for service in gocron gocron-node; do
  printf '%s-amd64\n' "$service" > "$dist/$service/$service-linux-amd64"
  printf '%s-arm64\n' "$service" > "$dist/$service/$service-linux-arm64"
  cp "$repo_root/LICENSE" "$dist/$service/LICENSE"
done
export release_commit=0123456789abcdef0123456789abcdef01234567
write_manifests "$dist"
python3 - "$dist" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
expected = {
    "gocron": "1.11.1-seiya.5",
    "gocron-node": "1.11.1-seiya.4",
}
for name, version in expected.items():
    document = json.loads((root / name / "release.json").read_text(encoding="utf-8"))
    assert set(document) == {"schema_version", "name", "version", "source", "inputs", "targets"}
    assert document["name"] == name
    assert document["version"] == version
    assert set(document["source"]) == {"repository", "commit", "tag"}
    assert set(document["inputs"]) == {"toolchains", "source_files", "files"}
    assert document["inputs"]["files"][0]["filename"] == "LICENSE"
    assert set(document["targets"]) == {"linux-amd64", "linux-arm64"}
    for target in document["targets"].values():
        assert set(target) == {"filename", "size", "sha256"}
PY

: > "$FAKE_FERY_LOG"
rm -rf -- "$FAKE_CDN_STORE"
verify_local() { :; }
unset FERY_SECRET_KEY
if publish_release "$dist" "$0" >/dev/null 2>&1; then
  echo '缺少 FERY_SECRET_KEY 时错误进入发布' >&2
  exit 1
fi
export FERY_SECRET_KEY=test-only
publish_release "$dist" "$0" >/dev/null
test "$(wc -l < "$FAKE_FERY_LOG")" -eq 8
test "$(head -n 6 "$FAKE_FERY_LOG" | grep -c '/release.json$' || true)" -eq 0
test "$(tail -n 2 "$FAKE_FERY_LOG" | grep -c '/release.json$')" -eq 2
grep -qx "seiya/sources/gocron/$release_commit/release.json" "$FAKE_FERY_LOG"
grep -qx "seiya/sources/gocron-node/$release_commit/release.json" "$FAKE_FERY_LOG"
