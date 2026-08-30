#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)
cdn_origin=${SEIYA_CDN_ORIGIN:-https://fery.seiya.dev}
repository=in64/gocron
release_tag=v1.11.1-seiya.5
gocron_version=1.11.1-seiya.5
gocron_node_version=1.11.1-seiya.4
app_version=1.11.1
go_version=1.26.6
node_version=25.9.0
pnpm_version=10.34.3
fery_version=0.1.1

usage() {
  echo '用法: seiya-release.sh build <dist-dir>' >&2
  echo '      seiya-release.sh verify-local <dist-dir>' >&2
  echo '      seiya-release.sh install-fery <destination>' >&2
  echo '      seiya-release.sh publish <dist-dir> <fery>' >&2
  echo '      seiya-release.sh verify-remote <dist-dir>' >&2
  exit 2
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

file_size() {
  if stat -c %s "$1" >/dev/null 2>&1; then
    stat -c %s "$1"
  else
    stat -f %z "$1"
  fi
}

load_release_identity() {
  local dirty
  release_commit=$(git -C "$repo_root" rev-parse HEAD)
  test "$(git -C "$repo_root" rev-parse "$release_tag^{commit}")" = "$release_commit" || {
    echo "发布 tag $release_tag 必须精确指向当前提交" >&2
    return 1
  }
  dirty=$(git -C "$repo_root" status --porcelain --untracked-files=all)
  test -z "$dirty" || {
    echo '发布源码工作树不干净' >&2
    return 1
  }
  source_app_version=$(sed -n 's/.*AppVersion[[:space:]]*= "\([^"]*\)".*/\1/p' \
    "$repo_root/cmd/gocron/gocron.go")
  test "$source_app_version" = "$app_version" || {
    echo "源码 AppVersion 与发布基线不一致: $source_app_version" >&2
    return 1
  }
}

require_toolchains() {
  command -v go >/dev/null
  command -v node >/dev/null
  command -v pnpm >/dev/null
  test "$(go env GOVERSION)" = "go$go_version" || {
    echo "需要 Go $go_version，当前为 $(go env GOVERSION)" >&2
    return 1
  }
  test "$(node --version)" = "v$node_version" || {
    echo "需要 Node.js $node_version，当前为 $(node --version)" >&2
    return 1
  }
  test "$(pnpm --version)" = "$pnpm_version" || {
    echo "需要 pnpm $pnpm_version，当前为 $(pnpm --version)" >&2
    return 1
  }
}

manifest_json() {
  local name version service_dir
  name=$1
  version=$2
  service_dir=$3
  SEIYA_MANIFEST_REPO_ROOT=$repo_root \
  SEIYA_MANIFEST_SERVICE_DIR=$service_dir \
  SEIYA_MANIFEST_NAME=$name \
  SEIYA_MANIFEST_VERSION=$version \
  SEIYA_MANIFEST_REPOSITORY=$repository \
  SEIYA_MANIFEST_COMMIT=$release_commit \
  SEIYA_MANIFEST_TAG=$release_tag \
  SEIYA_MANIFEST_GO=$go_version \
  SEIYA_MANIFEST_NODE=$node_version \
  SEIYA_MANIFEST_PNPM=$pnpm_version \
    python3 - <<'PY'
import hashlib
import json
import os
import pathlib

repo = pathlib.Path(os.environ["SEIYA_MANIFEST_REPO_ROOT"])
dist = pathlib.Path(os.environ["SEIYA_MANIFEST_SERVICE_DIR"])
name = os.environ["SEIYA_MANIFEST_NAME"]


def file_record(path: pathlib.Path, filename: str | None = None) -> dict:
    if not path.is_file() or path.stat().st_size <= 0:
        raise SystemExit(f"发布输入不存在或为空: {path}")
    return {
        "filename": filename or path.name,
        "size": path.stat().st_size,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }


source_files = {}
for relative in ("go.sum", "web/gocronx-admin/pnpm-lock.yaml"):
    record = file_record(repo / relative)
    source_files[relative] = {"size": record["size"], "sha256": record["sha256"]}

targets = {}
for target in ("linux-amd64", "linux-arm64"):
    filename = f"{name}-{target}"
    targets[target] = file_record(dist / filename, filename)

document = {
    "schema_version": 1,
    "name": name,
    "version": os.environ["SEIYA_MANIFEST_VERSION"],
    "source": {
        "repository": os.environ["SEIYA_MANIFEST_REPOSITORY"],
        "commit": os.environ["SEIYA_MANIFEST_COMMIT"],
        "tag": os.environ["SEIYA_MANIFEST_TAG"],
    },
    "inputs": {
        "toolchains": {
            "go": os.environ["SEIYA_MANIFEST_GO"],
            "node": os.environ["SEIYA_MANIFEST_NODE"],
            "pnpm": os.environ["SEIYA_MANIFEST_PNPM"],
        },
        "source_files": source_files,
        "files": [file_record(dist / "LICENSE", "LICENSE")],
    },
    "targets": targets,
}
print(json.dumps(document, ensure_ascii=False, sort_keys=True, separators=(",", ":")))
PY
}

write_manifests() {
  local dist_dir
  dist_dir=$1
  manifest_json gocron "$gocron_version" "$dist_dir/gocron" > "$dist_dir/gocron/release.json"
  manifest_json gocron-node "$gocron_node_version" "$dist_dir/gocron-node" \
    > "$dist_dir/gocron-node/release.json"
}

validate_manifest() {
  local name version service_dir expected
  name=$1
  version=$2
  service_dir=$3
  expected=$(mktemp)
  manifest_json "$name" "$version" "$service_dir" > "$expected"
  cmp -s "$expected" "$service_dir/release.json" || {
    rm -f -- "$expected"
    echo "release.json 与源码或本地产物不一致: $name" >&2
    return 1
  }
  rm -f -- "$expected"
}

verify_local() {
  local dist_dir
  dist_dir=$1
  load_release_identity
  validate_manifest gocron "$gocron_version" "$dist_dir/gocron"
  validate_manifest gocron-node "$gocron_node_version" "$dist_dir/gocron-node"
}

build_release() {
  local dist_dir build_epoch build_date ldflags arch service package output
  dist_dir=$1
  load_release_identity
  require_toolchains
  mkdir -p "$dist_dir/gocron" "$dist_dir/gocron-node"
  dist_dir=$(cd -- "$dist_dir" && pwd)
  rm -f -- \
    "$dist_dir/gocron/gocron-linux-amd64" \
    "$dist_dir/gocron/gocron-linux-arm64" \
    "$dist_dir/gocron/release.json" \
    "$dist_dir/gocron-node/gocron-node-linux-amd64" \
    "$dist_dir/gocron-node/gocron-node-linux-arm64" \
    "$dist_dir/gocron-node/release.json"

  (
    cd "$repo_root/web/gocronx-admin"
    pnpm install --frozen-lockfile
    pnpm run build
  )

  build_epoch=$(git -C "$repo_root" show -s --format=%ct HEAD)
  build_date=$(python3 - "$build_epoch" <<'PY'
import datetime
import sys

print(datetime.datetime.fromtimestamp(int(sys.argv[1]), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
  )
  ldflags="-s -w -buildid= -X main.AppVersion=$app_version -X main.BuildDate=$build_date -X main.GitCommit=$release_commit"
  for arch in amd64 arm64; do
    for service in gocron gocron-node; do
      package=./cmd/gocron
      test "$service" = gocron || package=./cmd/node
      output="$dist_dir/$service/$service-linux-$arch"
      (
        cd "$repo_root"
        CGO_ENABLED=0 GOOS=linux GOARCH=$arch SOURCE_DATE_EPOCH=$build_epoch \
          go build -mod=readonly -trimpath -buildvcs=false -ldflags "$ldflags" \
            -o "$output" "$package"
      )
      chmod 0755 "$output"
    done
  done
  install -m 0644 "$repo_root/LICENSE" "$dist_dir/gocron/LICENSE"
  install -m 0644 "$repo_root/LICENSE" "$dist_dir/gocron-node/LICENSE"
  write_manifests "$dist_dir"
  verify_local "$dist_dir"
}

verify_cdn() {
  local file relative expected temporary attempt
  file=$1
  relative=$2
  expected=$(sha256_file "$file")
  temporary=$(mktemp)
  attempt=1
  while :; do
    if curl -fsSL \
      "$cdn_origin/$relative?seiya_verify=${expected:0:16}" -o "$temporary" \
      && test "$(file_size "$temporary")" = "$(file_size "$file")" \
      && test "$(sha256_file "$temporary")" = "$expected"; then
      break
    fi
    test "$attempt" -lt 5 || {
      rm -f -- "$temporary"
      echo "CDN 逐字节回读失败: $relative" >&2
      return 1
    }
    attempt=$((attempt + 1))
    sleep $((attempt * 2))
  done
  rm -f -- "$temporary"
  echo "CDN 逐字节回读通过: $relative"
}

publish_immutable() {
  local file relative fery expected temporary status
  file=$1
  relative=$2
  fery=$3
  expected=$(sha256_file "$file")
  temporary=$(mktemp)
  if ! status=$(curl -sS -L -o "$temporary" -w '%{http_code}' \
    "$cdn_origin/$relative?seiya_preflight=${expected:0:16}"); then
    rm -f -- "$temporary"
    echo "远端预检请求失败: $relative" >&2
    return 1
  fi
  case "$status" in
    200)
      if ! cmp -s "$file" "$temporary"; then
        rm -f -- "$temporary"
        echo "远端不可变对象与本地产物冲突: $relative" >&2
        return 1
      fi
      echo "远端不可变对象已存在且一致: $relative"
      ;;
    404)
      "$fery" put "$file" "r2p:/$relative"
      ;;
    *)
      rm -f -- "$temporary"
      echo "远端预检失败: $relative HTTP $status" >&2
      return 1
      ;;
  esac
  rm -f -- "$temporary"
  verify_cdn "$file" "$relative"
}

install_fery() {
  local destination manifest filename size sha temporary
  destination=$1
  manifest=$(mktemp)
  temporary=$(mktemp)
  curl -fsSL "$cdn_origin/seiya/tools/fery/$fery_version/release.json" -o "$manifest"
  read -r filename size sha < <(python3 - "$manifest" "$fery_version" <<'PY'
import json
import pathlib
import sys

document = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if document.get("name") != "fery" or document.get("version") != sys.argv[2]:
    raise SystemExit("Fery release manifest 名称或版本不匹配")
target = document.get("targets", {}).get("linux-amd64", {})
expected = {"filename", "size", "sha256"}
if set(target) != expected or target.get("filename") != "fery-linux-amd64":
    raise SystemExit("Fery release manifest 缺少 linux-amd64")
print(target["filename"], target["size"], target["sha256"])
PY
  )
  curl -fsSL "$cdn_origin/seiya/tools/fery/$fery_version/$filename" -o "$temporary"
  test "$(file_size "$temporary")" = "$size"
  test "$(sha256_file "$temporary")" = "$sha"
  chmod 0755 "$temporary"
  mv -- "$temporary" "$destination"
  rm -f -- "$manifest"
}

publish_release() {
  local dist_dir fery service name prefix
  dist_dir=$1
  fery=$2
  test -n "${FERY_SECRET_KEY:-}" || {
    echo 'FERY_SECRET_KEY 未设置' >&2
    return 1
  }
  test -x "$fery"
  verify_local "$dist_dir"

  # 两项服务的全部 payload 先发布并完成 CDN 回读，release.json 最后发布。
  for service in gocron gocron-node; do
    prefix="seiya/sources/$service/$release_commit"
    for name in "$service-linux-amd64" "$service-linux-arm64" LICENSE; do
      publish_immutable "$dist_dir/$service/$name" \
        "$prefix/$name" "$fery"
    done
  done
  for service in gocron gocron-node; do
    prefix="seiya/sources/$service/$release_commit"
    publish_immutable "$dist_dir/$service/release.json" \
      "$prefix/release.json" "$fery"
  done
}

verify_remote() {
  local dist_dir service name prefix
  dist_dir=$1
  verify_local "$dist_dir"
  for service in gocron gocron-node; do
    prefix="seiya/sources/$service/$release_commit"
    for name in "$service-linux-amd64" "$service-linux-arm64" LICENSE release.json; do
      verify_cdn "$dist_dir/$service/$name" "$prefix/$name"
    done
  done
}

main() {
  case "${1:-}" in
    build)
      test "$#" -eq 2 || usage
      build_release "$2"
      ;;
    verify-local)
      test "$#" -eq 2 || usage
      verify_local "$2"
      ;;
    install-fery)
      test "$#" -eq 2 || usage
      install_fery "$2"
      ;;
    publish)
      test "$#" -eq 3 || usage
      publish_release "$2" "$3"
      ;;
    verify-remote)
      test "$#" -eq 2 || usage
      verify_remote "$2"
      ;;
    *) usage ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
