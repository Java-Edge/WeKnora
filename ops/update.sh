#!/bin/bash
# WeKnora 升级脚本：更新代码到最新版 -> 拉取新镜像 -> 滚动重启容器
# 用法:
#   ./ops/update.sh            升级前自动备份，升级到最新版
#   ./ops/update.sh --no-backup 跳过备份（不推荐）
#   ./ops/update.sh --tag v0.8.3  固定升级到指定 release tag（.env 中 WEKNORA_VERSION 同步被改写）
# 版本策略: .env 中 WEKNORA_VERSION=latest 表示跟随 main 分支最新构建；
#           固定版本可设 WEKNORA_VERSION=v0.x.x 或加 --tag 参数。
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

WITH_BACKUP=1
TAG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --no-backup) WITH_BACKUP=0 ;;
    --tag) TAG="${2:?--tag 需要版本参数}"; shift ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
  shift
done

# ---- 0. 记录升级前状态 ----
OLD_VERSION="$(cat VERSION 2>/dev/null || unknown)"
OLD_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || unknown)"
echo "==> 升级前版本: $OLD_VERSION (commit $OLD_COMMIT)"

if [ ! -f .env ]; then
  echo "[ERROR] .env 不存在，无法继续" >&2
  exit 1
fi
set -a; . ./.env; set +a
FP="${FRONTEND_PORT:-18090}"
AP="${APP_PORT:-18091}"

# ---- 1. 升级前备份（可按需跳过）----
if [ "$WITH_BACKUP" = "1" ]; then
  "$REPO/ops/backup.sh" || { echo "[ERROR] 备份失败，终止升级"; exit 1; }
else
  echo "==> 已跳过备份 (--no-backup)"
fi

# ---- 2. 更新代码 ----
echo "==> git fetch/pull ..."
cp .env.example /tmp/weknora-env-example-old.$$
git fetch origin main --depth=1
git pull --ff-only origin main
NEW_COMMIT="$(git rev-parse --short HEAD)"
echo "==> 当前版本: $(cat VERSION 2>/dev/null) (commit $NEW_COMMIT)"

# ---- 2b. 检查 .env.example 新增配置项（不覆盖现有 .env）----
if ! diff -q /tmp/weknora-env-example-old.$$ .env.example >/dev/null 2>&1; then
  echo "==> 新版 .env.example 有变化，新增的可选项如下（按需手工合并到 .env）:"
  diff /tmp/weknora-env-example-old.$$ .env.example | grep '^>' | head -40 || true
fi
rm -f /tmp/weknora-env-example-old.$$

# ---- 3. 固定/切换版本标签 ----
if [ -n "$TAG" ]; then
  echo "==> 改写 WEKNORA_VERSION=$TAG"
  sed -i '' "s|^WEKNORA_VERSION=.*|WEKNORA_VERSION=$TAG|" .env
fi

# ---- 4. 拉取新镜像并重建容器 ----
echo "==> docker compose pull ..."
docker compose pull frontend app docreader postgres redis
echo "==> docker compose up -d ..."
docker compose up -d

# ---- 5. 健康检查 ----
echo "==> 等待服务就绪 ..."
for i in $(seq 1 40); do
  code=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$FP/" 2>/dev/null || true)
  [ "$code" = "200" ] || [ "$code" = "302" ] || [ "$code" = "301" ] && break
  sleep 3
done
h1=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$FP/" 2>/dev/null || echo fail)
h2=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$AP/health" 2>/dev/null || echo fail)
echo ""
echo "[DONE] $OLD_VERSION ($OLD_COMMIT) -> $(cat VERSION 2>/dev/null || unknown) ($NEW_COMMIT)"
echo "  前端 UI:  http://127.0.0.1:$FP/  (HTTP $h1)"
echo "  后端 API: http://127.0.0.1:$AP/health (HTTP $h2)"
if [ "$h1" != "200" ] && [ "$h1" != "302" ] && [ "$h1" != "301" ]; then
  echo "[WARN] UI 未返回 200，请执行 docker compose logs -f app 排查"
  exit 1
fi
echo "提示: 大版本跨升级前请阅读官方升级须知 https://weknora.weixin.qq.com/docs/07-releases"
