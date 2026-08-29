#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
get|put)
  command=$1
  source_path=$2
  destination=${3:-}
  case "${FAKE_FERY_ERROR:-}" in
    auth) echo "错误: SDK 错误: 服务错误 (代码: AccessDenied): AccessDenied" >&2; exit 1 ;;
    network) echo "错误: 发送请求失败: timed out" >&2; exit 1 ;;
    server) echo "错误: SDK 错误: 服务错误 (代码: InternalError): InternalError" >&2; exit 1 ;;
  esac
  case "$command" in
    get)
      stored="$FAKE_FERY_STORE/${source_path#r2p:/}"
      if [ ! -f "$stored" ]; then
        echo "错误: SDK 错误: 服务错误 (代码: NotFound): NotFound" >&2
        exit 1
      fi
      cp "$stored" "$destination"
      ;;
    put)
      stored="$FAKE_FERY_STORE/${destination#r2p:/}"
      mkdir -p "$(dirname "$stored")"
      test ! -e "$stored"
      cp "$source_path" "$stored"
      printf 'put\n' >> "$FAKE_FERY_PUT_LOG"
      ;;
    *) exit 2 ;;
  esac
  exit 0
  ;;
esac

CDPATH=
export CDPATH
script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=publish-seiya-artifacts.sh
source "$script_dir/publish-seiya-artifacts.sh"

test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
scratch="$test_root/scratch"
mkdir -p "$scratch"
source_file="$test_root/service-linux-amd64"
printf 'first\n' > "$source_file"
export FAKE_FERY_STORE="$test_root/store"
export FAKE_FERY_PUT_LOG="$test_root/puts"
export FERY_BIN=$0
remote=r2p:/seiya/services/service/1/service-linux-amd64

publish_immutable "$source_file" "$remote" >/dev/null
test "$(wc -l < "$FAKE_FERY_PUT_LOG")" -eq 1
publish_immutable "$source_file" "$remote" >/dev/null
test "$(wc -l < "$FAKE_FERY_PUT_LOG")" -eq 1

printf 'conflict\n' > "$source_file"
if publish_immutable "$source_file" "$remote" >/dev/null 2>&1; then
  echo "冲突对象被错误接受" >&2
  exit 1
fi
test "$(wc -l < "$FAKE_FERY_PUT_LOG")" -eq 1

for error in auth network server; do
  export FAKE_FERY_ERROR=$error
  if publish_immutable "$source_file" "${remote}-$error" >/dev/null 2>&1; then
    echo "$error 错误被错误识别为 NotFound" >&2
    exit 1
  fi
  test "$(wc -l < "$FAKE_FERY_PUT_LOG")" -eq 1
done

is_fery_not_found '错误: SDK 错误: 服务错误 (代码: NotFound): NotFound'
if is_fery_not_found '错误: SDK 错误: 服务错误 (代码: AccessDenied): AccessDenied'; then exit 1; fi
if is_fery_not_found '错误: 发送请求失败: timed out'; then exit 1; fi
if is_fery_not_found '错误: SDK 错误: 服务错误 (代码: InternalError): InternalError'; then exit 1; fi
if is_fery_not_found '网络错误: 服务错误 (代码: NotFound): NotFound'; then exit 1; fi
